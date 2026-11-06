#!/usr/bin/env python3
"""A deliberately misbehaving IPP printer for failure testing.

    tools/fake_ipp.py PORT

The first path segment picks the behaviour, so ipp://localhost:PORT/busy-twice/ipp/print is a printer
that answers busy twice. Each scenario keeps its own counters. GET /__log/<scenario> returns JSON with
what that printer received, read from the wire: HTTP headers, body length, IPP version, request id,
attributes, and the size in the raster header. Document bodies are counted, not stored.
"""
import json
import socket
import socketserver
import struct
import sys
import threading
import time

OK, OK_IGNORED = 0x0000, 0x0001
BAD_REQUEST, NOT_FOUND, UNSUPPORTED_ATTR, BAD_FORMAT = 0x0400, 0x0406, 0x040B, 0x040A
SERVER_ERROR, BAD_VERSION, NOT_ACCEPTING, BUSY = 0x0500, 0x0503, 0x0506, 0x0507
OPS = {0x02: "Print-Job", 0x04: "Validate-Job", 0x08: "Cancel-Job", 0x09: "Get-Job-Attributes",
       0x0B: "Get-Printer-Attributes"}
INT, BOOL, ENUM = 0x21, 0x22, 0x23
RES, RANGE, TEXT, NAME = 0x32, 0x33, 0x41, 0x42
KEYWORD, URI, CHARSET, LANG, MIME = 0x44, 0x45, 0x47, 0x48, 0x49

# ---------------------------------------------------------------- encoding


def raw(tag, name, value):
    n = name.encode()
    return bytes([tag]) + struct.pack(">H", len(n)) + n + struct.pack(">H", len(value)) + value


def enc(tag, v):
    if tag in (INT, ENUM):
        return struct.pack(">i", v)
    if tag == BOOL:
        return bytes([1 if v else 0])
    if tag == RANGE:
        return struct.pack(">ii", v[0], v[1])
    if tag == RES:
        return struct.pack(">iib", v[0], v[1], v[2] if len(v) > 2 else 3)
    return v.encode() if isinstance(v, str) else v


def attr(tag, name, *values):
    out = b""
    for i, v in enumerate(values):
        out += raw(tag, name if i == 0 else "", enc(tag, v))
    return out


def collection(name, members):
    """members: [(member name, tag, value)], where tag None means value is an encoded collection body."""
    out = raw(0x34, name, b"")
    for member, tag, value in members:
        out += raw(0x4A, "", member.encode())
        out += value if tag is None else raw(tag, "", enc(tag, value))
    return out + raw(0x37, "", b"")


def media_entry(name, x, y, source=None):
    size = collection("", [("x-dimension", RANGE if isinstance(x, tuple) else INT, x),
                           ("y-dimension", RANGE if isinstance(y, tuple) else INT, y)])
    members = [("media-size", None, size)]
    if source:
        members.append(("media-source", KEYWORD, source))
    return collection(name, members)


def media_database(entries):
    return b"".join(media_entry("media-col-database" if i == 0 else "", *e) for i, e in enumerate(entries))


BASE_MEDIA = [
    (21000, 29700, "manual"), (21000, 29700, "auto"), (29700, 42000, "manual"), (42000, 59400, "manual"),
    (59400, 84100, "manual"), (60960, (10000, 1800000), "roll-1"), (43180, (10000, 1800000), "roll-1"),
    (29700, (10000, 1800000), "roll-1"), ((21000, 61000), (10000, 1800000), "roll-1"),
]


