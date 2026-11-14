# Book Quest · benchmark results

Apple M3 (8 cores: 4 performance + 4 efficiency) · 16 GB · macOS 26.4.1 · Python 3.12.5 · 2026-11-14

Book: *C++ Crash Course*, 794 pages. Pages are drawn for an iPad-sized box of 1608×2328 px (1608×2124 px per page). Engine timings are the best of 3 round(s) per page; percentiles are across 46 text pages.

## Codecs: one page, five ways

| Encoder | Size p50 | Size p95 | vs JPEG | Encode p50 | Encode p95 |
|---|---:|---:|---:|---:|---:|
| **16-shade PNG (ours: NEON + 8-core deflate)** | 121.0 KB | 150.1 KB | 0.25× | 1.92 ms | 2.17 ms |
| JPEG q0.8, color (ImageIO) | 486.9 KB | 644.2 KB | 1.00× | 13.24 ms | 15.40 ms |
| JPEG q0.8, gray (ImageIO) | 470.5 KB | 627.4 KB | 0.97× | 9.04 ms | 11.04 ms |
| HEIC q0.6 (ImageIO) | 209.5 KB | 288.4 KB | 0.43× | 41.85 ms | 44.95 ms |
| PNG 8-bit gray (ImageIO) | 207.3 KB | 256.8 KB | 0.43× | 37.57 ms | 39.94 ms |
| Preview: ¼-size JPEG q0.5 | 35.3 KB | 43.8 KB | 0.07× | 2.19 ms | 2.71 ms |

Every PNG was decoded again with ImageIO and compared with the reference quantizer: **0 mismatched pixels** out of 491,816,448 checked.

## Inside the encoder

| Stage | p50 | p95 |
|---|---:|---:|
| PDFKit draw, grayscale | 2.00 ms | 2.60 ms |
| Separate color check (old: a second draw) | 1.00 ms | 1.22 ms |
| PDFKit draw, color (new: once) | 2.60 ms | 3.36 ms |
| NEON pass: gray + color detection | 0.46 ms | 0.51 ms |
| Quantize + pack, scalar C | 1.88 ms | 2.00 ms |
| Quantize + pack, NEON, 1 core | 0.18 ms | 0.22 ms |
| Quantize + pack, NEON, 8 cores | 0.11 ms | 0.15 ms |
| Deflate, 1 core | 7.76 ms | 9.47 ms |
| Deflate, 8 strips in parallel | 1.60 ms | 1.87 ms |
| PNG encode, scalar, 1 core | 9.98 ms | 11.71 ms |
| **PNG encode, NEON, 8 cores** | 1.92 ms | 2.17 ms |
| **Whole page, first time (draw → PNG)** | 5.43 ms | 6.15 ms |
| Whole page, colors already known | 4.19 ms | 4.85 ms |

| Compression strips | 1 | 2 | 4 | 8 |
|---|---:|---:|---:|---:|
| PNG encode p50 | 8.19 ms | 4.61 ms | 2.87 ms | 1.84 ms |

## Server, end to end (HTTP over loopback)

| Path | p50 | p95 | p99 |
|---|---:|---:|---:|
| Page from memory | 0.24 ms | 0.29 ms | 0.36 ms |
| Page from disk, right after a restart | 0.61 ms | 1.92 ms | 3.34 ms |
| Page never drawn before | 9.17 ms | 12.59 ms | 21.83 ms |
| Preview never drawn before | 4.30 ms | 6.36 ms | 7.97 ms |
| Push → reader receives it (page drawn ahead) | 1.04 ms | 1.34 ms | 1.56 ms |
| Push → Mac gets the acknowledgement | 1.59 ms | 2.10 ms | 2.53 ms |
| Push → sharp page delivered (drawn ahead) | 2.00 ms | 2.59 ms | 3.20 ms |
| Push → reader receives it (cold) | 0.48 ms | 0.73 ms | 0.95 ms |
| Push → sharp page delivered (cold) | 10.30 ms | 18.85 ms | 27.92 ms |
| Quest state (gzip 109 KB → 29 KB) | 5.50 ms | 6.01 ms | 8.23 ms |

- **Throughput:** 3,102 page requests/s (324 MB/s) with 8 clients.
- **Whole book in the background:** 794/794 pages in 11.7 s (68.0 pages/s on one core), 94 MB on disk.
- **Page sizes over the wire:** 118.8 KB p50, 159.2 KB p95 (60 image/png).
- **Memory:** server 132 MB with the whole book cached; 4 helpers 322 MB.

## On real devices (reported by the reader)

| Device | Measurement | n | p50 | p95 | p99 |
|---|---|---:|---:|---:|---:|
| iPad | Page turn, swipe → new page on screen | 66 | 16.00 ms | 31.75 ms | 34.05 ms |
| iPad | Jump to a page (slider, link, book switch) | 16 | 56.00 ms | 141.50 ms | 164.30 ms |
| iPad | Mac click → preview on the iPad's screen | 3 | 43.00 ms | 52.00 ms | 52.80 ms |
| iPad | Mac click → sharp page on the iPad's screen | 4 | 48.00 ms | 53.85 ms | 53.97 ms |
| iPad | Preview on screen while the page loads | 3 | 65.00 ms | 145.10 ms | 152.22 ms |
| iPad | Mac hover → page fetched and decoded ahead | 2 | 35.00 ms | 43.10 ms | 43.82 ms |
| iPad | Scroll mode: page appears | 277 | 20.00 ms | 112.20 ms | 294.20 ms |
| iPad | Scroll mode: preview appears | 116 | 33.00 ms | 93.75 ms | 319.20 ms |
| iPad | Fetch a page over Wi-Fi | 312 | 26.00 ms | 162.85 ms | 480.86 ms |
| iPad | Fetch a preview over Wi-Fi | 125 | 28.00 ms | 102.60 ms | 285.76 ms |
| iPad | Decode a page image | 121 | 9.00 ms | 23.00 ms | 38.20 ms |
| mac | Push → acknowledgement back (Wi-Fi round trip) | 7 | 128.41 ms | 183.62 ms | 185.95 ms |
