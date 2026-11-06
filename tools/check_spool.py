#!/usr/bin/env python3
"""Checks what the simulated printers actually received, without using any app code.

  check_spool.py SPOOL_ROOT [--log LOG ...]

SPOOL_ROOT holds one folder per printer (ppd, urf, pwg, pdf). Spooled files are named by
ippeveprinter after the job, which is the scenario's document name. Expectations live here,
worked out by hand from the test page drawn in SimulatedPrinterTests.swift.
"""
import glob, os, re, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decode_raster import decode

RED, GREEN, BLUE = (255, 0, 0), (0, 255, 0), (0, 0, 255)
A4_300 = (2480, 3508)
UPRIGHT = "upright"
TURNED = "turned"   # landscape sheet a quarter turn anticlockwise onto portrait media

E = {  # scenario: (folder, kind, jobs, per-job [(w, h, pages)], grey, layout, dpi)
    "s01-auto": ("ppd", "urf", [(*A4_300, 1)], False, UPRIGHT, 300),
    "s02-pwg": ("ppd", "pwg", [(*A4_300, 1)], False, UPRIGHT, 300),
    "s03-pdf": ("ppd", "pdf", [(595, 842, 1)], False, UPRIGHT, 300),
    "s04-grey": ("ppd", "urf", [(*A4_300, 1)], True, UPRIGHT, 300),
    "s05-pwggrey": ("ppd", "pwg", [(*A4_300, 1)], True, UPRIGHT, 300),
    "s06-landscape": ("ppd", "urf", [(*A4_300, 1)], False, TURNED, 300),
    "s07-pwglandscape": ("ppd", "pwg", [(*A4_300, 1)], False, TURNED, 300),
    "s08-copies": ("ppd", "urf", [(*A4_300, 6)], False, UPRIGHT, 300),
    "s09-mixed": ("ppd", "urf", [(3508, None, 1), (3508, None, 1)], False, UPRIGHT, 300),
    "s10-roll24": ("ppd", "urf", [(7200, None, 1)], False, UPRIGHT, 300),
    "s11-urfonly": ("urf", "urf", [(4960, 7016, 1)], True, UPRIGHT, 600),
    "s12-pwgonly": ("pwg", "pwg", [(*A4_300, 1)], True, UPRIGHT, 300),
    "s13-pdfonly": ("pdf", "pdf", [(595, 842, 1)], False, UPRIGHT, 300),
    "s15-feeder": ("ppd", "urf", [(*A4_300, 1)], False, UPRIGHT, 300),
    "s16-high": ("pwg", "pwg", [(4960, 7016, 1)], True, UPRIGHT, 600),
    "s17-twoup": ("ppd", "urf", [(*A4_300, 1)], False, "twoup", 300),
    "s18-poster": ("ppd", "urf", [(*A4_300, 4)], False, "poster", 300),
    "s19-banner": ("ppd", "urf", [(7200, 10153, 2)], False, "banner", 300),
}
ORDER = {"s08-copies": [0, 1, 2, 0, 1, 2], "s19-banner": [0, 1]}
# Printer-side refusals these scenarios are meant to hit: the simulator's fixed media list rejects
# custom sizes at Validate-Job, so the app drops media-col and the raster carries its own size.
JOB_PAGE = {("s09-mixed", 1): 1}  # the second batch of a mixed job holds source page 1
failures = []


def fail(name, msg):
    failures.append(f"{name}: {msg}")


def luma(c):
    return (54 * c[0] + 183 * c[1] + 19 * c[2] + 128) >> 8


def near(a, b, tol):
    return all(abs(x - y) <= tol for x, y in zip(a, b))


def sample(get, w, h, fx, fy):
    return get(int(w * fx), int(h * fy))