def base_printer():
    return {
        "printer-uri-supported": attr(URI, "printer-uri-supported", "ipp://localhost/ipp/print"),
        "uri-security-supported": attr(KEYWORD, "uri-security-supported", "none"),
        "printer-name": attr(NAME, "printer-name", "Fake T2170"),
        "printer-make-and-model": attr(TEXT, "printer-make-and-model", "Fake SC-T2170"),
        "printer-state": attr(ENUM, "printer-state", 3),
        "printer-state-reasons": attr(KEYWORD, "printer-state-reasons", "none"),
        "printer-is-accepting-jobs": attr(BOOL, "printer-is-accepting-jobs", True),
        "ipp-versions-supported": attr(KEYWORD, "ipp-versions-supported", "1.1", "2.0"),
        "operations-supported": attr(ENUM, "operations-supported", 2, 4, 8, 9, 11),
        "document-format-supported": attr(MIME, "document-format-supported", "application/octet-stream",
                                          "image/urf", "image/pwg-raster", "application/pdf"),
        "urf-supported": attr(KEYWORD, "urf-supported", "V1.4", "CP1", "W8", "SRGB24", "RS300-600"),
        "pwg-raster-document-type-supported": attr(KEYWORD, "pwg-raster-document-type-supported", "sgray_8", "srgb_8"),
        "pwg-raster-document-resolution-supported": attr(RES, "pwg-raster-document-resolution-supported",
                                                         (300, 300), (600, 600)),
        "media-supported": attr(KEYWORD, "media-supported", "iso_a4_210x297mm", "iso_a3_297x420mm"),
        "media-default": attr(KEYWORD, "media-default", "iso_a4_210x297mm"),
        "media-source-supported": attr(KEYWORD, "media-source-supported", "auto", "manual", "roll-1"),
        "media-type-supported": attr(KEYWORD, "media-type-supported", "stationery", "photographic"),
        "media-col-database": media_database(BASE_MEDIA),
        "print-quality-supported": attr(ENUM, "print-quality-supported", 3, 4, 5),
        "print-color-mode-supported": attr(KEYWORD, "print-color-mode-supported", "auto", "color", "monochrome"),
        "finishings-supported": attr(ENUM, "finishings-supported", 3, 11, 60, 61, 62, 63),
        "copies-supported": attr(RANGE, "copies-supported", (1, 999)),
        "sides-supported": attr(KEYWORD, "sides-supported", "one-sided"),
        "print-scaling-supported": attr(KEYWORD, "print-scaling-supported", "none", "fit"),
        "number-up-supported": attr(INT, "number-up-supported", 1),
        "marker-names": attr(NAME, "marker-names", "Black", "Cyan", "Magenta", "Yellow"),
        "marker-levels": attr(INT, "marker-levels", 80, 60, 40, 20),
        "marker-colors": attr(NAME, "marker-colors", "#000000", "#00FFFF", "#FF00FF", "#FFFF00"),
        "marker-types": attr(KEYWORD, "marker-types", "ink-cartridge", "ink-cartridge", "ink-cartridge", "ink-cartridge"),
    }


def odd_extras():
    p = base_printer()
    p["printer-state-message"] = raw(0x13, "printer-state-message", b"")
    p["printer-info"] = raw(0x35, "printer-info", struct.pack(">H", 2) + b"en" + struct.pack(">H", 4) + b"Tiki")
    p["printer-location"] = raw(0x36, "printer-location", b"\x00")
    p["x-ext"] = raw(0x7F, "x-ext", b"\x40\x00\x00\x01abc")
    p["x-odd"] = raw(0x3F, "x-odd", b"\x01\x02")
    p["media-col-default"] = raw(0x12, "media-col-default", b"")
    p["printer-more-info"] = raw(URI, "printer-more-info", b"")
    p["printer-current-time"] = raw(0x31, "printer-current-time", bytes(11))
    p["copies-supported"] = attr(INT, "copies-supported", 1)
    p["print-quality-supported"] = raw(0x12, "print-quality-supported", b"")
    p["printer-resolution-supported"] = attr(RES, "printer-resolution-supported", (118, 118, 4))
    p["marker-levels"] = attr(INT, "marker-levels", -3, -2)
    p["x-utf8"] = raw(NAME, "x-utf8", b"\xff\xfe\xfa")
    return p


def wrong_lengths():
    p = base_printer()
    p["printer-up-time"] = raw(INT, "printer-up-time", b"\x00\x01")
    p["printer-state-change-time"] = raw(ENUM, "x-short-enum", b"")
    p["printer-current-time"] = raw(0x31, "printer-current-time", b"\x07")
    p["printer-resolution-default"] = raw(RES, "printer-resolution-default", b"\x00\x01")
    p["pages-per-minute"] = raw(RANGE, "x-short-range", b"\x00")
    p["color-supported"] = raw(BOOL, "color-supported", b"")
    return p


