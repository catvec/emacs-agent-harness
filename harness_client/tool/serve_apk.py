#!/usr/bin/env python3
"""Serve the Harness APK on the local network and show its URL as a QR code.

`tool/qr_install.sh --serve' runs this for phones that cannot use adb wireless
debugging: scan the code with the phone's camera, open the download and install
the app.  The server binds every interface and serves that one APK, nothing
else.  Stop it with Ctrl-C.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import socket
import sys
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qr_terminal  # noqa: E402


def lan_address() -> str:
    """Return this machine's address on the local network, best effort."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        try:
            # A UDP connect sends nothing; it only asks the kernel which
            # source address it would use.
            sock.connect(("8.8.8.8", 80))
            address = sock.getsockname()[0]
            if address and not address.startswith("127."):
                return address
        except OSError:
            pass
    try:
        address = socket.gethostbyname(socket.gethostname())
        if address and not address.startswith("127."):
            return address
    except OSError:
        pass
    return "127.0.0.1"


class ApkHandler(BaseHTTPRequestHandler):
    apk = ""
    download_name = "Harness.apk"
    server_version = "HarnessQR/1.0"

    def do_GET(self) -> None:  # noqa: N802 (http.server's naming)
        self._respond(send_body=True)

    def do_HEAD(self) -> None:  # noqa: N802
        self._respond(send_body=False)

    def _respond(self, send_body: bool) -> None:
        path = urlsplit(self.path).path
        if path == "/":
            page = (
                "<!doctype html><meta charset=utf-8>"
                "<meta name=viewport content='width=device-width,initial-scale=1'>"
                "<title>Harness</title>"
                "<style>body{font:17px system-ui,sans-serif;max-width:30rem;margin:3rem auto;"
                "padding:0 1.5rem;color:#29241f;background:#f8f6f2}"
                "a{display:block;margin:2rem 0;padding:1rem;border-radius:.75rem;"
                "background:#d65a36;color:#fff;text-align:center;text-decoration:none}"
                "small{color:#6b625a}</style>"
                "<h1>Harness</h1>"
                f"<a href='/{self.download_name}'>Download the Android app</a>"
                "<p>After the download, open it and allow this browser to install "
                "unknown apps if Android asks.</p>"
                "<small>The file is served from this computer on your local network.</small>"
            ).encode()
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(page)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if send_body:
                self.wfile.write(page)
            return
        if path not in ("/" + self.download_name, "/harness.apk", "/app.apk"):
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        try:
            size = os.path.getsize(self.apk)
        except OSError:
            self.send_error(HTTPStatus.NOT_FOUND, "the APK is gone")
            return
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/vnd.android.package-archive")
        self.send_header("Content-Disposition", f'attachment; filename="{self.download_name}"')
        self.send_header("Content-Length", str(size))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if not send_body:
            return
        try:
            with open(self.apk, "rb") as source:
                shutil.copyfileobj(source, self.wfile, length=64 * 1024)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, format: str, *args) -> None:  # noqa: A002
        # One short line per request; the QR and instructions are the output
        # that matters.
        sys.stderr.write("serve_apk: " + (format % args) + "\n")


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Serve an APK on the local network and show its URL as a QR code.")
    parser.add_argument("apk", help="APK file to serve")
    parser.add_argument("--port", type=int, default=0,
                        help="port to listen on (default: pick a free one)")
    parser.add_argument("--address", default=None,
                        help="address to put in the URL and QR code (default: detect)")
    parser.add_argument("--download-name", default="Harness.apk",
                        help="file name the phone saves (default Harness.apk)")
    parser.add_argument("--no-image", action="store_true",
                        help="do not open the QR code in an image viewer")
    args = parser.parse_args(argv)

    apk = os.path.abspath(args.apk)
    if not os.path.isfile(apk):
        print(f"serve_apk: no such file: {apk}", file=sys.stderr)
        return 1
    download_name = re.sub(r"[^A-Za-z0-9._-]", "_", os.path.basename(args.download_name))
    if download_name in ("", ".", ".."):
        download_name = "Harness.apk"

    address = args.address or lan_address()
    handler = type("Handler", (ApkHandler,), {
        "apk": apk,
        "download_name": download_name,
    })
    try:
        server = Server(("", args.port), handler)
    except OSError as exc:
        print(f"serve_apk: cannot listen: {exc}", file=sys.stderr)
        return 1
    port = server.server_address[1]
    url = f"http://{address}:{port}/{download_name}"
    qr = qr_terminal.encode(url, "M")

    # A fresh screen keeps an older code from a previous run out of the
    # camera's view.  A pipe or an Emacs comint buffer (TERM=dumb) gets the
    # text without control characters.
    tty = (sys.stdout.isatty() and os.environ.get("TERM", "")
           not in ("", "dumb"))
    if tty:
        print("\033[2J\033[H", end="")
    print(f"Serving {os.path.basename(apk)} "
          f"({os.path.getsize(apk) / 1024 / 1024:.1f} MB) at")
    print(f"  {url}")
    print()
    print("Scan this code with the phone's camera to download the app.")
    print("The phone and this computer must be on the same network.")
    print()
    sys.stdout.write(qr_terminal.render(qr))
    print()
    if (not args.no_image and tty
            and (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))):
        path = qr_terminal.show_image(qr)
        if path:
            print(f"Large QR image: {path}")
    print("Press Ctrl-C to stop serving.")
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print()
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
