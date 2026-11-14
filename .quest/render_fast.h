// render_fast.h: the hot loops of quest-render, in C so they can use ARM NEON vector instructions.
// Swift imports this as a bridging header (swiftc -import-objc-header). Everything has a plain C
// fallback, so it also builds on Intel Macs.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <zlib.h>
#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

// 8-bit gray → 16 shades, packed two pixels per byte, each row prefixed with PNG filter type 0.
// The shade is exactly round(v * 15 / 255) for every v; (v * 15 + 135) >> 8 is the only multiply-shift
// form of that with a shift of 8, which lets NEON do 32 pixels per step with one widening multiply-add
// and one narrowing shift per 8 lanes. Rows y0..y1 are written, so threads can split an image.
static inline void qf_pack4(const uint8_t *gray, int w, int pitch, uint8_t *out, int y0, int y1) {
    const int rb = (w + 1) / 2;
    for (int y = y0; y < y1; y++) {
        const uint8_t *row = gray + (size_t)y * pitch;
        uint8_t *o = out + (size_t)y * (rb + 1);
        *o++ = 0;
        int x = 0;
#if defined(__ARM_NEON)
        const uint8x8_t k15 = vdup_n_u8(15);
        const uint16x8_t k135 = vdupq_n_u16(135);
        for (; x + 32 <= w; x += 32) {
            uint8x16x2_t v = vld2q_u8(row + x);                 // de-interleave: even pixels, odd pixels
            uint8x16_t hi = vcombine_u8(vshrn_n_u16(vmlal_u8(k135, vget_low_u8(v.val[0]), k15), 8),
                                        vshrn_n_u16(vmlal_u8(k135, vget_high_u8(v.val[0]), k15), 8));
            uint8x16_t lo = vcombine_u8(vshrn_n_u16(vmlal_u8(k135, vget_low_u8(v.val[1]), k15), 8),
                                        vshrn_n_u16(vmlal_u8(k135, vget_high_u8(v.val[1]), k15), 8));
            vst1q_u8(o, vorrq_u8(vshlq_n_u8(hi, 4), lo));
            o += 16;
        }
#endif
        for (; x + 1 < w; x += 2)
            *o++ = (uint8_t)((((row[x] * 15 + 135) >> 8) << 4) | ((row[x + 1] * 15 + 135) >> 8));
        if (x < w)
            *o++ = (uint8_t)(((row[x] * 15 + 135) >> 8) << 4);
    }
}

// The same packing one pixel at a time (same multiply-shift, no vectors): the fair scalar baseline.
// The compiler's auto-vectorizer is switched off for it, so the comparison really is scalar vs NEON.
static inline void qf_pack4_scalar(const uint8_t *gray, int w, int pitch, uint8_t *out, int y0, int y1) {
    const int rb = (w + 1) / 2;
    for (int y = y0; y < y1; y++) {
        const uint8_t *row = gray + (size_t)y * pitch;
        uint8_t *o = out + (size_t)y * (rb + 1);
        *o++ = 0;
        int x = 0;
#pragma clang loop vectorize(disable) interleave(disable)
        for (; x + 1 < w; x += 2)
            *o++ = (uint8_t)((((row[x] * 15 + 135) >> 8) << 4) | ((row[x + 1] * 15 + 135) >> 8));
        if (x < w)
            *o++ = (uint8_t)(((row[x] * 15 + 135) >> 8) << 4);
    }
}

static inline size_t qf_deflate_bound(size_t n) { return compressBound((uLong)n) + 64; }

// One strip of a pigz-style parallel deflate. Each strip is compressed on its own as a raw deflate
// stream (no zlib header) that ends on a byte boundary with an empty stored block (Z_SYNC_FLUSH), or
// with the final block (Z_FINISH) for the last strip. Because no strip refers back into another,
// the strips can simply be concatenated into one valid stream. Returns the size, or 0 on error.
static inline size_t qf_deflate_strip(const uint8_t *src, size_t n, uint8_t *dst, size_t cap,
                                      int level, int strategy, int last) {
    z_stream zs = {0};
    if (deflateInit2(&zs, level, Z_DEFLATED, -15, 8, strategy) != Z_OK) return 0;
    zs.next_in = (Bytef *)src;
    zs.avail_in = (uInt)n;
    zs.next_out = dst;
    zs.avail_out = (uInt)cap;
    int rc = deflate(&zs, last ? Z_FINISH : Z_SYNC_FLUSH);
    size_t got = cap - zs.avail_out;
    int ok = last ? rc == Z_STREAM_END : (rc == Z_OK && zs.avail_out > 0);
    deflateEnd(&zs);
    return ok ? got : 0;
}

static inline uint32_t qf_adler32(const uint8_t *p, size_t n) { return (uint32_t)adler32(1, p, (uInt)n); }

static inline uint32_t qf_crc32(const uint8_t *p, size_t n) { return (uint32_t)crc32(0, p, (uInt)n); }

// One pass over an RGBA page that does two jobs: copy out the green channel as the grayscale image
// (on a gray page R = G = B, so this is exact) and notice whether any pixel has real color
// (max - min of R, G, B above 28). Returns 1 if the page has color.
static inline int qf_gray_and_color(const uint8_t *rgba, int w, int h, int pitch, uint8_t *gray, int gpitch) {
    int color = 0;
    for (int y = 0; y < h; y++) {
        const uint8_t *row = rgba + (size_t)y * pitch;
        uint8_t *g = gray + (size_t)y * gpitch;
        int x = 0;
#if defined(__ARM_NEON)
        uint8x16_t spread = vdupq_n_u8(0);
        for (; x + 16 <= w; x += 16) {
            uint8x16x4_t p = vld4q_u8(row + 4 * x);               // de-interleave R, G, B, A
            vst1q_u8(g + x, p.val[1]);
            uint8x16_t hi = vmaxq_u8(vmaxq_u8(p.val[0], p.val[1]), p.val[2]);
            uint8x16_t lo = vminq_u8(vminq_u8(p.val[0], p.val[1]), p.val[2]);
            spread = vmaxq_u8(spread, vsubq_u8(hi, lo));
        }
        if (vmaxvq_u8(spread) > 28) color = 1;
#endif
        for (; x < w; x++) {
            const uint8_t *q = row + 4 * x;
            uint8_t hi = q[0] > q[1] ? q[0] : q[1], lo = q[0] < q[1] ? q[0] : q[1];
            hi = hi > q[2] ? hi : q[2];
            lo = lo < q[2] ? lo : q[2];
            if (hi - lo > 28) color = 1;
            g[x] = q[1];
        }
    }
    return color;
}
