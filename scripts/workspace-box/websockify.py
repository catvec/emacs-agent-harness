#!/usr/bin/env python3
"""Serve a noVNC page and bridge WebSocket clients to a VNC server.

This is the small, dependency-free end of a workspace computer: x11vnc
speaks RFB on a loopback TCP port, a browser (and the Flutter client)
speaks WebSocket, and this process is the short wire between them.  The
same port serves the noVNC files under ``--web-root``, so the page and
the socket it connects to share an origin.

    websockify.py --listen 127.0.0.1:6080 --target 127.0.0.1:5900 \\
        --token TOKEN --web-root scripts/workspace-box/novnc

Only a client that names the token may open ``/websockify``.  Every
other path is a static file from the web root.  The bind address is the
boundary: the caller passes a loopback address and never a public one.

The bridge is deliberately plain: one thread per connection, no
compression, no extensions.  A WebSocket frame is a length and a mask;
RFB is bytes after that, and the byte stream is all either side sees.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import mimetypes
import os
import socket
import socketserver
import struct
import sys
import threading
import urllib.parse

GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
BUFFER = 65536
MAX_HEADER = 32 * 1024


def log(message: str) -> None:
    print(f"workspace-box: {message}", flush=True)


def parse_hostport(value: str) -> tuple[str, int]:
    host, sep, port = value.rpartition(":")
    if not sep or not host:
        raise argparse.ArgumentTypeError(f"expected HOST:PORT, got {value!r}")
    return host, int(port)


def query_token(path: str) -> str | None:
    query = urllib.parse.urlsplit(path).query
    values = urllib.parse.parse_qs(query, keep_blank_values=True)
    token = values.get("token")
    return token[0] if token else None


def websocket_frame(payload: bytes, opcode: int = 2) -> bytes:
    """Return one unmasked server frame for PAYLOAD."""
    length = len(payload)
    if length < 126:
        header = struct.pack("!BB", 0x80 | opcode, length)
    elif length < (1 << 16):
        header = struct.pack("!BBH", 0x80 | opcode, 126, length)
    else:
        header = struct.pack("!BBQ", 0x80 | opcode, 127, length)
    return header + payload


def read_exact(sock: socket.socket, count: int) -> bytes:
    data = bytearray()
    while len(data) < count:
        piece = sock.recv(count - len(data))
        if not piece:
            raise ConnectionError("closed")
        data.extend(piece)
    return bytes(data)


def read_frame(sock: socket.socket) -> tuple[bool, int, bytes]:
    """Read one client frame; return (fin, opcode, payload)."""
    first, second = read_exact(sock, 2)
    fin = bool(first & 0x80)
    opcode = first & 0x0F
    masked = bool(second & 0x80)
    length = second & 0x7F
    if length == 126:
        (length,) = struct.unpack("!H", read_exact(sock, 2))
    elif length == 127:
        (length,) = struct.unpack("!Q", read_exact(sock, 8))
    if length > (64 * 1024 * 1024):
        raise ConnectionError("frame too large")
    mask = read_exact(sock, 4) if masked else b""
    payload = read_exact(sock, length) if length else b""
    if masked:
        payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    return fin, opcode, payload


class Bridge(threading.Thread):
    """Carry one WebSocket connection to the VNC server and back."""

    def __init__(self, client: socket.socket, target: tuple[str, int]) -> None:
        super().__init__(daemon=True)
        self.client = client
        self.target = target

    def run(self) -> None:
        try:
            vnc = socket.create_connection(self.target, timeout=5)
            vnc.settimeout(None)
            self.client.settimeout(None)
            stop = threading.Event()

            def client_to_vnc() -> None:
                try:
                    while not stop.is_set():
                        fin, opcode, payload = read_frame(self.client)
                        if opcode == 0x8:  # close
                            break
                        if opcode == 0x9:  # ping
                            self._send(websocket_frame(payload, 0xA))
                            continue
                        if opcode == 0xA:
                            continue
                        if not fin:
                            # The noVNC client sends whole RFB messages; a
                            # fragmented frame is assembled so the VNC server
                            # still sees one stream.
                            pieces = [payload]
                            while not fin:
                                fin, continuation, piece = read_frame(self.client)
                                if continuation == 0x8:
                                    pieces = []
                                    break
                                pieces.append(piece)
                            payload = b"".join(pieces)
                        if payload:
                            vnc.sendall(payload)
                except (ConnectionError, OSError):
                    pass
                finally:
                    stop.set()
                    try:
                        vnc.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass

            def vnc_to_client() -> None:
                try:
                    while not stop.is_set():
                        data = vnc.recv(BUFFER)
                        if not data:
                            break
                        self._send(websocket_frame(data, 0x2))
                except (ConnectionError, OSError):
                    pass
                finally:
                    stop.set()
                    self._send(websocket_frame(b"", 0x8))

            reader = threading.Thread(target=client_to_vnc, daemon=True)
            writer = threading.Thread(target=vnc_to_client, daemon=True)
            reader.start()
            writer.start()
            reader.join()
            writer.join(timeout=1)
        except OSError as error:
            log(f"bridge failed: {error}")
        finally:
            try:
                self.client.close()
            except OSError:
                pass

    def _send(self, data: bytes) -> None:
        try:
            self.client.sendall(data)
        except OSError:
            pass


class Handler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        client = self.request
        try:
            header = self._read_header(client)
            if header is None:
                return
            first_line, headers = header
            method, path, _ = first_line.split(" ", 2)
            if method != "GET":
                self._http(client, 405, "text/plain", b"Method not allowed\n")
                return
            if path == "/health":
                self._http(client, 200, "text/plain", b"ok\n")
                return
            if headers.get("upgrade", "").lower() == "websocket":
                if not path.startswith("/websockify"):
                    self._http(client, 404, "text/plain", b"Not found\n")
                    return
                supplied = query_token(path)
                if not hmac.compare_digest(supplied or "", self.server.token):
                    self._http(client, 403, "text/plain", b"Forbidden\n")
                    return
                self._upgrade(client, headers)
                return
            self._static(client, path)
        except (ConnectionError, OSError):
            pass
        except ValueError:
            self._http(client, 400, "text/plain", b"Bad request\n")

    def _read_header(self, client: socket.socket) -> tuple[str, dict[str, str]] | None:
        data = bytearray()
        while b"\r\n\r\n" not in data:
            if len(data) > MAX_HEADER:
                self._http(client, 431, "text/plain", b"Header too large\n")
                return None
            piece = client.recv(4096)
            if not piece:
                return None
            data.extend(piece)
        text = data.split(b"\r\n\r\n", 1)[0].decode("latin-1")
        lines = text.split("\r\n")
        headers = {}
        for line in lines[1:]:
            name, sep, value = line.partition(":")
            if sep:
                headers[name.strip().lower()] = value.strip()
        return lines[0], headers

    def _upgrade(self, client: socket.socket, headers: dict[str, str]) -> None:
        key = headers.get("sec-websocket-key")
        if not key:
            self._http(client, 400, "text/plain", b"Missing key\n")
            return
        accept = base64.b64encode(hashlib.sha1(key.encode() + GUID).digest()).decode()
        response = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n"
            "\r\n"
        )
        client.sendall(response.encode())
        Bridge(client, self.server.target).run()

    def _static(self, client: socket.socket, path: str) -> None:
        path = urllib.parse.urlsplit(path).path
        if path in ("", "/"):
            path = f"/{self.server.page}"
        relative = path.lstrip("/")
        candidate = os.path.realpath(os.path.join(self.server.web_root, relative))
        root = os.path.realpath(self.server.web_root)
        if not candidate.startswith(root + os.sep) and candidate != root:
            self._http(client, 403, "text/plain", b"Forbidden\n")
            return
        if os.path.isdir(candidate):
            candidate = os.path.join(candidate, "index.html")
        if not os.path.isfile(candidate):
            self._http(client, 404, "text/plain", b"Not found\n")
            return
        with open(candidate, "rb") as stream:
            body = stream.read()
        kind = mimetypes.guess_type(candidate)[0] or "application/octet-stream"
        self._http(client, 200, kind, body)

    def _http(self, client: socket.socket, status: int, kind: str, body: bytes) -> None:
        reason = {200: "OK", 400: "Bad Request", 403: "Forbidden",
                  404: "Not Found", 405: "Method Not Allowed",
                  431: "Request Header Fields Too Large"}.get(status, "Error")
        head = (
            f"HTTP/1.1 {status} {reason}\r\n"
            f"Content-Type: {kind}\r\n"
            f"Content-Length: {len(body)}\r\n"
            "Cache-Control: no-store\r\n"
            "Connection: close\r\n"
            "\r\n"
        ).encode()
        client.sendall(head + body)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, address, target, token, web_root, page):
        self.target = target
        self.token = token
        self.web_root = os.path.abspath(web_root)
        self.page = page
        super().__init__(address, Handler)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen", type=parse_hostport, default="127.0.0.1:6080")
    parser.add_argument("--target", type=parse_hostport, required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--web-root", required=True)
    parser.add_argument("--web-page", default="vnc_lite.html")
    args = parser.parse_args(argv)
    server = Server(args.listen, args.target, args.token, args.web_root, args.web_page)
    log(f"listening on {args.listen[0]}:{args.listen[1]} -> "
        f"{args.target[0]}:{args.target[1]}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
