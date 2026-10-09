"""Creative Voice (.VOC) -> WAV."""
import struct
import wave


def voc_to_wav(data, path):
    if not data.startswith(b"Creative Voice File\x1a"):
        raise ValueError("not a VOC file")
    p = struct.unpack_from("<H", data, 20)[0]
    pcm = bytearray()
    rate = 11025
    while p < len(data):
        btype = data[p]
        if btype == 0:
            break
        size = data[p + 1] | (data[p + 2] << 8) | (data[p + 3] << 16)
        body = data[p + 4:p + 4 + size]
        if btype == 1:
            rate = 1000000 // (256 - body[0])
            pcm += body[2:]
        elif btype == 2:
            pcm += body
        p += 4 + size
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(1)
        w.setframerate(rate)
        w.writeframes(bytes(pcm))
    return rate, len(pcm)
