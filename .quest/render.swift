// quest-render: draws PDF pages with macOS PDFKit for the iPad reader, and reads a PDF's table of
// contents for `./quest add`. ./quest builds it once with `swiftc -O` and talks to it over stdin/stdout:
//   I <tab> path                                 -> page count, labels and sizes as JSON
//   O <tab> path                                 -> table of contents, title and author as JSON
//   R <tab> path <tab> page <tab> W <tab> H <tab> auto|preview|jpeg|png|heic [<tab> threads]
//   B <tab> path <tab> W <tab> H <tab> page,page,… <tab> threads   -> per-stage timings as JSON (./quest bench)
//   T <tab> strokes.json                         -> handwriting written with the Pencil, as text (Vision, on-device)
// Each reply is "OK <tab> length <tab> mime type" (or "ERR …"), a newline, then that many bytes.
//
// "auto" picks the smallest sharp encoding for each page. Text pages become 16-shade grayscale PNGs
// (4 bits per pixel, written by hand below): about a quarter of the size of a JPEG, and crisper.
// Gray photos become gray JPEGs and pages with color stay color JPEGs. "preview" is a quick, small JPEG
// the reader shows while the sharp page is still on its way.
//
// The PNG encoder's hot loops live in render_fast.h (C with ARM NEON): pixels are quantized and packed
// 32 at a time, and the image is compressed as independent strips on all cores at once, pigz-style.
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision
import zlib

var docs: [String: PDFDocument] = [:]
var threads = 8                             // compression strips per page (background work asks for 1)
var colorful: [String: Bool] = [:]          // "path#page" -> does the page have color?
let out = FileHandle.standardOutput
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let grayCS = CGColorSpaceCreateDeviceGray()

func reply(_ ok: Bool, _ body: Data, _ mime: String = "application/json") {
    out.write(Data("\(ok ? "OK" : "ERR")\t\(body.count)\t\(ok ? mime : "text/plain")\n".utf8) + body)
}

func open(_ path: String) -> PDFDocument? {
    if let d = docs[path] { return d }
    guard let d = PDFDocument(url: URL(fileURLWithPath: path)) else { return nil }
    if docs.count > 6 { docs.removeAll() }
    docs[path] = d
    return d
}

func size(_ page: PDFPage) -> CGSize {
    let b = page.bounds(for: .cropBox)
    return page.rotation % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
}

func info(_ d: PDFDocument) -> Data {
    var labels: [String] = [], sizes: [[Double]] = []
    for i in 0..<d.pageCount {
        guard let p = d.page(at: i) else { labels.append(String(i + 1)); sizes.append([612, 792]); continue }
        labels.append(p.label ?? String(i + 1))
        let s = size(p)
        sizes.append([(s.width * 10).rounded() / 10, (s.height * 10).rounded() / 10])
    }
    let obj: [String: Any] = ["n": d.pageCount, "labels": labels, "sizes": sizes]
    return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
}

func draw(_ page: PDFPage, _ W: Int, _ H: Int, gray: Bool) -> CGContext? {
    let s = size(page)
    let k = min(CGFloat(W) / s.width, CGFloat(H) / s.height)
    let w = max(1, Int(s.width * k)), h = max(1, Int(s.height * k))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: gray ? grayCS : srgb,
                              bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(w) / s.width, y: CGFloat(h) / s.height)
    page.draw(with: .cropBox, to: ctx)
    return ctx
}

func encode(_ img: CGImage, _ type: UTType, _ q: Double) -> Data? {
    let data = NSMutableData()
    guard let dst = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
    return CGImageDestinationFinalize(dst) ? data as Data : nil
}

// Checked once per page on a small RGB render, then remembered.
func hasColor(_ path: String, _ index: Int, _ page: PDFPage) -> Bool {
    let key = "\(path)#\(index)"
    if let c = colorful[key] { return c }
    var c = true
    if let ctx = draw(page, 360, 520, gray: false), let p = ctx.data?.assumingMemoryBound(to: UInt8.self) {
        c = false
        scan: for y in stride(from: 0, to: ctx.height, by: 2) {
            let row = p + y * ctx.bytesPerRow
            for x in stride(from: 0, to: ctx.width, by: 2) {
                let r = Int(row[x * 4]), g = Int(row[x * 4 + 1]), b = Int(row[x * 4 + 2])
                if max(r, g, b) - min(r, g, b) > 28 { c = true; break scan }
            }
        }
    }
    colorful[key] = c
    return c
}

