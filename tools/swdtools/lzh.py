"""LZH decompressor for SWDA (轩辕剑外传：枫之舞) compressed blocks.

Reimplemented from RPG.EXE far proc 0AF8:38AC.
Block layout: u16 unpacked_size, u8 method (0 = stored, else LZH), bitstream.
The LZH stream is LHA -lh5- style static Huffman with NT=19/TBIT=5,
NC=510/CBIT=9, NP=17/PBIT=5 and a 16-bit block-size prefix per block.
Matches copy straight from the output buffer (no ring), dist = p + 1.
"""
import struct


class _Bits:
    def __init__(self, data, pos):
        self.d = data
        self.pos = pos
        self.acc = 0
        self.n = 0

    def get(self, k):
        while self.n < k:
            b = self.d[self.pos] if self.pos < len(self.d) else 0
            self.pos += 1
            self.acc = (self.acc << 8) | b
            self.n += 8
        self.n -= k
        v = (self.acc >> self.n) & ((1 << k) - 1)
        self.acc &= (1 << self.n) - 1
        return v

    def peek(self, k):
        save = (self.pos, self.acc, self.n)
        v = self.get(k)
        self.pos, self.acc, self.n = save
        return v


class _Huff:
    """Canonical Huffman (LHA make_table assigns codes in symbol order by length)."""

    def __init__(self, lens, single=None):
        self.single = single
        if single is not None:
            return
        self.table = {}
        code = 0
        for L in range(1, 17):
            for sym, l in enumerate(lens):
                if l == L:
                    self.table[(L, code)] = sym
                    code += 1
            code <<= 1

    def decode(self, br):
        if self.single is not None:
            return self.single
        code = 0
        for L in range(1, 17):
            code = (code << 1) | br.get(1)
            s = self.table.get((L, code))
            if s is not None:
                return s
        raise ValueError("bad huffman code")


def _read_pt(br, nn, nbit, ispecial):
    n = br.get(nbit)
    if n == 0:
        return _Huff(None, single=br.get(nbit)), None
    lens = []
    while len(lens) < n:
        c = br.get(3)
        if c == 7:
            while br.get(1):
                c += 1
        lens.append(c)
        if len(lens) == ispecial:
            lens.extend([0] * br.get(2))
    lens += [0] * (nn - len(lens))
    return _Huff(lens[:nn]), lens


def _read_c(br, pt):
    n = br.get(9)
    if n == 0:
        return _Huff(None, single=br.get(9))
    lens = []
    while len(lens) < n:
        c = pt.decode(br)
        if c <= 2:
            if c == 0:
                cnt = 1
            elif c == 1:
                cnt = br.get(4) + 3
            else:
                cnt = br.get(9) + 20
            lens.extend([0] * cnt)
        else:
            lens.append(c - 2)
    lens += [0] * (510 - len(lens))
    return _Huff(lens[:510])


def decompress(block):
    size = struct.unpack_from("<H", block, 0)[0]
    method = block[2]
    if method == 0:
        return bytes(block[3:3 + size])
    br = _Bits(block, 3)
    out = bytearray()
    left = 0
    while len(out) < size:
        if left == 0:
            left = br.get(16)
            pt, _ = _read_pt(br, 19, 5, 3)
            c = _read_c(br, pt)
            p, _ = _read_pt(br, 17, 5, -1)
        left -= 1
        sym = c.decode(br)
        if sym < 256:
            out.append(sym)
            continue
        length = sym - 253
        d = p.decode(br)
        if d:
            d = (1 << (d - 1)) + br.get(d - 1)
        src = len(out) - d - 1
        for i in range(length):
            out.append(out[src + i])
    return bytes(out[:size])
