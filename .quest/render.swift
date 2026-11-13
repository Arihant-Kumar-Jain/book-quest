// quest-render: draws PDF pages with macOS PDFKit and encodes them with ImageIO,
// so the iPad reader gets ready-to-show images instead of parsing the PDF itself.
// ./quest builds this once with swiftc and talks to it over stdin/stdout:
//   I <tab> path                                  -> page count, labels and sizes as JSON
//   O <tab> path                                  -> table of contents, title and author as JSON
//   R <tab> path <tab> page <tab> W <tab> H <tab> jpeg|heic|png <tab> quality
// Each reply is "OK <tab> length" or "ERR <tab> length", a newline, then that many bytes.
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

var docs: [String: PDFDocument] = [:]
let out = FileHandle.standardOutput
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func reply(_ ok: Bool, _ body: Data) {
    out.write(Data("\(ok ? "OK" : "ERR")\t\(body.count)\n".utf8) + body)
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

func render(_ d: PDFDocument, _ index: Int, _ W: Int, _ H: Int, _ type: UTType, _ q: Double) -> Data? {
    guard let page = d.page(at: index) else { return nil }
    let s = size(page)
    let k = min(CGFloat(W) / s.width, CGFloat(H) / s.height)
    let w = max(1, Int(s.width * k)), h = max(1, Int(s.height * k))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(w) / s.width, y: CGFloat(h) / s.height)
    page.draw(with: .cropBox, to: ctx)
    guard let img = ctx.makeImage() else { return nil }
    let data = NSMutableData()
    guard let dst = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: q] as CFDictionary)
    return CGImageDestinationFinalize(dst) ? data as Data : nil
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

while let line = readLine(strippingNewline: true) {
    let f = line.components(separatedBy: "\t")
    guard f.count >= 2, let d = open(f[1]) else { reply(false, Data("can't open that PDF".utf8)); continue }
    if f[0] == "I" { reply(true, info(d)); continue }
    if f[0] == "O" { reply(true, outline(d)); continue }
    guard f[0] == "R", f.count >= 7, let pg = Int(f[2]), let W = Int(f[3]), let H = Int(f[4]), let q = Double(f[6]),
          W > 0, H > 0, W <= 8192, H <= 8192 else { reply(false, Data("bad request".utf8)); continue }
    let type: UTType = f[5] == "heic" ? .heic : f[5] == "png" ? .png : .jpeg
    if let data = autoreleasepool(invoking: { render(d, pg - 1, W, H, type, q) }) {
        reply(true, data)
    } else {
        reply(false, Data("can't draw page \(pg)".utf8))
    }
}
