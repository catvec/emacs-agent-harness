#!/usr/bin/env python3
"""Tests for the QR terminal tool and the phone installers beside it.

Run from harness_client:

    python3 tool/test_qr_tools.py

The QR encoder is checked against `qrencode' when it is installed (it builds
the same symbols independently); the installer is driven with a fake adb so
the pairing, connecting, installing and launching steps are all exercised
without a phone.
"""

from __future__ import annotations

import http.client
import io
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOL_DIR)

import qr_terminal  # noqa: E402
import serve_apk  # noqa: E402


def matrix(qr: dict) -> list[list[int]]:
    return [[1 if module else 0 for module in row] for row in qr["modules"]]


def qrencode(text: str, level: str) -> list[list[int]] | None:
    """Return qrencode's module matrix for TEXT, in 8-bit mode and no margin."""
    if not shutil.which("qrencode"):
        return None
    result = subprocess.run(
        ["qrencode", "-t", "ASCII", "-m", "0", "-l", level, "-8", "--", text],
        capture_output=True, text=True)
    if result.returncode != 0:
        return None
    lines = result.stdout.splitlines()
    return [[1 if lines[y][2 * x:2 * x + 2] == "##" else 0
             for x in range(len(lines[y]) // 2)]
            for y in range(len(lines))]


class QrEncodeTest(unittest.TestCase):
    TEXTS = [
        "",
        "a",
        "hello world",
        "0123456789",
        "WIFI:T:ADB;S:ADB_WIFI_abcdefghijklmn-abcdef;P:abcdefghijklmnopqrstu;;",
        "https://example.com/a/b?c=d&e=f",
        "héllo 🌍",
        "x" * 50,
        "Harness " * 20,
        "0123456789" * 30,
        "abcdefghijklmnopqrstuvwxyz" * 40,
        "0123456789abcdef" * 160,
    ]

    @unittest.skipUnless(shutil.which("qrencode"), "qrencode is not installed")
    def test_symbols_match_qrencode(self):
        for text in self.TEXTS:
            for level in "LMQH":
                if level == "H" and len(text.encode()) > 1200:
                    continue
                reference = qrencode(text, level)
                if reference is None:
                    # qrencode rejects the empty input; every other text must
                    # match.
                    continue
                candidates = [matrix(qr_terminal.encode(text, level, mask=mask))
                              for mask in range(8)]
                self.assertIn(reference, candidates,
                              f"no mask of {text[:20]!r} at {level} matches qrencode")

    @unittest.skipUnless(shutil.which("qrencode"), "qrencode is not installed")
    def test_largest_version(self):
        text = "x" * 2900
        qr = qr_terminal.encode(text, "L")
        self.assertEqual(qr["version"], 40)
        reference = qrencode(text, "L")
        self.assertIsNotNone(reference)
        candidates = [matrix(qr_terminal.encode(text, "L", mask=mask))
                      for mask in range(8)]
        self.assertIn(reference, candidates)

    def test_version_grows_with_the_text(self):
        last = 0
        for length in (1, 10, 30, 80, 150, 300, 600, 1000):
            version = qr_terminal.encode("x" * length, "M")["version"]
            self.assertGreaterEqual(version, last)
            last = version

    def test_too_much_text(self):
        with self.assertRaises(ValueError):
            qr_terminal.encode("x" * 3000, "H")

    def test_size_and_quiet_zone(self):
        qr = qr_terminal.encode("hello", "M")
        self.assertEqual(qr["size"], qr["version"] * 4 + 17)
        rendered = qr_terminal.render(qr, margin=4, ascii=True).splitlines()
        self.assertEqual(len(rendered), qr["size"] + 8)
        self.assertTrue(all(len(line) == 2 * (qr["size"] + 8) for line in rendered))
        # The quiet zone is light: spaces in ASCII output.
        self.assertTrue(rendered[0].strip() == "")
        self.assertTrue(rendered[-1].strip() == "")

    def test_ansi_render(self):
        qr = qr_terminal.encode("hello", "M")
        margin = 4
        lines = qr_terminal.render(qr, margin=margin).splitlines()
        width = qr["size"] + 2 * margin
        self.assertEqual(len(lines), (width + 1) // 2)
        plain = []
        for line in lines:
            self.assertTrue(line.startswith("\033[47;30m"))
            self.assertTrue(line.endswith("\033[0m"))
            text = re.sub(r"\033\[[0-9;]*m", "", line)
            self.assertEqual(len(text), width)
            plain.append(text)
        # The quiet zone is light, at the top and at the bottom.
        self.assertEqual(plain[0].strip(), "")
        self.assertEqual(plain[1].strip(), "")
        self.assertEqual(plain[-1].strip(), "")
        self.assertEqual(plain[-2].strip(), "")
        # Decode the half blocks back into modules: they must be exactly the
        # matrix, with the quiet zone around it (no rows shifted or reused).
        decoded = []
        for text in plain:
            top_row, bottom_row = [], []
            for char in text:
                if char == "\u2588":
                    top_row.append(True)
                    bottom_row.append(True)
                elif char == "\u2580":
                    top_row.append(True)
                    bottom_row.append(False)
                elif char == "\u2584":
                    top_row.append(False)
                    bottom_row.append(True)
                else:
                    self.assertEqual(char, " ")
                    top_row.append(False)
                    bottom_row.append(False)
            decoded.extend([top_row, bottom_row])
        # The last line's lower half is outside an odd-height symbol.
        decoded = decoded[:width]
        expected = [[False] * width for _ in range(width)]
        for y in range(qr["size"]):
            for x in range(qr["size"]):
                expected[y + margin][x + margin] = qr["modules"][y][x]
        self.assertEqual(decoded, expected)

    def test_pairing_code_is_compact_at_level_l(self):
        text = ("WIFI:T:ADB;S:ADB_WIFI_abcdefghijklmn-abcdef;"
                "P:abcdefghijklmnopqrstu;;")
        self.assertEqual(qr_terminal.encode(text, "L")["version"], 4)
        self.assertEqual(len(qr_terminal.render(
            qr_terminal.encode(text, "L")).splitlines()), 21)

    def test_png_dimensions_and_pixels(self):
        qr = qr_terminal.encode("hello", "M")
        data = qr_terminal.png_bytes(qr, scale=4, margin=3)
        self.assertTrue(data.startswith(b"\x89PNG\r\n\x1a\n"))
        width, height = struct.unpack(">II", data[16:24])
        pixels = (qr["size"] + 6) * 4
        self.assertEqual((width, height), (pixels, pixels))
        # The top-left corner is quiet zone (white); the finder starts dark.
        try:
            from PIL import Image
        except ImportError:
            self.skipTest("Pillow is not installed")
        image = Image.open(io.BytesIO(data)).convert("L")
        self.assertEqual(image.getpixel((0, 0)), 255)
        self.assertEqual(image.getpixel((12, 12)), 0)

    def test_png_cli(self):
        path = os.path.join(tempfile.mkdtemp(prefix="harness-qr-png-"), "qr.png")
        result = subprocess.run(
            [sys.executable, os.path.join(TOOL_DIR, "qr_terminal.py"),
             "--level", "L", "--scale", "5", "--margin", "2", "--png", path,
             "hello"],
            capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(os.path.isfile(path))
        with open(path, "rb") as f:
            self.assertEqual(f.read(8), b"\x89PNG\r\n\x1a\n")
        os.unlink(path)
        os.rmdir(os.path.dirname(path))

    def test_large_image_uses_a_viewer(self):
        tmp = tempfile.mkdtemp(prefix="harness-qr-viewer-")
        log = os.path.join(tmp, "calls")
        fake = os.path.join(tmp, "feh")
        with open(fake, "w") as f:
            f.write('#!/bin/sh\nprintf "%s\\n" "$*" > ' + log + "\n")
        os.chmod(fake, 0o755)
        path = None
        try:
            with mock.patch.dict(os.environ, {
                    "PATH": tmp + os.pathsep + os.environ.get("PATH", ""),
                    "DISPLAY": ":1", "WAYLAND_DISPLAY": ""}):
                path = qr_terminal.show_image(qr_terminal.encode("hello", "M"),
                                              scale=2)
                self.assertIsNotNone(path)
                self.assertTrue(os.path.isfile(path))
                deadline = time.time() + 2
                while not os.path.exists(log) and time.time() < deadline:
                    time.sleep(0.02)
                with open(log) as f:
                    self.assertIn(path, f.read())
        finally:
            if path and os.path.exists(path):
                os.unlink(path)
            shutil.rmtree(tmp, ignore_errors=True)

    def test_masks_differ(self):
        qr = qr_terminal.encode("mask test", "M")
        self.assertIn(qr["mask"], range(8))
        matrices = {tuple(map(tuple, matrix(qr_terminal.encode("mask test", "M", mask=mask))))
                    for mask in range(8)}
        self.assertGreater(len(matrices), 1)

    def test_multibyte_text_is_utf8(self):
        qr = qr_terminal.encode("é", "L")
        # One UTF-8 byte plus mode and count bits fits version 1.
        self.assertEqual(qr["version"], 1)


class ServeApkTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="harness-serve-test-")
        self.apk = os.path.join(self.tmp, "app-release.apk")
        with open(self.apk, "wb") as f:
            f.write(b"fake apk contents")
        handler = type("Handler", (serve_apk.ApkHandler,), {"apk": self.apk})
        self.server = serve_apk.Server(("127.0.0.1", 0), handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def get(self, path: str) -> tuple[int, dict, bytes]:
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        connection.request("GET", path)
        response = connection.getresponse()
        body = response.read()
        headers = dict(response.getheaders())
        connection.close()
        return response.status, headers, body

    def test_apk_download(self):
        status, headers, body = self.get("/harness.apk")
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"], "application/vnd.android.package-archive")
        self.assertEqual(headers["Content-Disposition"], 'attachment; filename="Harness.apk"')
        self.assertEqual(body, b"fake apk contents")

    def test_landing_page(self):
        status, headers, body = self.get("/")
        self.assertEqual(status, 200)
        self.assertIn("text/html", headers["Content-Type"])
        self.assertIn(b"Download the Android app", body)

    def test_unknown_path(self):
        status, _, _ = self.get("/etc/passwd")
        self.assertEqual(status, 404)


FAKE_ADB = r'''#!/usr/bin/env python3
import os
import sys

args = sys.argv[1:]
state = os.environ["FAKE_ADB_STATE"]
with open(os.path.join(state, "log"), "a") as log:
    log.write(" ".join(args) + "\n")

def flag(name):
    return os.path.exists(os.path.join(state, name))

def touch(name):
    open(os.path.join(state, name), "w").close()

def number(name, default=0):
    try:
        with open(os.path.join(state, name)) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return default

ip = os.environ.get("FAKE_PHONE_IP", "192.168.7.42")
other = os.environ.get("FAKE_OTHER_IP", "192.168.1.117")
pair_port = "37111"
connect_port = "42345"
pairing_name = os.environ.get("QR_INSTALL_PAIR_NAME", "ADB_WIFI_testpair-abcdef")
guid = "adb-phone-abc"
serial = ip + ":" + connect_port

if args == ["devices"]:
    print("List of devices attached")
    if flag("preconnected") or flag("connected"):
        print(serial + "\tdevice")
elif args[:2] == ["mdns", "services"]:
    count = number("mdns_count") + 1
    with open(os.path.join(state, "mdns_count"), "w") as f:
        f.write(str(count))
    print("List of discovered mdns services")
    if flag("stale_pairing"):
        print("adb-other\t_adb-tls-pairing._tcp\t" + other + ":38291")
    if not flag("no_pairing") and count > number("pairing_after", 0):
        print(pairing_name + "\t_adb-tls-pairing._tcp\t" + ip + ":" + pair_port)
    if flag("paired"):
        if flag("stale_connect"):
            print("adb-other\t_adb-tls-connect._tcp\t" + other + ":46037")
        if flag("stale_same_host"):
            print("adb-stale\t_adb-tls-connect._tcp\t" + ip + ":46037")
        if not flag("no_phone_connect"):
            since = count - number("paired_mdns_count")
            if since > number("connect_after", 0):
                print(guid + "\t_adb-tls-connect._tcp\t" + ip + ":" + connect_port)
elif args[0] == "pair":
    if args[1] != ip + ":" + pair_port:
        print("Failed: Wrong password or connection was dropped.")
        sys.exit(1)
    assert args[2], "no pairing code"
    with open(os.path.join(state, "paired_mdns_count"), "w") as f:
        f.write(str(number("mdns_count")))
    touch("paired")
    print("Successfully paired to " + args[1] + " [guid=" + guid + "]")
elif args[0] == "connect":
    addr = args[1]
    if addr == ip + ":" + connect_port:
        touch("connected")
        print("connected to " + addr)
    else:
        print("failed to connect to '" + addr + "': Connection refused")
elif args[0] == "disconnect":
    print("disconnected " + args[1])
elif args[0] == "-s" and len(args) >= 3 and args[2] == "get-state":
    if flag("preconnected") or flag("connected"):
        print("device")
    else:
        sys.exit(1)
elif args[0] == "-s" and len(args) >= 4 and args[2] == "install":
    assert os.path.isfile(args[4]), args
    if flag("install_fail"):
        print("Performing Streamed Install")
        print("Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: signatures do not match]")
        sys.exit(1)
    touch("installed")
    print("Performing Streamed Install")
    print("Success")
elif args[0] == "-s" and len(args) >= 5 and args[2] == "shell":
    touch("launched")
    print("Starting: Intent")
else:
    print("fake adb: unhandled " + " ".join(args), file=sys.stderr)
    sys.exit(2)
'''


class InstallScriptTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="harness-qr-install-test-")
        self.state = os.path.join(self.tmp, "state")
        os.makedirs(self.state)
        self.adb = os.path.join(self.tmp, "adb")
        with open(self.adb, "w") as f:
            f.write(FAKE_ADB)
        os.chmod(self.adb, 0o755)
        self.apk = os.path.join(self.tmp, "app.apk")
        with open(self.apk, "w") as f:
            f.write("fake apk")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def flag(self, name):
        open(os.path.join(self.state, name), "w").close()

    def set_number(self, name, value):
        with open(os.path.join(self.state, name), "w") as f:
            f.write(str(value))

    def calls(self):
        with open(os.path.join(self.state, "log")) as f:
            return f.read().splitlines()

    def has_flag(self, name):
        return os.path.exists(os.path.join(self.state, name))

    def run_install(self, *args, timeout=30, **env_extra):
        env = dict(os.environ)
        env.update(ADB=self.adb, FAKE_ADB_STATE=self.state,
                   QR_INSTALL_PAIR_NAME="ADB_WIFI_testpair-abcdef",
                   FAKE_PHONE_IP="192.168.7.42")
        env.update(env_extra)
        return subprocess.run(
            [os.path.join(TOOL_DIR, "qr_install.sh"), "--no-build",
             "--apk", self.apk, *args],
            capture_output=True, text=True, timeout=timeout, env=env)

    def test_pairs_and_installs(self):
        result = self.run_install("--timeout", "10")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Paired with 192.168.7.42", result.stdout)
        self.assertIn("Installed.", result.stdout)
        self.assertIn("Opened Harness", result.stdout)
        calls = self.calls()
        self.assertTrue(any(call.startswith("pair 192.168.7.42:37111 ") for call in calls))
        self.assertIn("connect 192.168.7.42:42345", calls)
        self.assertTrue(any(" install -r " + self.apk in call for call in calls))
        self.assertTrue(any("shell am start" in call for call in calls))
        self.assertTrue(self.has_flag("installed"))
        self.assertTrue(self.has_flag("launched"))

    def test_uses_an_already_connected_device(self):
        self.flag("preconnected")
        result = self.run_install("--timeout", "10")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Using the connected device", result.stdout)
        calls = self.calls()
        self.assertEqual(calls[0], "devices")
        self.assertFalse(any(call.startswith("pair ") for call in calls))
        self.assertTrue(any(" install -r " + self.apk in call for call in calls))

    def test_no_launch(self):
        self.flag("preconnected")
        result = self.run_install("--no-launch", "--timeout", "10")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(any("shell am start" in call for call in self.calls()))

    def test_install_failure_is_explained(self):
        self.flag("preconnected")
        self.flag("install_fail")
        result = self.run_install("--timeout", "10")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("signed with another key", result.stdout)
        self.assertIn("uninstall app.harness.client", result.stdout)

    def test_pairing_skips_another_pairing_server(self):
        # A pairing-code dialog (or a previous run) can leave its own pairing
        # service advertised.  The QR asks the phone for this service name, so
        # only that one may be paired.
        self.flag("stale_pairing")
        result = self.run_install("--timeout", "10")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()
        self.assertFalse(any(call.startswith("pair 192.168.1.117:")
                             for call in calls), calls)
        self.assertTrue(any(call.startswith("pair 192.168.7.42:37111 ")
                            for call in calls), calls)

    def test_ignores_connect_service_of_another_host(self):
        # The regression: the phone paired at .119, but .117 still advertised
        # an old _adb-tls-connect service.  The old code connected to .117.
        self.flag("stale_connect")
        self.set_number("connect_after", 3)
        result = self.run_install("--timeout", "15", FAKE_PHONE_IP="192.168.1.119")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()
        self.assertFalse(any(call.startswith("connect 192.168.1.117:")
                             for call in calls), calls)
        self.assertIn("connect 192.168.1.119:42345", calls)
        self.assertIn("Installed.", result.stdout)

    def test_retries_a_stale_port_on_the_same_host(self):
        # The first published port for the phone can be a stale one; a refused
        # connect must not end the run.
        self.flag("stale_same_host")
        self.set_number("connect_after", 4)
        result = self.run_install("--timeout", "15", FAKE_PHONE_IP="192.168.1.119")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()
        self.assertIn("connect 192.168.1.119:46037", calls)
        self.assertIn("connect 192.168.1.119:42345", calls)
        self.assertIn("Installed.", result.stdout)

    def test_explains_when_the_debugging_port_does_not_open(self):
        self.flag("stale_connect")
        self.flag("no_phone_connect")
        result = self.run_install("--timeout", "3", FAKE_PHONE_IP="192.168.1.119")
        self.assertNotEqual(result.returncode, 0)
        calls = self.calls()
        self.assertFalse(any(call.startswith("connect 192.168.1.117:")
                             for call in calls), calls)
        self.assertIn("wireless debugging port did not open", result.stderr)
        self.assertIn("qr_install.sh --connect IP:PORT", result.stderr)

    def test_connect_address_skips_pairing(self):
        result = self.run_install("--connect", "192.168.7.42:42345",
                                  "--timeout", "10")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()
        self.assertFalse(any(call.startswith("pair ") for call in calls), calls)
        self.assertIn("connect 192.168.7.42:42345", calls)
        self.assertIn("Installed.", result.stdout)

    def test_qr_timeout(self):
        self.flag("no_pairing")
        result = self.run_install("--timeout", "2")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("timed out waiting for the phone", result.stderr)

    def test_help(self):
        result = subprocess.run([os.path.join(TOOL_DIR, "qr_install.sh"), "--help"],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertIn("Pair device with QR code", result.stdout)

    def test_bad_timeout(self):
        result = self.run_install("--timeout", "soon")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("positive number of seconds", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