def printer_for(scenario, n=1):
    if scenario == "odd-values":
        return odd_extras()
    if scenario == "wrong-lengths":
        return wrong_lengths()
    p = base_printer()
    if scenario == "empty-mcd":
        del p["media-col-database"]
        p["media-col-database"] = raw(0x13, "media-col-database", b"")
    elif scenario == "huge-mcd":
        p["media-col-database"] = media_database(
            BASE_MEDIA + [(10000 + i, 20000 + i, "manual") for i in range(2000)])
    elif scenario == "sparse":
        keep = ("document-format-supported", "urf-supported")
        p = {k: v for k, v in p.items() if k in keep}
        p["document-format-supported"] = attr(MIME, "document-format-supported", "image/urf")
    elif scenario == "stopped":
        p["printer-state"] = attr(ENUM, "printer-state", 5)
        p["printer-state-reasons"] = attr(KEYWORD, "printer-state-reasons", "media-empty-error", "cover-open-report")
    elif scenario == "refuse-media-size-pdf":
        p["document-format-supported"] = attr(MIME, "document-format-supported", "application/pdf")
        for key in ("urf-supported", "pwg-raster-document-type-supported", "pwg-raster-document-resolution-supported"):
            del p[key]
    elif scenario == "octet-only":
        p["document-format-supported"] = attr(MIME, "document-format-supported", "application/octet-stream")
        for key in ("urf-supported", "pwg-raster-document-type-supported", "pwg-raster-document-resolution-supported"):
            del p[key]
    elif scenario == "no-custom":
        p["media-col-database"] = media_database(BASE_MEDIA[:5])
    if scenario == "paused-now" and n > 1:
        p["printer-is-accepting-jobs"] = attr(BOOL, "printer-is-accepting-jobs", False)
    if scenario == "wrong-roll":
        p["media-col-ready"] = media_entry("media-col-ready", 43180, (10000, 1800000), "roll-1")
    if scenario == "right-roll":
        p["media-col-ready"] = media_entry("media-col-ready", 29700, (10000, 1800000), "roll-1")
    return p


# ---------------------------------------------------------------- scenario behaviour


def ipp(status, extra=b""):
    return ("ipp", status, extra)


def unsupported_col(*members):
    return ("ipp", UNSUPPORTED_ATTR, b"\x05" + collection("media-col", [(m, KEYWORD, "x") for m in members]))


def unsupported(*names):
    return ("ipp", UNSUPPORTED_ATTR, b"\x05" + b"".join(raw(0x10, n, b"") for n in names))


def only_format(fmt, action):
    return lambda n, r: action if r["format"] == fmt else None


def while_media_col(action):
    # The first check of each request happens before its attributes are read, hence .get.
    return lambda n, r: action if "media-col" in r.get("attrs", {}) else None


def echo_then_while_media_col(echo, action):
    return lambda n, r: echo if n == 1 else while_media_col(action)(n, r)


def first(count, action):
    return lambda n, r: action if n <= count else None


ALWAYS = 1 << 30
HOOKS = {
    "print-refuse-urf": {"Print-Job": only_format("image/urf", ipp(BAD_FORMAT))},
    "validate-refuse-urf": {"Validate-Job": only_format("image/urf", ipp(BAD_FORMAT))},
    "print-040b-format": {"Print-Job": only_format("image/urf", unsupported("document-format"))},
    "refuse-all": {"Print-Job": first(ALWAYS, ipp(BAD_FORMAT))},
    "drop-media-col": {"Print-Job": first(1, unsupported("media-col"))},
    "always-040b": {"Print-Job": first(ALWAYS, unsupported("media-col"))},
    "validate-040b": {"Validate-Job": first(1, unsupported("finishings"))},
    "validate-500": {"Validate-Job": first(ALWAYS, ipp(SERVER_ERROR))},
    "busy-twice": {"Print-Job": first(2, ipp(BUSY))},
    "busy-forever": {"Print-Job": first(ALWAYS, ipp(BUSY))},
    "not-accepting": {"Print-Job": first(ALWAYS, ipp(NOT_ACCEPTING))},
    "bad-request": {"Print-Job": first(ALWAYS, ipp(BAD_REQUEST))},
    "server-error": {"Print-Job": first(ALWAYS, ipp(SERVER_ERROR))},
    "drop-mid-body": {"Print-Job": first(1, ("rst_mid",))},
    "drop-after-body": {"Print-Job": first(1, ("close",))},
    "poll-drop-3": {"Get-Job-Attributes": first(3, ("close",))},
    "poll-drop-forever": {"Get-Job-Attributes": first(ALWAYS, ("close",))},
    "poll-500-forever": {"Get-Job-Attributes": first(ALWAYS, ipp(SERVER_ERROR))},
    "connect-html": {"Get-Printer-Attributes": first(ALWAYS, ("http", 200, "text/html", b"<html>hello</html>"))},
    "connect-426": {"Get-Printer-Attributes": first(ALWAYS, ("http", 426, "text/plain", b"Upgrade Required"))},
    "connect-401": {"Get-Printer-Attributes": first(ALWAYS, ("http", 401, "text/plain", b"Unauthorized"))},
    "connect-garbage": {"Get-Printer-Attributes": first(ALWAYS, ("http", 200, "application/ipp", bytes(range(200))))},
    "connect-short": {"Get-Printer-Attributes": first(ALWAYS, ("http", 200, "application/ipp", b"\x02\x00"))},
    "connect-truncated": {"Get-Printer-Attributes": first(ALWAYS, ("truncated",))},
    "connect-drop": {"Get-Printer-Attributes": first(ALWAYS, ("close",))},
    "connect-refuse-list": {"Get-Printer-Attributes": first(1, ipp(BAD_REQUEST))},
    "print-html": {"Print-Job": first(ALWAYS, ("http", 200, "text/html", b"<html>nope</html>"))},
    "print-garbage": {"Print-Job": first(ALWAYS, ("http", 200, "application/ipp", bytes(range(200))))},
    "no-job-id": {"Print-Job": first(ALWAYS, ipp(OK))},
    "ok-ignored": {"Print-Job": first(ALWAYS, ("job", OK_IGNORED, b"\x05" + attr(KEYWORD, "finishings", "x")))},
    "stall-validate": {"Validate-Job": first(1, ("stall", 75))},
    "retry-after-failure": {"Print-Job": first(1, ipp(SERVER_ERROR))},
    "drop-media-source": {"Print-Job": first(1, unsupported_col("media-source"))},
    "echo-media-col": {"Print-Job": first(1, unsupported_col("media-size", "media-source", "media-type"))},
    "refuse-media-size": {"Print-Job": first(ALWAYS, unsupported_col("media-size"))},
    "refuse-media-size-pdf": {"Print-Job": first(ALWAYS, unsupported_col("media-size"))},
    "refuse-media-size-roll": {"Print-Job": while_media_col(unsupported_col("media-size"))},
    "refuse-media-col-roll": {"Print-Job": while_media_col(unsupported("media-col"))},
    "echo-then-size-roll": {"Print-Job": echo_then_while_media_col(
        unsupported_col("media-size", "media-source", "media-type"), unsupported_col("media-size"))},
}