// Share of mid-gray pixels: text is mostly black and white, photos and screenshots are full of grays.
func midtones(_ p: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ pitch: Int) -> Double {
    var n = 0, m = 0
    for y in stride(from: 0, to: h, by: 4) {
        let row = p + y * pitch
        for x in stride(from: 0, to: w, by: 4) {
            n += 1
            if row[x] > 48 && row[x] < 208 { m += 1 }
        }
    }
    return Double(m) / Double(max(1, n))
}

// A 4-bit (16-shade) grayscale PNG: two pixels per byte, no row filter, zlib level 3.
func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

func chunk(_ type: String, _ body: UnsafeBufferPointer<UInt8>, into out: inout [UInt8]) {
    let tb = Array(type.utf8)
    out += be32(UInt32(body.count))
    out += tb
    out += body
    var crc = UInt32(crc32(0, tb, uInt(tb.count)))
    crc = UInt32(crc32(uLong(crc), body.baseAddress, uInt(body.count)))
    out += be32(crc)
}

struct Timing { var pack = 0.0, deflate = 0.0, assemble = 0.0 }

// A 4-bit (16-shade) grayscale PNG. Rows are quantized and packed in parallel (qf_pack4, NEON), then the
// filtered image is cut into `parts` strips that are deflated at the same time on separate cores and
// joined into a single zlib stream (qf_deflate_strip). The result is an ordinary PNG any browser reads.
func png4(_ g: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ pitch: Int, parts: Int = threads, simd: Bool = true,
          level: Int32 = 3, timing: UnsafeMutablePointer<Timing>? = nil) -> Data? {
    let rb = (w + 1) / 2, n = (rb + 1) * h
    let k = max(1, min(parts, h / 64))
    let raw = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
    defer { raw.deallocate() }
    var t0 = DispatchTime.now().uptimeNanoseconds
    DispatchQueue.concurrentPerform(iterations: k) { i in
        let y0 = Int32(h * i / k), y1 = Int32(h * (i + 1) / k)
        if simd { qf_pack4(g, Int32(w), Int32(pitch), raw, y0, y1) } else { qf_pack4_scalar(g, Int32(w), Int32(pitch), raw, y0, y1) }
    }
    var t1 = DispatchTime.now().uptimeNanoseconds
    timing?.pointee.pack += Double(t1 - t0) / 1e6
    // strips end on row boundaries; each gets its own output region, so no thread waits on another
    let bounds = (0...k).map { (rb + 1) * (h * $0 / k) }
    let caps = (0..<k).map { qf_deflate_bound(bounds[$0 + 1] - bounds[$0]) }
    let offs = caps.reduce(into: [0]) { $0.append($0.last! + $1) }
    let z = UnsafeMutablePointer<UInt8>.allocate(capacity: offs.last!)
    defer { z.deallocate() }
    let sizes = UnsafeMutablePointer<Int>.allocate(capacity: k)
    defer { sizes.deallocate() }
    t0 = DispatchTime.now().uptimeNanoseconds
    DispatchQueue.concurrentPerform(iterations: k) { i in
        sizes[i] = qf_deflate_strip(raw + bounds[i], bounds[i + 1] - bounds[i], z + offs[i], caps[i],
                                    level, Z_DEFAULT_STRATEGY, i == k - 1 ? 1 : 0)
    }
    t1 = DispatchTime.now().uptimeNanoseconds
    timing?.pointee.deflate += Double(t1 - t0) / 1e6
    t0 = t1
    if (0..<k).contains(where: { sizes[$0] == 0 }) { return nil }
    var idat: [UInt8] = [0x78, 0x5E]                    // zlib header: 32 KB window, fast level
    idat.reserveCapacity((0..<k).reduce(0) { $0 + sizes[$1] } + 6)
    for i in 0..<k { idat += UnsafeBufferPointer(start: z + offs[i], count: sizes[i]) }
    idat += be32(qf_adler32(raw, n))
    var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    png.reserveCapacity(idat.count + 64)
    let ihdr = be32(UInt32(w)) + be32(UInt32(h)) + [4, 0, 0, 0, 0]   // 4-bit grayscale, no interlace
    ihdr.withUnsafeBufferPointer { chunk("IHDR", $0, into: &png) }
    idat.withUnsafeBufferPointer { chunk("IDAT", $0, into: &png) }
    [UInt8]().withUnsafeBufferPointer { chunk("IEND", $0, into: &png) }
    timing?.pointee.assemble += Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    return Data(png)
}

