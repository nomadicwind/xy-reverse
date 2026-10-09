"""Softstar RIX music (RX/*.RIX) to WAV.

A Python port of AdPlug's RIX player (src/rix.cpp, "Softstar RIX OPL Format
Player by palxex and BSPAL"), Copyright (C) 1999-2007 Simon Peter et al.,
licensed under the GNU Lesser General Public License 2.1 or later; this file
is under the same licence. The OPL2 chip is emulated by PyOPL (DOSBox's
emulator), an optional dependency: without it music is skipped.

The player is driven at 70 Hz. A song plays once and ends; the game loops it.
"""
import struct
import wave

ADFLAG = (0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 1, 1)
REG_DATA = (0, 1, 2, 3, 4, 5, 8, 9, 10, 11, 12, 13, 16, 17, 18, 19, 20, 21)
AD_C0_OFFS = (0, 1, 2, 0, 1, 2, 3, 4, 5, 3, 4, 5, 6, 7, 8, 6, 7, 8)
MODIFY = (0, 3, 1, 4, 2, 5, 6, 9, 7, 10, 8, 11, 12, 15, 13, 16, 14, 17, 12,
          15, 16, 0, 14, 0, 17, 0, 13, 0)
BD_REG_DATA = (0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x08, 0x04, 0x02, 0x01)

RATE = 49716
REFRESH = 70


