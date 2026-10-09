"""Pictures, palettes and conversion to RGBA."""
import struct

TRANSPARENT = 0xFE


def vga_palette(pal6):
    """768 bytes of 6-bit VGA RGB -> list of (r, g, b) tuples."""
    return [tuple(pal6[i * 3 + k] * 255 // 63 for k in range(3)) for i in range(len(pal6) // 3)]


def decode_pic(chunk):
    """Picture chunk: u16 h, u16 w, then raw w*h bytes or b'NT' + RLE.

    RLE is per Mode X plane row: 0xFF ends a row of w/4 pixels, 0x80|n copies
    n literal bytes, n < 0x80 repeats the next byte n times. Rows are stored
    plane-major. Returns (w, h, indexed_pixels) in row-major order.
    """
    h, w = struct.unpack_from("<HH", chunk, 0)
    if chunk[4:6] != b"NT":
        return w, h, bytes(chunk[4:4 + w * h])
    q = (w + 3) // 4
    segs, cur, p = [], bytearray(), 6
    while p < len(chunk) and len(segs) < 4 * h:
        c = chunk[p]
        p += 1
        if c == 0xFF:
            segs.append(cur)
            cur = bytearray()
        elif c & 0x80:
            cur += chunk[p:p + (c & 0x7F)]
            p += c & 0x7F
        else:
            cur += bytes([chunk[p]]) * c
            p += 1
    out = bytearray([TRANSPARENT]) * (w * h)
    for i, s in enumerate(segs):
        plane, row = divmod(i, h)
        for x, v in enumerate(s[:q]):
            if x * 4 + plane < w:
                out[row * w + x * 4 + plane] = v
    return w, h, bytes(out)


def to_rgba(w, h, pixels, palette, transparent=TRANSPARENT):
    """Indexed pixels -> PIL RGBA image (transparent index gets alpha 0)."""
    from PIL import Image
    buf = bytearray()
    for v in pixels:
        r, g, b = palette[v]
        buf += bytes((r, g, b, 0 if v == transparent and transparent is not None else 255))
    return Image.frombytes("RGBA", (w, h), bytes(buf))