// qf_gray_and_color over horizontal bands on all the cores this request may use.
func grayAndColor(_ rgba: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ pitch: Int, _ gray: UnsafeMutablePointer<UInt8>, _ gpitch: Int) -> Bool {
    let k = max(1, min(threads, h / 64))
    let found = UnsafeMutablePointer<Int32>.allocate(capacity: k)
    defer { found.deallocate() }
    DispatchQueue.concurrentPerform(iterations: k) { i in
        let y0 = h * i / k, y1 = h * (i + 1) / k
        found[i] = qf_gray_and_color(rgba + y0 * pitch, Int32(w), Int32(y1 - y0), Int32(pitch), gray + y0 * gpitch, Int32(gpitch))
    }
    return (0..<k).contains { found[$0] != 0 }
}

func render(_ d: PDFDocument, _ path: String, _ index: Int, _ W: Int, _ H: Int, _ mode: String) -> (Data, String)? {
    guard let page = d.page(at: index) else { return nil }
    if ["jpeg", "png", "heic"].contains(mode) {             // a fixed format, in color
        let type: UTType = mode == "heic" ? .heic : mode == "png" ? .png : .jpeg
        guard let ctx = draw(page, W, H, gray: false), let img = ctx.makeImage(),
              let data = encode(img, type, mode == "heic" ? 0.6 : 0.8) else { return nil }
        return (data, type.preferredMIMEType ?? "image/jpeg")
    }
    let key = "\(path)#\(index)"
    var gctx: CGContext? = nil, cctx: CGContext? = nil
    if let known = colorful[key] {                          // seen before: draw straight in the right colors
        if known { cctx = draw(page, W, H, gray: false) } else { gctx = draw(page, W, H, gray: true) }
    } else {
        // first time: one color draw, then one NEON pass that finds color and extracts the gray image
        // (drawing twice costs ~4 ms more, since every PDFKit draw has a fixed overhead)
        guard let c = draw(page, W, H, gray: false), let rgba = c.data?.assumingMemoryBound(to: UInt8.self),
              let g = CGContext(data: nil, width: c.width, height: c.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: grayCS, bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let gp = g.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let color = grayAndColor(rgba, c.width, c.height, c.bytesPerRow, gp, g.bytesPerRow)
        colorful[key] = color
        if color { cctx = c } else { gctx = g }
    }
    if let c = cctx {                                       // a page with color stays a color JPEG
        guard let img = c.makeImage(), let data = encode(img, .jpeg, mode == "preview" ? 0.5 : 0.8) else { return nil }
        return (data, "image/jpeg")
    }
    guard let ctx = gctx, let p = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    if mode == "preview" {
        guard let img = ctx.makeImage(), let data = encode(img, .jpeg, 0.5) else { return nil }
        return (data, "image/jpeg")
    }
    if midtones(p, ctx.width, ctx.height, ctx.bytesPerRow) < 0.12, let data = png4(p, ctx.width, ctx.height, ctx.bytesPerRow) {
        return (data, "image/png")
    }
    guard let img = ctx.makeImage(), let data = encode(img, .jpeg, 0.8) else { return nil }
    return (data, "image/jpeg")
}

// The table of contents as [depth, page (1-based), title] rows, plus the document's own title.
func outline(_ d: PDFDocument) -> Data {
    var rows: [[Any]] = []
    func walk(_ node: PDFOutline, _ depth: Int) {
        for i in 0..<node.numberOfChildren {
            guard let c = node.child(at: i) else { continue }
            var page = c.destination?.page
            if page == nil, let go = c.action as? PDFActionGoTo { page = go.destination.page }
            let title = (c.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let page = page, !title.isEmpty { rows.append([depth, d.index(for: page) + 1, title]) }
            if depth < 4 { walk(c, depth + 1) }
        }
    }
    if let root = d.outlineRoot { walk(root, 0) }
    let guessed = rows.isEmpty
    if guessed { rows = scanForChapters(d) }
    let attrs = d.documentAttributes ?? [:]
    let obj: [String: Any] = ["n": d.pageCount, "outline": rows, "guessed": guessed,
                              "title": attrs[PDFDocumentAttribute.titleAttribute] as? String ?? "",
                              "author": attrs[PDFDocumentAttribute.authorAttribute] as? String ?? ""]
    return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
}

// No outline: look for chapter openers in the page text. A chapter starts on a page whose first line is
// "Chapter N" (or just the number N) followed by a title, and N must count up 1, 2, 3, so code listings
// that happen to start with a number don't fool it. "Index" after the last chapter ends the book.
func scanForChapters(_ d: PDFDocument) -> [[Any]] {
    var rows: [[Any]] = [], want = 1
    let words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
    for i in 0..<d.pageCount {
        let lines = (d.page(at: i)?.string ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first else { continue }
        let low = first.lowercased()
        if !rows.isEmpty && (low == "index" || low == "bibliography" || low == "references") {
            rows.append([0, i + 1, first]); break
        }
        var n: Int? = Int(first)
        var rest = Array(lines.dropFirst())
        if low.hasPrefix("chapter ") {
            let tok = low.dropFirst(8).split(separator: " ").first.map(String.init) ?? ""
            n = Int(tok.trimmingCharacters(in: CharacterSet(charactersIn: ":.")))
                ?? words.firstIndex(of: tok).map { $0 + 1 }
            let after = first.dropFirst(8 + tok.count).trimmingCharacters(in: CharacterSet(charactersIn: " :.-—"))
            if !after.isEmpty { rest.insert(after, at: 0) }
        }
        guard n == want, let t1 = rest.first, t1.count >= 3, t1.count < 90 else { continue }
        let letters = t1.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let upper = letters.filter { CharacterSet.uppercaseLetters.contains($0) }
        let looksTitle = low.hasPrefix("chapter ") || (letters.count >= 3 && upper.count * 10 >= letters.count * 7)
        guard looksTitle else { continue }
        var title = t1
        if rest.count > 1, !low.hasPrefix("chapter ") {
            let t2 = rest[1], l2 = t2.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            if l2.count >= 2, l2.filter({ CharacterSet.uppercaseLetters.contains($0) }).count == l2.count, t2.count < 60 { title += " " + t2 }
        }
        rows.append([0, i + 1, "Chapter \(want): \(title)"])
        want += 1
    }
    return rows.count >= 2 ? rows : []
}

// Benchmark: for each page, time every stage of the pipeline and the alternative encoders, and check that
// both PNG encoders decode back to exactly the expected 16-shade pixels.
func bench(_ d: PDFDocument, _ path: String, _ W: Int, _ H: Int, _ pages: [Int], _ cores: Int) -> Data {
    func ms(_ a: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - a) / 1e6 }
    var rows: [[String: Any]] = []
    for pg in pages {
        guard let page = d.page(at: pg - 1) else { continue }
        _ = draw(page, 64, 64, gray: true)              // first-touch parse, measured separately below
        var r: [String: Any] = ["page": pg]
        var t = DispatchTime.now().uptimeNanoseconds
        colorful.removeValue(forKey: "\(path)#\(pg - 1)")
        let color = hasColor(path, pg - 1, page)
        r["color_check_ms"] = ms(t); r["color"] = color
        t = DispatchTime.now().uptimeNanoseconds
        guard let gctx = draw(page, W, H, gray: true), let gp = gctx.data?.assumingMemoryBound(to: UInt8.self) else { continue }
        r["draw_ms"] = ms(t)
        t = DispatchTime.now().uptimeNanoseconds
        if let c = draw(page, W, H, gray: false), let rgba = c.data?.assumingMemoryBound(to: UInt8.self) {
            r["draw_rgb_ms"] = ms(t)
            let tmp = UnsafeMutablePointer<UInt8>.allocate(capacity: c.width * c.height)
            let t2 = DispatchTime.now().uptimeNanoseconds
            _ = grayAndColor(rgba, c.width, c.height, c.bytesPerRow, tmp, c.width)
            r["gray_color_pass_ms"] = ms(t2)
            tmp.deallocate()
        }
        r["first_render_ms"] = 0
        let (w, h, pitch) = (gctx.width, gctx.height, gctx.bytesPerRow)
        r["w"] = w; r["h"] = h
        t = DispatchTime.now().uptimeNanoseconds
        r["midtones"] = midtones(gp, w, h, pitch); r["midtones_ms"] = ms(t)
        // the engine: scalar vs NEON packing, 1 core vs many for compression
        for (name, parts, simd) in [("png4_scalar_1", 1, false), ("png4_neon_1", 1, true), ("png4_neon_n", cores, true)] {
            var tm = Timing()
            t = DispatchTime.now().uptimeNanoseconds
            let png = png4(gp, w, h, pitch, parts: parts, simd: simd, timing: &tm)
            r[name + "_ms"] = ms(t); r[name + "_pack_ms"] = tm.pack; r[name + "_deflate_ms"] = tm.deflate
            r[name + "_bytes"] = png?.count ?? 0
            // verify: decode with ImageIO and compare every pixel with the reference quantizer
            if let png = png, let src = CGImageSourceCreateWithData(png as CFData, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
               let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: grayCS,
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                let dp = ctx.data!.assumingMemoryBound(to: UInt8.self)
                var bad = 0
                for y in 0..<h { for x in 0..<w where dp[y * w + x] != UInt8((Int(gp[y * pitch + x]) * 15 + 127) / 255 * 17) { bad += 1 } }
                r[name + "_mismatched_pixels"] = bad
            } else { r[name + "_mismatched_pixels"] = -1 }
        }
        for cores in [1, 2, 4, 8] {
            t = DispatchTime.now().uptimeNanoseconds
            _ = png4(gp, w, h, pitch, parts: cores)
            r["scale_\(cores)_ms"] = ms(t)
        }
        // the alternatives, through Apple's ImageIO
        if let gimg = gctx.makeImage(), let cctx = draw(page, W, H, gray: false), let cimg = cctx.makeImage() {
            for (name, img, type, q) in [("jpeg_color", cimg, UTType.jpeg, 0.8), ("jpeg_gray", gimg, UTType.jpeg, 0.8),
                                         ("heic", cimg, UTType.heic, 0.6), ("png_gray8", gimg, UTType.png, 1.0)] {
                t = DispatchTime.now().uptimeNanoseconds
                let data = encode(img, type, q)
                r[name + "_ms"] = ms(t); r[name + "_bytes"] = data?.count ?? 0
            }
        }
        t = DispatchTime.now().uptimeNanoseconds
        let pv = render(d, path, pg - 1, max(16, W / 4), H / 4, "preview")
        r["preview_ms"] = ms(t); r["preview_bytes"] = pv?.0.count ?? 0
        colorful.removeValue(forKey: "\(path)#\(pg - 1)")
        t = DispatchTime.now().uptimeNanoseconds
        _ = render(d, path, pg - 1, W, H, "auto")              // the real path, first time this page is seen
        r["first_render_ms"] = ms(t)
        t = DispatchTime.now().uptimeNanoseconds
        _ = render(d, path, pg - 1, W, H, "auto")              // again, colors known: straight to gray
        r["repeat_render_ms"] = ms(t)
        rows.append(r)
    }
    let obj: [String: Any] = ["cores": ProcessInfo.processInfo.activeProcessorCount, "neon": NEON_ON, "rows": rows]
    return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
}

// Handwriting → text. The strokes (page-normalized points from the reader) are drawn black on white,
// cropped to where the ink is, and read with Vision's on-device text recognizer, which handles handwriting.
// Lines come back top to bottom. Highlighter strokes are ignored: they mark text, they aren't writing.
func transcribe(_ file: String) -> Data {
    guard let raw = FileManager.default.contents(atPath: file),
          let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
          let strokes = obj["strokes"] as? [[String: Any]] else { return Data() }
    let aspect = (obj["aspect"] as? Double) ?? 1.3
    let W = 1600.0, H = W * aspect
    var lines: [(width: Double, pts: [CGPoint])] = []
    var minX = Double.infinity, minY = Double.infinity, maxX = 0.0, maxY = 0.0
    for s in strokes where (s["t"] as? String) != "hl" {
        guard let pts = s["pts"] as? [[Double]], !pts.isEmpty else { continue }
        let w = max(2.5, ((s["w"] as? Double) ?? 0.002) * W * 0.9)
        let cg = pts.map { CGPoint(x: $0[0] * W, y: $0[1] * H) }
        for p in cg { minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y) }
        lines.append((w, cg))
    }
    guard !lines.isEmpty else { return Data() }
    let pad = 40.0, cw = Int(maxX - minX + 2 * pad), ch = Int(maxY - minY + 2 * pad)
    guard cw > 0, ch > 0, let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0, space: grayCS,
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return Data() }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
    ctx.translateBy(x: 0, y: CGFloat(ch)); ctx.scaleBy(x: 1, y: -1)              // page coordinates point down
    ctx.translateBy(x: CGFloat(pad - minX), y: CGFloat(pad - minY))
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 1)); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    for l in lines {
        ctx.setLineWidth(CGFloat(l.width))
        ctx.beginPath(); ctx.addLines(between: l.pts.count == 1 ? [l.pts[0], l.pts[0]] : l.pts); ctx.strokePath()
    }
    guard let img = ctx.makeImage() else { return Data() }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    // Read in the Mac's own languages (English if none is supported). Automatic detection guesses badly on a
    // few handwritten words: it read "one copy" as Cyrillic.
    let supported = (try? req.supportedRecognitionLanguages()) ?? ["en-US"]
    var langs: [String] = []
    for pref in Locale.preferredLanguages {
        if let m = supported.first(where: { $0.lowercased().hasPrefix(String(pref.lowercased().prefix(2))) }), !langs.contains(m) { langs.append(m) }
    }
    req.recognitionLanguages = langs.isEmpty ? ["en-US"] : langs
    try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
    let found = (req.results ?? []).compactMap { o -> (CGRect, String)? in
        guard let t = o.topCandidates(1).first?.string else { return nil }
        return (o.boundingBox, t)
    }
    // top to bottom (Vision's origin is bottom-left), then left to right within a line
    var text = found.sorted { abs($0.0.midY - $1.0.midY) > 0.02 ? $0.0.midY > $1.0.midY : $0.0.minX < $1.0.minX }
        .map { $0.1 }.joined(separator: "\n")
    // Vision sometimes answers with Cyrillic or Greek look-alikes ("опе сору" for "one copy") even when asked
    // for English. If every language we asked for is written in Latin letters, map those back.
    let latin: Set<String> = ["en", "fr", "it", "de", "es", "pt", "tr", "id", "cs", "da", "nl", "no", "nn", "nb", "ms", "pl", "ro", "sv", "vi"]
    if req.recognitionLanguages.allSatisfy({ latin.contains(String($0.prefix(2))) }) {
        let twins: [Character: Character] = ["а": "a", "в": "B", "е": "e", "к": "k", "м": "M", "н": "H", "о": "o", "п": "n",
            "р": "p", "с": "c", "т": "T", "у": "y", "х": "x", "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H",
            "О": "O", "Р": "P", "С": "C", "Т": "T", "Х": "X", "У": "Y", "і": "i", "ј": "j", "ѕ": "s", "ο": "o", "α": "a",
            "ν": "v", "ρ": "p", "τ": "t", "Ο": "O", "Α": "A", "Β": "B", "Ε": "E", "Κ": "K", "Μ": "M", "Ν": "N", "Τ": "T"]
        text = String(text.map { twins[$0] ?? $0 })
    }
    return Data(text.utf8)
}