def _s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def _cdiv(a, b):
    """C integer division (truncates toward zero)."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q


def _cmod(a, b):
    return a - _cdiv(a, b) * b


class RixPlayer:
    def __init__(self, data, write):
        self.buf = data
        self.length = len(data)
        self.write = write
        self.f_buffer = [0] * 300
        self.a0b0_data2 = [0] * 11
        self.a0b0_data3 = [0] * 18
        self.a0b0_data4 = [0] * 18
        self.a0b0_data5 = [0] * 96
        self.addrs_head = [0] * 96
        self.insbuf = [0] * 28
        self.displace = [0] * 11
        self.reg_bufs = [[0] * 14 for _ in range(18)]
        self.for40reg = [0x7F] * 18
        self.I = 0
        self.mus_block = self.ins_block = 0
        self.rhythm = self.music_on = self.pause_flag = 0
        self.band = self.band_low = 0
        self.e0_reg_flag = 0
        self.bd_modify = 0
        self.sustain = 0
        self.play_end = False
        self.write(1, 32)
        self._ad_initial()
        self._data_initial()

    # ---- set-up
    def _ad_initial(self):
        for i in range(25):
            res = ((i * 24 + 10000) * 52088 // 250000 * 0x24000 // 0x1B503) & 0xFFFFFFFF
            self.f_buffer[i * 12] = (((res & 0xFFFF) + 4) >> 3) & 0xFFFF
            for t in range(1, 12):
                res = int(res * 1.06) & 0xFFFFFFFF
                self.f_buffer[i * 12 + t] = (((res & 0xFFFF) + 4) >> 3) & 0xFFFF
        k = 0
        for i in range(8):
            for j in range(12):
                self.a0b0_data5[k] = i
                self.addrs_head[k] = j
                k += 1
        self.e0_reg_flag = 0x20

    def _data_initial(self):
        b = self.buf
        if 0x0D < self.length:
            self.rhythm = b[2]
            self.mus_block = (b[0x0D] << 8) + b[0x0C]
            self.ins_block = (b[0x09] << 8) + b[0x08]
            self.I = self.mus_block + 1
        else:
            self.I = self.mus_block = self.length
        if self.rhythm != 0:
            self.a0b0_data4[8], self.a0b0_data3[8] = 0, 0x18
            self.a0b0_data4[7], self.a0b0_data3[7] = 0, 0x1F
        self.bd_modify = 0
        self.band = 0
        self.music_on = 1

    # ---- timer tick (int 08h)
    def update(self):
        band_sus = 1
        while band_sus:
            if self.sustain <= 0:
                band_sus = self._rix_proc()
                if band_sus:
                    self.sustain += band_sus
                else:
                    self.play_end = True
                    break
            else:
                self.sustain -= 14
                break
        return not self.play_end

    def _rix_proc(self):
        if self.music_on == 0 or self.pause_flag == 1:
            return 0
        b = self.buf
        self.band = 0
        while self.I < self.length and b[self.I] != 0x80:
            self.band_low = b[self.I - 1]
            ctrl = b[self.I]
            self.I += 2
            hi = ctrl & 0xF0
            if hi == 0x90:
                self._get_ins()
                self._p90(ctrl & 0x0F)
            elif hi == 0xA0:
                self._pA0(ctrl & 0x0F, (self.band_low << 6) & 0xFFFF)
            elif hi == 0xB0:
                self._pB0(ctrl & 0x0F, self.band_low)
            elif hi == 0xC0:
                self._switch_ad_bd(ctrl & 0x0F)
                if self.band_low != 0:
                    self._pC0(ctrl & 0x0F, self.band_low)
            else:
                self.band = ((ctrl << 8) + self.band_low) & 0xFFFF
            if self.band != 0:
                return self.band
        for i in range(11):
            self._switch_ad_bd(i)
        self.I = self.mus_block + 1
        self.band = 0
        self.music_on = 1
        return 0

    def _get_ins(self):
        base = self.ins_block + (self.band_low << 6)
        if base + 56 >= self.length:
            return
        b = self.buf
        for i in range(28):
            self.insbuf[i] = (b[base + i * 2 + 1] << 8) + b[base + i * 2]

    def _p90(self, c):
        if c >= 11:
            return
        ib = self.insbuf
        if self.rhythm == 0 or c < 6:
            self._ins_to_reg(MODIFY[c * 2], ib[0:13], ib[26])
            self._ins_to_reg(MODIFY[c * 2 + 1], ib[13:26], ib[27])
        elif c > 6:
            self._ins_to_reg(MODIFY[c * 2 + 6], ib[0:13], ib[26])
        else:
            self._ins_to_reg(12, ib[0:13], ib[26])
            self._ins_to_reg(15, ib[13:26], ib[27])

    def _pA0(self, c, index):
        if self.rhythm == 0 or c <= 6:
            self._prepare_a0b0(c, 0x3FFF if index > 0x3FFF else index)
            if c < 11:
                self._a0b0l(c, self.a0b0_data3[c], self.a0b0_data4[c])

    def _prepare_a0b0(self, index, v):
        if index >= 11:
            return
        res1 = (v - 0x2000) * 0x19
        low = _s16(_cdiv(res1, 0x2000))
        high = 0
        if low < 0:
            low = _s16(0x18 - low)
            high = 0xFFFF if low < 0 else 0
            res = ((high << 16) + (low & 0xFFFF)) & 0xFFFFFFFF
            low = _s16(_cdiv(_s16(res), _s16(0xFFE7)))
            self.a0b0_data2[index] = low & 0xFFFF
            low = _s16(res)
            res = (low - 0x18) & 0xFFFFFFFF
            high = _s16(_cmod(_s16(res), 0x19))
            low = _s16(_cdiv(_s16(res), 0x19))
            if high != 0:
                low = _s16(0x19 - high)
        else:
            res = high = low
            low = _s16(_cdiv(_s16(res), 0x19))
            self.a0b0_data2[index] = low & 0xFFFF
            res = high
            low = _s16(_cmod(_s16(res), 0x19))
        low = _s16(low * 0x18)
        self.displace[index] = low & 0xFFFF

    def _a0b0l(self, index, p2, p3):
        if index >= 11:
            return
        i = (p2 + self.a0b0_data2[index]) & 0xFFFF
        self.a0b0_data4[index] = p3 & 0xFF
        self.a0b0_data3[index] = p2 & 0xFF
        i = i if _s16(i) <= 0x5F else 0x5F
        i = i if _s16(i) >= 0 else 0
        k = self.addrs_head[i] + self.displace[index] // 2
        data = self.f_buffer[k] if 0 <= k < 300 else 0
        self._bop(0xA0 + index, data)
        data = self.a0b0_data5[i] * 4 + (0 if p3 < 1 else 0x20) + ((data >> 8) & 3)
        self._bop(0xB0 + index, data)

    def _pB0(self, c, index):
        if c >= 11:
            return
        if self.rhythm == 0 or c < 6:
            temp = MODIFY[c * 2 + 1]
        else:
            temp = c * 2 if c > 6 else c * 2 + 1
            temp = MODIFY[temp + 6]
        self.for40reg[temp] = 0x7F if index > 0x7F else index
        self._ad_40(temp)

    def _pC0(self, c, index):
        i = index - 12 if index >= 12 else 0
        if c < 6 or self.rhythm == 0:
            self._a0b0l(c, i, 1)
            return
        if c != 6:
            if c == 8:
                self._a0b0l(c, i, 0)
                self._a0b0l(7, i + 7, 0)
        else:
            self._a0b0l(c, i, 0)
        self.bd_modify |= BD_REG_DATA[c] if c < len(BD_REG_DATA) else 0
        self._ad_bd()

    def _switch_ad_bd(self, index):
        if self.rhythm == 0 or index < 6:
            self._a0b0l(index, self.a0b0_data3[index], 0)
        else:
            self.bd_modify &= ~(BD_REG_DATA[index] if index < len(BD_REG_DATA) else 0) & 0xFF
            self._ad_bd()

    def _ins_to_reg(self, index, insb, value):
        r = self.reg_bufs[index]
        for i in range(13):
            r[i] = insb[i] & 0xFF
        r[13] = value & 3
        self._ad_bd()
        self._bop(8, 0)
        self._ad_40(index)
        self._ad_C0(index)
        r = self.reg_bufs[index]
        self._bop(0x60 + REG_DATA[index], ((r[3] << 4) | (r[6] & 0x0F)) & 0xFF)
        self._bop(0x80 + REG_DATA[index], ((r[4] << 4) | (r[7] & 0x0F)) & 0xFF)
        data = (0 if r[9] < 1 else 0x80) + (0 if r[10] < 1 else 0x40) + \
            (0 if r[5] < 1 else 0x20) + (0 if r[11] < 1 else 0x10) + (r[1] & 0x0F)
        self._bop(0x20 + REG_DATA[index], data)
        self._bop(0xE0 + REG_DATA[index], 0 if self.e0_reg_flag == 0 else (r[13] & 3))

    def _ad_C0(self, index):
        if ADFLAG[index] == 1:
            return
        r = self.reg_bufs[index]
        data = (r[2] * 2) | (1 if r[12] < 1 else 0)
        self._bop(0xC0 + AD_C0_OFFS[index], data)

    def _ad_40(self, index):
        r = self.reg_bufs[index]
        data = (0x3F - (0x3F & r[8])) & 0xFFFF
        data = (data * self.for40reg[index]) & 0xFFFF
        data = (data * 2 + 0x7F) & 0xFFFF
        data = (data // 0xFE - 0x3F) & 0xFFFF
        data = (-data) & 0xFFFF
        data |= r[0] << 6
        self._bop(0x40 + REG_DATA[index], data)

    def _ad_bd(self):
        self._bop(0xBD, (0 if self.rhythm < 1 else 0x20) | self.bd_modify)

    def _bop(self, reg, value):
        self.write(reg & 0xFF, value & 0xFF)


def render(data, path, max_seconds=420, rate=RATE):
    """Plays a RIX file once into a 16-bit mono WAV. Returns the length in
    seconds, or None when PyOPL is not installed."""
    try:
        import pyopl
    except ImportError:
        return None
    chip = pyopl.opl(rate, 2, 1)
    player = RixPlayer(bytes(data), chip.writeReg)
    out = bytearray()
    ticks = 0
    silent_tail = 0
    chunk = bytearray(512 * 2)
    made = 0.0
    while ticks < max_seconds * REFRESH:
        alive = player.update()
        ticks += 1
        # samples owed for this tick (rate / 70 is not whole)
        target = int(ticks * rate / REFRESH)
        need = target - int(made)
        while need > 0:
            n = min(need, 512)
            part = chunk if n == 512 else bytearray(n * 2)
            chip.getSamples(part)
            out += part
            need -= n
            made += n
        if not alive:
            # let the last notes ring out for half a second
            silent_tail += 1
            if silent_tail > REFRESH // 2:
                break
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(bytes(out))
    return ticks / REFRESH


if __name__ == "__main__":
    import sys
    print(render(open(sys.argv[1], "rb").read(), sys.argv[2]))