def check_page(name, get, w, h, grey, layout, page_index, tol):
    """get(x, y) -> (r, g, b)."""
    level = page_index * 60
    grey_at = (level, level, level)
    if layout == "twoup":   # two pages stacked, each a quarter of the sheet's height
        want = {(.4, .12): RED, (.6, .12): GREEN, (.4, .37): BLUE, (.6, .37): (0, 0, 0),
                (.4, .62): RED, (.6, .62): GREEN, (.4, .87): BLUE, (.6, .87): (60, 60, 60),
                (.1, .5): (255, 255, 255), (.9, .5): (255, 255, 255)}
        for (fx, fy), colour in want.items():
            got = sample(get, w, h, fx, fy)
            if not near(got, colour, tol):
                fail(name, f"at ({fx},{fy}): got {got}, want {colour}")
        return
    if layout == "poster":  # 2x2 tiles of one A4 page, each tile one flat quadrant
        colour = [RED, GREEN, BLUE, (0, 0, 0)][page_index]
        got = sample(get, w, h, .5, .5)
        if not near(got, colour, tol):
            fail(name, f"tile {page_index}: got {got}, want {colour}")
        return
    if layout == "banner":  # page fills the width; the sheet ends at the page plus its 3 mm margin
        want = {(.3, .2): RED, (.7, .2): GREEN, (.3, .6): BLUE, (.7, .6): grey_at, (.5, .999): (255, 255, 255)}
        for (fx, fy), colour in want.items():
            got = sample(get, w, h, fx, fy)
            if not near(got, colour, tol):
                fail(name, f"page {page_index} at ({fx},{fy}): got {got}, want {colour}")
        return
    if layout == UPRIGHT:
        want = {(.3, .3): RED, (.7, .3): GREEN, (.3, .7): BLUE}
        br = (.7, .7)
    else:
        want = {(.3, .7): RED, (.3, .3): GREEN, (.7, .7): BLUE}
        br = (.7, .3)
    want[br] = grey_at
    for (fx, fy), colour in want.items():
        got = sample(get, w, h, fx, fy)
        expect = (luma(colour),) * 3 if grey else colour
        if not near(got, expect, tol):
            fail(name, f"page {page_index} at ({fx},{fy}): got {got}, want {expect}")


def raster(name, path, spec, kind, job_page=0):
    w_want, h_want, pages_want = spec[0]
    _, _, _, grey, layout, dpi = None, None, None, spec[1], spec[2], spec[3]
    data = open(path, "rb").read()
    got_kind, pages = decode(data)
    if got_kind.lower()[:3] != kind:
        fail(name, f"kind {got_kind}, want {kind}")
    if len(pages) != pages_want:
        fail(name, f"{len(pages)} pages, want {pages_want}")
    order = ORDER.get(name)
    for i, (info, px) in enumerate(pages):
        w, h, bpp = info["width"], info["height"], info["bpp"]
        if abs(w - w_want) > 1 or (h_want and abs(h - h_want) > 1):
            fail(name, f"page {i}: {w}x{h}, want {w_want}x{h_want}")
        if info["dpi"][0] != dpi:
            fail(name, f"dpi {info['dpi']}")
        if bpp != (1 if grey else 3):
            fail(name, f"{bpp} bytes a pixel, grey={grey}")

        def get(x, y):
            o = (y * w + x) * bpp
            return tuple(px[o:o + 3]) if bpp == 3 else (px[o],) * 3
        index = order[i] if order else i if layout == "poster" else job_page
        check_page(name, get, w, h, grey, layout, index, 1 if not grey else 2)
    # rastertotiff refuses every sgray file, CUPS's own reference file included ("unsupported color
    # space 18"), so it can only be a second reader for colour. Grey PWG is covered by the byte
    # comparison with rastertopwg in RasterEncoderTests.
    if kind == "pwg" and not grey:
        cups_cross_check(name, path, pages[0][0], grey, layout)
    return pages


def cups_cross_check(name, path, info, grey, layout):
    """Second reader: Apple's CUPS filter has to accept the same file and see the same picture."""
    from PIL import Image
    Image.MAX_IMAGE_PIXELS = None
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "p.tiff")
        with open(path, "rb") as src, open(out, "wb") as dst:
            r = subprocess.run(["/usr/libexec/cups/filter/rastertotiff", "1", "u", "t", "1", ""],
                               stdin=src, stdout=dst, stderr=subprocess.PIPE,
                               env={"CONTENT_TYPE": "image/pwg-raster", "PATH": "/usr/bin:/bin"})
        if r.returncode:
            fail(name, f"rastertotiff exit {r.returncode}: {r.stderr[-200:]}")
            return
        img = Image.open(out).convert("RGB")
        w, h = img.size
        if (w, h) != (info["width"], info["height"]):
            fail(name, f"rastertotiff saw {w}x{h}")
        check_page(name + " (rastertotiff)", lambda x, y: img.getpixel((x, y)), w, h, grey, layout, 0, 2)