#if arch(arm64)
let NEON_ON = true
#else
let NEON_ON = false
#endif

while let line = readLine(strippingNewline: true) {
    let f = line.components(separatedBy: "\t")
    if f.count >= 2 && f[0] == "T" { reply(true, autoreleasepool { transcribe(f[1]) }, "text/plain"); continue }
    guard f.count >= 2, let d = open(f[1]) else { reply(false, Data("can't open that PDF".utf8)); continue }
    if f[0] == "I" { reply(true, info(d)); continue }
    if f[0] == "O" { reply(true, outline(d)); continue }
    if f[0] == "B", f.count >= 6, let W = Int(f[2]), let H = Int(f[3]), let cores = Int(f[5]) {
        reply(true, bench(d, f[1], W, H, f[4].split(separator: ",").compactMap { Int($0) }, cores))
        continue
    }
    guard f[0] == "R", f.count >= 6, let pg = Int(f[2]), let W = Int(f[3]), let H = Int(f[4]),
          W > 0, H > 0, W <= 8192, H <= 8192 else { reply(false, Data("bad request".utf8)); continue }
    threads = f.count >= 7 ? max(1, min(16, Int(f[6]) ?? 8)) : 8
    if let (data, mime) = autoreleasepool(invoking: { render(d, f[1], pg - 1, W, H, f[5]) }) {
        reply(true, data, mime)
    } else {
        reply(false, Data("can't draw page \(pg)".utf8))
    }
}
