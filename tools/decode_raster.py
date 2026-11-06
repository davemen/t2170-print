#!/usr/bin/env python3
"""Independent PWG Raster / Apple URF decoder.

Written from the file formats, not from the app's encoder, so a shared misreading
of the format cannot hide. Used by test-sim.sh to check what a simulated printer
actually received.

  decode_raster.py FILE [--json] [--png-prefix PREFIX]

Exits non-zero on any structural problem: bad magic, a compression byte of 128,
a line that over- or under-runs, trailing bytes, or a page count that disagrees
with the file header.
"""
import argparse, json, struct, sys


class Bad(Exception):
    pass


def decode_lines(buf, pos, width, height, bpp):
    """Returns (bytes of the page, new position, stats)."""
    line_bytes = width * bpp
    out = bytearray()
    done = 0
    repeats = 0
    while done < height:
        if pos >= len(buf):
            raise Bad(f"file ended at line {done} of {height}")
        rep = buf[pos] + 1
        pos += 1
        if done + rep > height:
            raise Bad(f"line repeat of {rep} at line {done} passes page height {height}")
        line = bytearray()
        while len(line) < line_bytes:
            if pos >= len(buf):
                raise Bad(f"file ended inside line {done}")
            op = buf[pos]
            pos += 1
            if op == 128:
                raise Bad(f"compression byte 128 at offset {pos - 1}")
            if op < 128:
                n = op + 1
                px = buf[pos:pos + bpp]
                pos += bpp
                if len(px) != bpp:
                    raise Bad("file ended inside a run")
                line += px * n
            else:
                n = 257 - op
                chunk = buf[pos:pos + n * bpp]
                pos += n * bpp
                if len(chunk) != n * bpp:
                    raise Bad("file ended inside a literal")
                line += chunk
        if len(line) != line_bytes:
            raise Bad(f"line {done} decoded to {len(line)} bytes, wanted {line_bytes}")
        out += bytes(line) * rep
        repeats = max(repeats, rep)
        done += rep
    return bytes(out), pos, {"max_line_repeat": repeats}


def u32(b, off):
    return struct.unpack_from(">I", b, off)[0]


def cstr(b):
    return b.split(b"\0", 1)[0].decode("ascii", "replace")


def decode_pwg(buf):
    pages = []
    pos = 4
    while pos < len(buf):
        h = buf[pos:pos + 1796]
        if len(h) != 1796:
            raise Bad(f"short page header at {pos}")
        pos += 1796
        if cstr(h[0:64]) != "PwgRaster":
            raise Bad("page header does not start with PwgRaster")
        info = {
            "dpi": (u32(h, 276), u32(h, 280)),
            "page_pt": (u32(h, 352), u32(h, 356)),
            "width": u32(h, 372), "height": u32(h, 376),
            "bits_color": u32(h, 384), "bits_pixel": u32(h, 388),
            "bytes_line": u32(h, 392), "color_order": u32(h, 396),
            "color_space": u32(h, 400), "colors": u32(h, 420),
            "total_pages": u32(h, 452), "cross_feed": u32(h, 456), "feed": u32(h, 460),
            "alternate_primary": u32(h, 480), "quality": u32(h, 484),
            "bbox": (u32(h, 284), u32(h, 288), u32(h, 292), u32(h, 296)),
            "image_box": tuple(u32(h, o) for o in (464, 468, 472, 476)),
            "page_name": cstr(h[1732:1796]),
        }
        if info["bits_color"] != 8 or info["bits_pixel"] not in (8, 24):
            raise Bad(f"bit depth {info['bits_color']}/{info['bits_pixel']}")
        bpp = info["bits_pixel"] // 8
        if info["bytes_line"] != info["width"] * bpp:
            raise Bad("BytesPerLine disagrees with width")
        if info["color_space"] != (19 if bpp == 3 else 18):
            raise Bad(f"colour space {info['color_space']} for {bpp} bytes a pixel")
        if info["colors"] != bpp:
            raise Bad("NumColors disagrees with bits per pixel")
        if info["dpi"][0] != info["dpi"][1]:
            raise Bad("unequal resolution")
        for axis, px, pt in (("x", info["width"], info["page_pt"][0]), ("y", info["height"], info["page_pt"][1])):
            want = pt * info["dpi"][0] / 72
            if abs(px - want) > info["dpi"][0] / 72 + 1:
                raise Bad(f"{axis}: {px} px does not match {pt} pt at {info['dpi'][0]} dpi")
        data, pos, stats = decode_lines(buf, pos, info["width"], info["height"], bpp)
        info.update(stats, bpp=bpp)
        pages.append((info, data))
    return pages


def decode_urf(buf):
    declared = u32(buf, 8)
    pos = 12
    pages = []
    while pos < len(buf):
        h = buf[pos:pos + 32]
        if len(h) != 32:
            raise Bad(f"short page header at {pos}")
        pos += 32
        bits, space, duplex, quality = h[0], h[1], h[2], h[3]
        if (bits, space) not in ((24, 1), (8, 0)):
            raise Bad(f"bits {bits}, colour space {space}")
        if duplex != 1:
            raise Bad(f"duplex byte {duplex}")
        if any(h[4:12]) or any(h[24:32]):
            raise Bad("reserved header bytes not zero")
        info = {"width": u32(h, 12), "height": u32(h, 16), "dpi": (u32(h, 20), u32(h, 20)),
                "quality": quality, "bpp": bits // 8}
        data, pos, stats = decode_lines(buf, pos, info["width"], info["height"], info["bpp"])
        info.update(stats)
        pages.append((info, data))
    if len(pages) != declared:
        raise Bad(f"file header says {declared} pages, found {len(pages)}")
    return pages


def decode(buf):
    if buf[:4] == b"RaS2":
        return "pwg", decode_pwg(buf)
    if buf[:8] == b"UNIRAST\0":
        return "urf", decode_urf(buf)
    raise Bad(f"unknown magic {buf[:8]!r}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--png-prefix")
    a = ap.parse_args()
    with open(a.file, "rb") as f:
        buf = f.read()
    try:
        kind, pages = decode(buf)
    except Bad as e:
        print(f"BAD {a.file}: {e}", file=sys.stderr)
        return 1
    if a.png_prefix:
        from PIL import Image
        for i, (info, data) in enumerate(pages):
            mode = "RGB" if info["bpp"] == 3 else "L"
            Image.frombytes(mode, (info["width"], info["height"]), data).save(f"{a.png_prefix}-{i + 1}.png")
    summary = {"format": kind, "pages": [i for i, _ in pages]}
    print(json.dumps(summary) if a.json else f"{kind}: {len(pages)} page(s) " + "; ".join(
        f"{i['width']}x{i['height']} @{i['dpi'][0]} bpp{i['bpp']}" for i, _ in pages))
    return 0


if __name__ == "__main__":
    sys.exit(main())