def pdf(name, path, spec):
    w_want, h_want, pages_want = spec[0]
    data = open(path, "rb").read()
    if not data.startswith(b"%PDF-"):
        fail(name, "not a PDF")
    n = len(re.findall(rb"/Type\s*/Page\b", data))
    if n != pages_want:
        fail(name, f"{n} PDF pages, want {pages_want}")
    with tempfile.TemporaryDirectory() as d:
        png = os.path.join(d, "p.png")
        subprocess.run(["/usr/bin/sips", "-s", "format", "png", path, "--out", png],
                       check=True, capture_output=True)
        from PIL import Image, ImageCms
        import io
        img = Image.open(png)
        # sips renders into Display P3; compare in sRGB, the space the page was drawn in
        icc = img.info.get("icc_profile")
        if icc:
            img = ImageCms.profileToProfile(img.convert("RGB"), ImageCms.ImageCmsProfile(io.BytesIO(icc)),
                                            ImageCms.createProfile("sRGB"), outputMode="RGB")
        img = img.convert("RGB")
        w, h = img.size
        if abs(w - w_want) > 2 or abs(h - h_want) > 2:
            fail(name, f"PDF page {w}x{h}, want {w_want}x{h_want}")
        check_page(name, lambda x, y: img.getpixel((x, y)), w, h, False, spec[2], 0, 40)


def main():
    root = sys.argv[1]
    for name, (folder, kind, jobs, grey, layout, dpi) in E.items():
        files = sorted(
            (f for f in glob.glob(os.path.join(root, folder, "**", f"*{name}*"), recursive=True)
             if os.path.isfile(f) and not f.endswith(".prn")),  # .prn is the empty output of the fake print command
            key=lambda f: int(re.match(r"(\d+)", os.path.basename(f)).group(1)))
        if len(files) != len(jobs):
            fail(name, f"{len(files)} spooled files, want {len(jobs)}: {files}")
            continue
        heights = []
        for n, (path, job) in enumerate(zip(files, jobs)):
            size = os.path.getsize(path)
            print(f"{name}: {os.path.basename(path)} {size:,} bytes")
            try:
                if kind == "pdf":
                    pdf(name, path, (job, grey, layout, dpi))
                else:
                    pages = raster(name, path, (job, grey, layout, dpi), kind, JOB_PAGE.get((name, n), 0))
                    heights.append(pages[0][0]["height"])
            except Exception as e:
                fail(name, f"{type(e).__name__}: {e}")
        if name == "s09-mixed" and len(set(heights)) != 2:
            fail(name, f"mixed sizes gave heights {heights}")
    for log in glob.glob(os.path.join(root, "*.log")):
        if os.path.basename(log) in ("xcodebuild.log", "fake.log"):
            continue
        text = open(log, errors="replace").read()
        bad = sorted(set(re.findall(r"(?:client|server)-error-[a-z-]+", text)))
        # the attribute names printers list as *-supported are fine; a status line is not
        bad = [b for b in bad if re.search(rf"status-code={b}|\s{b}$", text, re.M)]
        if os.path.basename(log) == "ppd.log":
            bad = [b for b in bad if b != "client-error-attributes-or-values-not-supported"]
        if bad:
            fail(os.path.basename(log), f"printer answered {bad}")
        jobs = len(re.findall(r"Print-Job successful-ok", text))
        print(f"{os.path.basename(log)}: {jobs} Print-Job accepted")
    print()
    if failures:
        print(f"FAILED, {len(failures)} problems:")
        for f in failures:
            print(" ", f)
        sys.exit(1)
    print(f"spool check passed: {len(E)} scenarios")


main()