# State for each poll; the last one repeats. An int is a job state, ("gone",) is job-not-found.
POLLS = {
    "job-gone": [5, ("gone",)],
    "job-gone-multi": [5, ("gone",)],
    "job-gone-at-once": [("gone",)],
    "job-aborted": [5, (8, "document-format-error")],
    "job-canceled": [5, (7, "job-canceled-at-device")],
    "job-stopped": [5, (6, "media-empty-error"), 5, 9],
    "job-cancel": [5],
    "job-unknown-state": [99, 9],
}
INSTANT = {"job-instant"}
NO_STATE = {"no-job-state"}
# Scenarios whose printer speaks IPP/1.1 only.
OLD_VERSION = {"version-503"}
CHUNKED = {"chunked"}
CONN_CLOSE = {"conn-close"}
CONTINUE = {"continue-100"}

STATE = {}
LOCK = threading.Lock()


def scenario_state(name):
    with LOCK:
        return STATE.setdefault(name, {"counts": {}, "log": [], "cancelled": False, "next_job": 100})


# ---------------------------------------------------------------- reading requests


def decode_value(tag, v):
    if tag in (INT, ENUM) and len(v) == 4:
        return str(struct.unpack(">i", v)[0])
    if tag == BOOL and v:
        return "true" if v[0] else "false"
    if tag == RANGE and len(v) == 8:
        return "%d-%d" % struct.unpack(">ii", v)
    if 0x41 <= tag <= 0x4A:
        return v.decode("utf-8", "replace")
    return v.hex()


def parse_ipp(b):
    attrs, top, depth, member, i = {}, None, 0, None, 8
    while i < len(b):
        tag = b[i]
        i += 1
        if tag == 3:
            return attrs, i
        if tag < 0x10:
            continue
        nl = struct.unpack(">H", b[i:i + 2])[0]
        name = b[i + 2:i + 2 + nl].decode("utf-8", "replace")
        i += 2 + nl
        vl = struct.unpack(">H", b[i:i + 2])[0]
        value = b[i + 2:i + 2 + vl]
        i += 2 + vl
        if tag == 0x34:
            if depth == 0 and name:
                top = name
                attrs.setdefault(top, [])
            depth += 1
        elif tag == 0x37:
            depth -= 1
        elif tag == 0x4A:
            member = value.decode("utf-8", "replace")
        elif depth > 0:
            attrs[top].append("%s=%s" % (member, decode_value(tag, value)))
        else:
            if name:
                top = name
                attrs.setdefault(top, [])
            attrs[top].append(decode_value(tag, value))
    return attrs, None


def raster_info(doc):
    if doc[:8] == b"UNIRAST\0" and len(doc) >= 44:
        width, height, dpi = struct.unpack(">III", doc[24:36])
        return {"magic": "URF", "pages": struct.unpack(">I", doc[8:12])[0], "width": width, "height": height, "dpi": dpi}
    if doc[:4] == b"RaS2" and len(doc) >= 4 + 384:
        width, height = struct.unpack(">II", doc[4 + 372:4 + 380])
        return {"magic": "PWG", "width": width, "height": height, "dpi": struct.unpack(">I", doc[4 + 276:4 + 280])[0]}
    return {"magic": doc[:5].decode("latin-1")}


class Conn(socketserver.BaseRequestHandler):
    def setup(self):
        self.buffer = b""
        self.request.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def fill(self):
        data = self.request.recv(1 << 20)
        if not data:
            raise ConnectionError("peer closed")
        self.buffer += data

    def read_exact(self, n):
        while len(self.buffer) < n:
            self.fill()
        out, self.buffer = self.buffer[:n], self.buffer[n:]
        return out

    def discard(self, n):
        while n > 0:
            if not self.buffer:
                self.fill()
            take = min(n, len(self.buffer))
            self.buffer = self.buffer[take:]
            n -= take

    def read_headers(self):
        while b"\r\n\r\n" not in self.buffer:
            self.fill()
        head, self.buffer = self.buffer.split(b"\r\n\r\n", 1)
        lines = head.decode("latin-1").split("\r\n")
        headers = {}
        for line in lines[1:]:
            key, _, value = line.partition(":")
            headers[key.strip().lower()] = value.strip()
        return lines[0].split(" "), headers

    def handle(self):
        try:
            while self.serve_one():
                pass
        except (ConnectionError, OSError):
            pass

    def reset(self):
        self.request.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        self.request.close()

    def serve_one(self):
        request_line, headers = self.read_headers()
        path = request_line[1]
        scenario = path.strip("/").split("/")[0]
        if path.startswith("/__log/"):
            body = json.dumps(scenario_state(path.split("/")[2])["log"]).encode()
            self.send_http(200, "application/json", body, close=True)
            return False

        length = int(headers.get("content-length", "-1"))
        state = scenario_state(scenario)
        if length < 0:
            prefix = self.read_chunked()
            rest = 0
            length_seen = None
        else:
            prefix = self.read_exact(min(length, 8))
            rest = length - len(prefix)
            length_seen = length
        op = OPS.get(struct.unpack(">H", prefix[2:4])[0], "op-%d" % struct.unpack(">H", prefix[2:4])[0])
        with LOCK:
            n = state["counts"][op] = state["counts"].get(op, 0) + 1
        entry = {"op": op, "n": n, "version": "%d.%d" % (prefix[0], prefix[1]),
                 "requestId": struct.unpack(">I", prefix[4:8])[0], "contentType": headers.get("content-type"),
                 "contentLength": length_seen, "bodyLength": 0, "format": None, "attrs": {}, "raster": None}
        state["log"].append(entry)
        hook = HOOKS.get(scenario, {}).get(op)
        if hook and hook(n, {"format": None}) == ("rst_mid",):
            self.read_exact(min(rest, 200))
            entry["bodyLength"] = 208
            self.reset()
            return False

        head = prefix + self.read_exact(min(rest, 65536 - len(prefix)))
        rest -= len(head) - len(prefix)
        self.discard(rest)
        attrs, end = parse_ipp(head)
        entry["bodyLength"] = length if length >= 0 else len(prefix)
        entry["attrs"] = attrs
        entry["format"] = (attrs.get("document-format") or [None])[0]
        if op == "Print-Job" and end is not None:
            entry["raster"] = raster_info(head[end:])
            entry["attributeBytes"] = end

        action = hook(n, {"format": entry["format"], "attrs": attrs}) if hook else None
        if scenario in OLD_VERSION and prefix[0] >= 2:
            action = ipp(BAD_VERSION)
        return self.respond(scenario, state, op, n, attrs, action, prefix)

    def read_chunked(self):
        out = b""
        while True:
            while b"\r\n" not in self.buffer:
                self.fill()
            size_line, self.buffer = self.buffer.split(b"\r\n", 1)
            size = int(size_line.split(b";")[0], 16)
            if size == 0:
                self.read_exact(2)
                return out
            out += self.read_exact(size)
            self.read_exact(2)

    def respond(self, scenario, state, op, n, attrs, action, prefix):
        rid = prefix[4:8]
        version = b"\x01\x01" if scenario in OLD_VERSION else b"\x02\x00"

        def message(status, groups=b""):
            head = b"\x01" + attr(CHARSET, "attributes-charset", "utf-8") + attr(LANG, "attributes-natural-language", "en")
            return version + struct.pack(">H", status) + rid + head + groups + b"\x03"

        if action is not None:
            kind = action[0]
            if kind == "ipp":
                return self.send_ipp(scenario, message(action[1], action[2]))
            if kind == "http":
                return self.send_http(action[1], action[2], action[3])
            if kind == "close":
                self.request.close()
                return False
            if kind == "stall":
                time.sleep(action[1])
                self.request.close()
                return False
            if kind == "truncated":
                body = message(OK, b"\x04" + attr(NAME, "printer-name", "x"))[:-6]
                return self.send_ipp(scenario, body)

        if op == "Get-Printer-Attributes":
            trailing = b"\xde\xad\xbe\xef" if scenario == "trailing-bytes" else b""
            groups = b"\x04" + b"".join(printer_for(scenario, n).values())
            return self.send_ipp(scenario, message(OK, groups) + trailing)
        if op == "Validate-Job":
            return self.send_ipp(scenario, message(OK))
        if op == "Print-Job":
            job_id = state["next_job"]
            state["next_job"] += 1
            job = attr(INT, "job-id", job_id) + attr(URI, "job-uri", "ipp://localhost/ipp/print/%d" % job_id)
            if scenario not in NO_STATE:
                job += attr(ENUM, "job-state", 9 if scenario in INSTANT else 3)
                job += attr(KEYWORD, "job-state-reasons", "none")
            status = OK
            extra = b""
            if action is not None and action[0] == "job":
                status, extra = action[1], action[2]
            return self.send_ipp(scenario, message(status, extra + b"\x02" + job))
        if op == "Cancel-Job":
            state["cancelled"] = True
            return self.send_ipp(scenario, message(OK))
        if op == "Get-Job-Attributes":
            if state["cancelled"]:
                poll = (7, "job-canceled-by-user")
            else:
                script = POLLS.get(scenario, [5, 5, 9])
                index = state.setdefault("polls", {}).get(attrs.get("job-id", ["0"])[0], 0)
                state["polls"][attrs.get("job-id", ["0"])[0]] = index + 1
                poll = script[min(index, len(script) - 1)]
            if poll == ("gone",):
                return self.send_ipp(scenario, message(NOT_FOUND))
            job_state, reason = poll if isinstance(poll, tuple) else (poll, "none")
            job = attr(INT, "job-id", int(attrs.get("job-id", ["0"])[0]))
            job += attr(ENUM, "job-state", job_state) + attr(KEYWORD, "job-state-reasons", reason)
            return self.send_ipp(scenario, message(OK, b"\x02" + job))
        return self.send_ipp(scenario, message(0x0501))

    def send_ipp(self, scenario, body):
        if scenario in CONTINUE:
            self.request.sendall(b"HTTP/1.1 100 Continue\r\n\r\n")
        if scenario in CHUNKED:
            head = b"HTTP/1.1 200 OK\r\nContent-Type: application/ipp\r\nTransfer-Encoding: chunked\r\n\r\n"
            half = len(body) // 2
            out = b""
            for part in (body[:half], body[half:]):
                out += b"%x\r\n" % len(part) + part + b"\r\n"
            self.request.sendall(head + out + b"0\r\n\r\n")
            return True
        return self.send_http(200, "application/ipp", body, close=scenario in CONN_CLOSE)

    def send_http(self, code, content_type, body, close=False):
        reason = {200: "OK", 401: "Unauthorized", 426: "Upgrade Required"}.get(code, "Status")
        head = "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n" % (code, reason, content_type, len(body))
        if code == 401:
            head += 'WWW-Authenticate: Basic realm="printer"\r\n'
        if close:
            head += "Connection: close\r\n"
        self.request.sendall(head.encode() + b"\r\n" + body)
        return not close


class Server(socketserver.ThreadingTCPServer):
    address_family = socket.AF_INET6
    allow_reuse_address = True
    daemon_threads = True
    request_queue_size = 64

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


if __name__ == "__main__":
    Server(("::", int(sys.argv[1])), Conn).serve_forever()
