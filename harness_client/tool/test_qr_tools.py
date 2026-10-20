#!/usr/bin/env python3
"""Tests for the QR terminal tool and the phone installers beside it.

Run from harness_client:

    python3 tool/test_qr_tools.py

The QR encoder is checked against `qrencode' when it is installed (it builds
the same symbols independently); the installer is driven with a fake adb so
the pairing, connecting, installing and launching steps are all exercised
without a phone, and with a fake flutter so building, and repairing a pub
cache that lost files, are exercised without the Flutter SDK.
"""

from __future__ import annotations

import http.client
import io
import json
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

import check_pub_cache  # noqa: E402
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
        "WIFI:T:ADB;S:studio-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;P:bbbbbbbbbbbbbbbbbbbbb;;",
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

    def test_pairing_credentials_are_not_a_wifi_ssid(self):
        name, password = qr_terminal.pairing_credentials()
        self.assertTrue(name.startswith("studio-"))
        self.assertGreater(len(name.encode()), 32)  # not a valid Wi-Fi SSID
        self.assertLessEqual(len(name.encode()), 63)  # a valid mDNS name
        self.assertEqual(len(password), 21)
        self.assertTrue(all(c.isalnum() or c == "-" for c in name + password))

    def test_pairing_credentials_take_an_override(self):
        name, password = qr_terminal.pairing_credentials("ADB_WIFI_testpair")
        self.assertEqual(name, "ADB_WIFI_testpair")
        self.assertEqual(len(password), 21)

    def test_pairing_cli(self):
        result = subprocess.run(
            [sys.executable, os.path.join(TOOL_DIR, "qr_terminal.py"),
             "--pairing", "studio-test"],
            capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        name, password = result.stdout.split()
        self.assertEqual(name, "studio-test")
        self.assertEqual(len(password), 21)

    def test_pairing_code_is_compact_at_level_l(self):
        # The QR service name is deliberately longer than a Wi-Fi SSID (32
        # bytes), so a camera that reads the code as a Wi-Fi network cannot
        # join it.  It is still short enough for an mDNS instance name (63
        # bytes) and keeps the symbol at version 4.
        name = "studio-" + "a" * 32
        self.assertEqual(len(name), 39)
        text = "WIFI:T:ADB;S:" + name + ";P:" + "b" * 21 + ";;"
        self.assertEqual(len(text), 78)
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
    expected = os.environ.get("FAKE_PAIR_CODE")
    if expected and args[2] != expected:
        print("Failed: Wrong password or connection was dropped.")
        sys.exit(1)
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

    def run_install(self, *args, timeout=30, stdin=None, input=None, **env_extra):
        env = dict(os.environ)
        env.update(ADB=self.adb, FAKE_ADB_STATE=self.state,
                   QR_INSTALL_PAIR_NAME="ADB_WIFI_testpair-abcdef",
                   FAKE_PHONE_IP="192.168.7.42")
        env.update(env_extra)
        return subprocess.run(
            [os.path.join(TOOL_DIR, "qr_install.sh"), "--no-build",
             "--apk", self.apk, *args],
            capture_output=True, text=True, timeout=timeout, env=env,
            stdin=stdin, input=input)

    def pairing_password(self):
        """The password the script gave `adb pair`, from the fake adb's log."""
        for call in self.calls():
            if call.startswith("pair "):
                return call.split()[2]
        self.fail("adb pair was never called: " + repr(self.calls()))

    def test_a_plain_run_shows_a_qr_code_to_scan(self):
        # The report: "why doesn't qr install show a qr code anymore?"  A plain
        # run had been changed to ask for the six-digit code, so it drew no QR
        # code, although Wireless debugging has a "Pair device with QR code"
        # option for exactly this.  A plain run shows the code again.
        result = self.run_install("--timeout", "10", stdin=subprocess.DEVNULL)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Pair device with QR code", result.stdout)
        self.assertIn("\033[47;30m", result.stdout)
        self.assertNotIn("Six-digit pairing code", result.stdout)
        # It keeps warning not to scan the code with the camera app.
        self.assertIn("not with the camera app", result.stdout)
        # What is drawn is the code the phone scans: the password in it is the
        # one adb then pairs with, under the service name the phone advertises.
        payload = ("WIFI:T:ADB;S:ADB_WIFI_testpair-abcdef;P:"
                   + self.pairing_password() + ";;")
        self.assertIn(qr_terminal.render(qr_terminal.encode(payload, "L")),
                      result.stdout)
        self.assertIn("Paired with 192.168.7.42", result.stdout)
        self.assertIn("Installed.", result.stdout)
        self.assertTrue(self.has_flag("installed"))

    def test_the_qr_code_can_be_left_to_the_six_digit_code(self):
        # --code is how to pair with the code of "Pair device with pairing
        # code" instead: it is asked for, and no QR code is drawn.
        result = self.run_install("--code", "--timeout", "10",
                                  input="123456\n", FAKE_PAIR_CODE="123456")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Pair device with pairing code", result.stdout)
        self.assertIn("Six-digit pairing code shown on the phone:", result.stdout)
        self.assertNotIn("\033[47;30m", result.stdout)
        self.assertNotIn("Pair device with QR code", result.stdout)
        self.assertIn("pair 192.168.7.42:37111 123456", self.calls())
        self.assertIn("Installed.", result.stdout)

    def test_qr_and_code_are_not_asked_for_together(self):
        for args in (["--qr", "--code"],
                     ["--qr", "--pair-code", "123456"],
                     ["--qr", "--pair-address", "192.168.7.42:37111"],
                     ["--code", "--qr"]):
            result = self.run_install(*args, "--timeout", "10",
                                      stdin=subprocess.DEVNULL)
            self.assertNotEqual(result.returncode, 0, args)
            self.assertRegex(result.stderr, r"--qr (and --code|pairs by scanning)",
                             args)
            self.assertNotIn("\033[47;30m", result.stdout, args)
        # It is refused before adb is run at all.
        self.assertFalse(os.path.exists(os.path.join(self.state, "log")))

    def test_pairs_and_installs(self):
        # The six-digit flow (--pair-code asks for it) never prints a Wi-Fi QR
        # code, so it cannot take the phone off its network.
        result = self.run_install("--pair-code", "123456", "--timeout", "10",
                                  FAKE_PAIR_CODE="123456")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Pair device with pairing code", result.stdout)
        self.assertIn("Pairing address: 192.168.7.42:37111", result.stdout)
        self.assertIn("Paired with 192.168.7.42", result.stdout)
        self.assertIn("Installed.", result.stdout)
        self.assertIn("Opened Harness", result.stdout)
        self.assertNotIn("WIFI:T:ADB", result.stdout)
        self.assertNotIn("\033[47;30m", result.stdout)
        calls = self.calls()
        self.assertTrue(any(call == "pair 192.168.7.42:37111 123456"
                            for call in calls), calls)
        self.assertIn("connect 192.168.7.42:42345", calls)
        self.assertTrue(any(" install -r " + self.apk in call for call in calls))
        self.assertTrue(any("shell am start" in call for call in calls))
        self.assertTrue(self.has_flag("installed"))
        self.assertTrue(self.has_flag("launched"))

    def test_qr_mode_still_pairs(self):
        # --qr is what a plain run does; it stays accepted for whoever gives it.
        result = self.run_install("--qr", "--timeout", "10")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Pair device with QR code", result.stdout)
        self.assertIn("\033[47;30m", result.stdout)
        self.assertIn("Paired with 192.168.7.42", result.stdout)
        self.assertIn("Installed.", result.stdout)
        self.assertTrue(any(call.startswith("pair 192.168.7.42:37111 ")
                            for call in self.calls()))

    def test_a_wrong_pairing_code_is_explained(self):
        result = self.run_install("--pair-code", "123456", "--timeout", "10",
                                  FAKE_PAIR_CODE="654321")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not pair with 192.168.7.42:37111", result.stderr)
        self.assertIn("Wrong password", result.stderr)

    def test_pair_address_skips_mdns_discovery(self):
        self.flag("no_pairing")
        result = self.run_install("--pair-address", "192.168.7.42:37111",
                                  "--pair-code", "123456", "--timeout", "10",
                                  FAKE_PAIR_CODE="123456")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Pairing address: 192.168.7.42:37111", result.stdout)
        self.assertIn("Installed.", result.stdout)

    def test_explains_when_no_pairing_service_is_found(self):
        self.flag("no_pairing")
        result = self.run_install("--code", "--timeout", "2",
                                  stdin=subprocess.DEVNULL)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not find the phone's pairing service", result.stderr)
        self.assertIn("--pair-address", result.stderr)
        self.assertNotIn("\033[47;30m", result.stdout)

    def test_uses_an_already_connected_device(self):
        # A phone adb already lists is used as it is: nothing is paired, so no
        # QR code is drawn either.
        self.flag("preconnected")
        result = self.run_install("--timeout", "10")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Using the connected device", result.stdout)
        self.assertNotIn("\033[47;30m", result.stdout)
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
        result = self.run_install("--qr", "--timeout", "10")
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
        result = self.run_install("--qr", "--timeout", "15", FAKE_PHONE_IP="192.168.1.119")
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
        result = self.run_install("--qr", "--timeout", "15", FAKE_PHONE_IP="192.168.1.119")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()
        self.assertIn("connect 192.168.1.119:46037", calls)
        self.assertIn("connect 192.168.1.119:42345", calls)
        self.assertIn("Installed.", result.stdout)

    def test_explains_when_the_debugging_port_does_not_open(self):
        self.flag("stale_connect")
        self.flag("no_phone_connect")
        result = self.run_install("--qr", "--timeout", "3", FAKE_PHONE_IP="192.168.1.119")
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
        result = self.run_install("--qr", "--timeout", "2")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("timed out waiting for the phone", result.stderr)

    def test_help(self):
        result = subprocess.run([os.path.join(TOOL_DIR, "qr_install.sh"), "--help"],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        # The QR code is the way to pair unless --code asks for the six digits.
        self.assertIn("Pair device with QR code", result.stdout)
        self.assertIn("pair by scanning the QR code shown here (the default)",
                      result.stdout)
        self.assertIn("--qr", result.stdout)
        self.assertIn("--code", result.stdout)
        self.assertIn("Pair device with pairing code", result.stdout)
        self.assertIn("WIFI:T:ADB", result.stdout)
        self.assertIn("not with the camera app", result.stdout)

    def test_bad_timeout(self):
        result = self.run_install("--timeout", "soon")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("positive number of seconds", result.stderr)


# A flutter that only builds: it logs its arguments and writes the APK.
FAKE_BUILD_FLUTTER = '''#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$FAKE_FLUTTER_LOG"
out=build/app/outputs/flutter-apk/app-release.apk
case " $* " in *" --debug "*) out=build/app/outputs/flutter-apk/app-debug.apk ;; esac
mkdir -p "$(dirname "$out")"
printf 'fresh apk\\n' > "$out"
'''


class BuildFixture(unittest.TestCase):
    """The installer, copied into a project of its own, with a fake adb and a
    fake flutter (FLUTTER, a script's source) that logs what it is asked."""

    FLUTTER = FAKE_BUILD_FLUTTER

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="harness-qr-build-test-")
        self.project = os.path.join(self.tmp, "harness_client")
        self.tool = os.path.join(self.project, "tool")
        os.makedirs(self.tool)
        os.makedirs(os.path.join(self.project, "lib"))
        for name in ("qr_install.sh", "qr_terminal.py", "serve_apk.py",
                     "check_pub_cache.py"):
            shutil.copy2(os.path.join(TOOL_DIR, name),
                         os.path.join(self.tool, name))
        self.script = os.path.join(self.tool, "qr_install.sh")
        self.apk = os.path.join(
            self.project, "build", "app", "outputs", "flutter-apk",
            "app-release.apk")
        self.state = os.path.join(self.tmp, "state")
        os.makedirs(self.state)
        self.flag("preconnected")

        with open(os.path.join(self.project, "lib", "app.dart"), "w") as f:
            f.write("void main() {}\n")
        for name in ("pubspec.yaml", "pubspec.lock", ".flutter-version"):
            with open(os.path.join(self.project, name), "w") as f:
                f.write("test\n")
        android = os.path.join(self.project, "android", "app", "src", "main")
        os.makedirs(android)
        with open(os.path.join(android, "AndroidManifest.xml"), "w") as f:
            f.write("<manifest/>\n")

        self.adb = os.path.join(self.tmp, "adb")
        with open(self.adb, "w") as f:
            f.write(FAKE_ADB)
        os.chmod(self.adb, 0o755)

        self.flutter_log = os.path.join(self.tmp, "flutter.log")
        self.flutter = os.path.join(self.tmp, "flutter")
        with open(self.flutter, "w") as f:
            f.write(self.FLUTTER)
        os.chmod(self.flutter, 0o755)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def flag(self, name):
        open(os.path.join(self.state, name), "w").close()

    def builds(self):
        try:
            with open(self.flutter_log) as f:
                return f.read().splitlines()
        except FileNotFoundError:
            return []

    def calls(self):
        try:
            with open(os.path.join(self.state, "log")) as f:
                return f.read().splitlines()
        except FileNotFoundError:
            return []

    def run_install(self, *args, **env_extra):
        env = dict(os.environ)
        env.update(ADB=self.adb, FAKE_ADB_STATE=self.state,
                   FLUTTER=self.flutter, FAKE_FLUTTER_LOG=self.flutter_log,
                   FAKE_PUB_CACHE=os.path.join(self.tmp, "pub-cache"))
        env.update(env_extra)
        return subprocess.run(
            [self.script, "--timeout", "10", "--no-launch", *args],
            capture_output=True, text=True, timeout=30, env=env,
            stdin=subprocess.DEVNULL)

    def set_age(self, path, offset):
        stamp = time.time() + offset
        os.utime(path, (stamp, stamp))


class BuildFreshnessTest(BuildFixture):
    """The default run must not install an APK built before the app changed."""

    def test_missing_apk_builds_and_installs(self):
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Building the release APK", result.stdout)
        self.assertIn("no APK at build/app/outputs/flutter-apk/app-release.apk",
                      result.stdout)
        self.assertEqual(self.builds(), ["build apk --release"])
        self.assertTrue(any(" install -r " + self.apk in call
                            for call in self.calls()), self.calls())

    def test_source_newer_than_the_apk_rebuilds(self):
        first = self.run_install()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertEqual(len(self.builds()), 1)
        # The APK is from before a change to the Dart app.
        self.set_age(self.apk, -60)
        self.set_age(os.path.join(self.project, "lib", "app.dart"), 0)
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("lib/app.dart is newer than app-release.apk",
                      result.stdout)
        self.assertEqual(len(self.builds()), 2)

    def test_current_apk_is_not_rebuilt(self):
        first = self.run_install()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.set_age(self.apk, 120)
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("Building the", result.stdout)
        self.assertEqual(len(self.builds()), 1)

    def test_generated_android_files_do_not_trigger_a_build(self):
        first = self.run_install()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.set_age(self.apk, 100)
        generated = os.path.join(self.project, "android", "app", "build",
                                 "generated", "stamp.txt")
        os.makedirs(os.path.dirname(generated))
        with open(generated, "w") as f:
            f.write("generated\n")
        self.set_age(generated, 200)
        local = os.path.join(self.project, "android", "local.properties")
        with open(local, "w") as f:
            f.write("sdk.dir=/tmp\n")
        self.set_age(local, 200)
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("Building the", result.stdout)
        self.assertEqual(len(self.builds()), 1)

    def test_force_builds_an_up_to_date_apk(self):
        first = self.run_install()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.set_age(self.apk, 120)
        result = self.run_install("--build")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("--build was given", result.stdout)
        self.assertEqual(len(self.builds()), 2)

    def test_no_build_warns_about_a_stale_apk(self):
        os.makedirs(os.path.dirname(self.apk))
        with open(self.apk, "w") as f:
            f.write("old apk\n")
        self.set_age(self.apk, -60)
        result = self.run_install("--no-build")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("app-release.apk is older than", result.stdout)
        self.assertIn("may not include the latest app", result.stdout)
        self.assertEqual(self.builds(), [])
        self.assertTrue(any(" install -r " + self.apk in call
                            for call in self.calls()), self.calls())

    def test_no_build_without_an_apk_is_an_error(self):
        result = self.run_install("--no-build")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("APK not found", result.stderr)
        self.assertEqual(self.builds(), [])

    def test_help_describes_the_freshness_check(self):
        result = subprocess.run([self.script, "--help"], capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertIn("up to date", result.stdout)
        self.assertIn("newer than it", result.stdout)


class PubCacheCheckTest(unittest.TestCase):
    """check_pub_cache finds packages that lost files that `pub get` trusts."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="harness-pub-check-test-")
        self.project = os.path.join(self.tmp, "app")
        self.cache = os.path.join(self.tmp, "pub cache", "hosted", "pub.dev")
        os.makedirs(os.path.join(self.project, "lib"))
        os.makedirs(os.path.join(self.project, "test"))
        os.makedirs(os.path.join(self.project, ".dart_tool"))
        self.packages = {}
        self.add_package("widget_kit", "1.2.3",
                         ["lib/widget_kit.dart", "lib/src/impl.dart"])
        # Like cupertino_icons: only assets, no lib/ at all.
        self.add_package("icon_font", "0.1.0", ["assets/icons.ttf"])
        self.write("lib/app.dart",
                   "import 'package:widget_kit/widget_kit.dart' as kit;\n")
        self.write_config()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, relative, text):
        path = os.path.join(self.project, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)

    def add_package(self, name, version, files, root=None, pubspec=True):
        root = root or os.path.join(self.cache, f"{name}-{version}")
        for relative in files + (["pubspec.yaml"] if pubspec else []):
            path = os.path.join(root, relative)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write("x\n")
        self.packages[name] = root
        return root

    def write_config(self, uri=lambda root: "file://" + root.replace(" ", "%20")):
        entries = [{"name": name, "rootUri": uri(root), "packageUri": "lib/"}
                   for name, root in self.packages.items()]
        entries.append({"name": "app", "rootUri": "../", "packageUri": "lib/"})
        with open(os.path.join(self.project, ".dart_tool",
                               "package_config.json"), "w") as f:
            json.dump({"configVersion": 2, "packages": entries}, f)

    def check(self):
        return check_pub_cache.incomplete_packages(self.project)

    def only_problem(self):
        problems = self.check()
        self.assertEqual(len(problems), 1, problems)
        return problems[0]

    def test_a_complete_cache_is_fine(self):
        # icon_font has no lib/, and that is not damage.
        self.assertEqual(self.check(), [])

    def test_nothing_cached_yet_is_fine(self):
        os.unlink(os.path.join(self.project, ".dart_tool", "package_config.json"))
        self.assertEqual(self.check(), [])

    def test_a_library_that_was_emptied_is_found(self):
        # What a reinstall that was stopped half way leaves: lib/ is there and
        # `pub get` still says "Got dependencies!", but its files are gone.
        library = os.path.join(self.packages["widget_kit"], "lib")
        shutil.rmtree(library)
        os.mkdir(library)
        root, label, problem = self.only_problem()
        self.assertEqual(root, self.packages["widget_kit"])
        self.assertEqual(label, "widget_kit 1.2.3")
        self.assertEqual(problem, "lib/ is empty")

    def test_an_emptied_library_is_found_even_when_nothing_imports_it(self):
        self.write("lib/app.dart", "void main() {}\n")
        shutil.rmtree(os.path.join(self.packages["widget_kit"], "lib", "src"))
        os.unlink(os.path.join(self.packages["widget_kit"], "lib", "widget_kit.dart"))
        self.assertEqual(self.only_problem()[2], "lib/ is empty")

    def test_a_library_that_is_gone_is_found_when_the_app_imports_it(self):
        shutil.rmtree(os.path.join(self.packages["widget_kit"], "lib"))
        self.assertEqual(self.only_problem()[2], "lib/widget_kit.dart is missing")

    def test_a_missing_file_the_app_imports_is_found(self):
        os.unlink(os.path.join(self.packages["widget_kit"], "lib", "widget_kit.dart"))
        self.assertEqual(self.only_problem()[2], "lib/widget_kit.dart is missing")

    def test_a_missing_file_nothing_imports_is_not_looked_for(self):
        os.unlink(os.path.join(self.packages["widget_kit"], "lib", "src", "impl.dart"))
        self.assertEqual(self.check(), [])

    def test_a_package_without_a_pubspec_is_found(self):
        os.unlink(os.path.join(self.packages["widget_kit"], "pubspec.yaml"))
        self.assertEqual(self.only_problem()[2], "pubspec.yaml is missing")

    def test_a_package_that_is_not_there_is_left_to_pub_get(self):
        shutil.rmtree(self.packages["widget_kit"])
        self.assertEqual(self.check(), [])

    def test_only_packages_in_the_hosted_cache_are_checked(self):
        # A path dependency or an SDK package can have an empty lib/ (or none)
        # for reasons of its own, and `pub cache repair` cannot fix it.
        sibling = self.add_package("local_kit", "0.0.1", [],
                                   root=os.path.join(self.tmp, "local_kit"))
        os.makedirs(os.path.join(sibling, "lib"))
        self.write_config(lambda root: os.path.relpath(
            root, os.path.join(self.project, ".dart_tool")).replace(os.sep, "/")
            if root == sibling else "file://" + root.replace(" ", "%20"))
        self.assertEqual(self.check(), [])

    def test_relative_and_encoded_root_uris_are_resolved(self):
        library = os.path.join(self.packages["widget_kit"], "lib")
        shutil.rmtree(library)
        os.mkdir(library)
        for uri in (lambda root: os.path.relpath(
                        root, os.path.join(self.project, ".dart_tool")),
                    lambda root: "file://" + root.replace(" ", "%20")):
            self.write_config(uri)
            self.assertEqual(self.only_problem()[1], "widget_kit 1.2.3")

    def test_imports_are_read_from_lib_and_test(self):
        self.write("lib/app.dart", "void main() {}\n")
        self.write("test/app_test.dart",
                   "import 'package:widget_kit/testing.dart';\n")
        self.assertEqual(self.only_problem()[2], "lib/testing.dart is missing")

    def test_alternatives_of_a_conditional_import_are_read(self):
        self.write("lib/app.dart", "import 'stub.dart'\n"
                   "    if (dart.library.io) 'package:widget_kit/io.dart'\n"
                   "    if (dart.library.html) \"package:widget_kit/widget_kit.dart\";\n")
        self.assertEqual(self.only_problem()[2], "lib/io.dart is missing")

    def test_exports_count_and_comments_do_not(self):
        self.write("lib/app.dart", "/// import 'package:widget_kit/commented.dart';\n"
                   "// import 'package:widget_kit/also_commented.dart';\n"
                   "export 'package:widget_kit/exported.dart' show Thing;\n")
        self.assertEqual(self.only_problem()[2], "lib/exported.dart is missing")

    def test_an_unreadable_configuration_is_an_error(self):
        with open(os.path.join(self.project, ".dart_tool",
                               "package_config.json"), "w") as f:
            f.write("{not json")
        with self.assertRaises(check_pub_cache.CheckError):
            self.check()

    def run_cli(self, *args):
        return subprocess.run(
            [sys.executable, "-I", os.path.join(TOOL_DIR, "check_pub_cache.py"),
             *args], capture_output=True, text=True, timeout=20)

    def test_cli_is_quiet_when_all_is_well(self):
        result = self.run_cli(self.project)
        self.assertEqual((result.returncode, result.stdout, result.stderr),
                         (0, "", ""))

    def test_cli_lists_what_is_wrong(self):
        library = os.path.join(self.packages["widget_kit"], "lib")
        shutil.rmtree(library)
        os.mkdir(library)
        result = self.run_cli(self.project)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("widget_kit 1.2.3: lib/ is empty", result.stdout)
        self.assertIn(self.packages["widget_kit"], result.stdout)
        self.assertIn("`flutter pub get` counts them as installed", result.stdout)

    def test_cli_reports_an_unreadable_configuration(self):
        with open(os.path.join(self.project, ".dart_tool",
                               "package_config.json"), "w") as f:
            f.write("[]")
        result = self.run_cli(self.project)
        self.assertEqual(result.returncode, 2)
        self.assertIn("cannot read", result.stderr)

    def test_cli_rejects_unknown_options(self):
        result = self.run_cli("--fix")
        self.assertEqual(result.returncode, 2)
        self.assertIn("check_pub_cache.py [PROJECT]", result.stderr)

    def test_cli_help(self):
        result = self.run_cli("--help")
        self.assertEqual(result.returncode, 0)
        self.assertIn("Find packages in the pub cache that lost their files",
                      result.stdout)


# A flutter that keeps its packages in $FAKE_PUB_CACHE the way pub does: `pub
# get` downloads a package only when its directory is absent and trusts one
# that is there, `pub cache repair` reinstalls them all, and `build apk` fails
# the way the compiler does when a file of a package is gone.
FAKE_PUB_FLUTTER = r"""#!/usr/bin/env python3
import json
import os
import shutil
import sys

args = sys.argv[1:]
with open(os.environ["FAKE_FLUTTER_LOG"], "a") as log:
    log.write(" ".join(args) + "\n")
cache = os.path.join(os.environ["FAKE_PUB_CACHE"], "hosted", "pub.dev")
# name: (version, whether it has a lib/)
PACKAGES = {"widget_kit": ("1.2.3", True), "icon_font": ("0.1.0", False)}


def directory(name):
    return os.path.join(cache, name + "-" + PACKAGES[name][0])


def install(name):
    version, has_lib = PACKAGES[name]
    shutil.rmtree(directory(name), ignore_errors=True)
    os.makedirs(directory(name))
    with open(os.path.join(directory(name), "pubspec.yaml"), "w") as f:
        f.write("name: " + name + "\nversion: " + version + "\n")
    if has_lib:
        os.makedirs(os.path.join(directory(name), "lib", "src"))
        for relative in (name + ".dart", "src/impl.dart"):
            with open(os.path.join(directory(name), "lib", relative), "w") as f:
                f.write("// code\n")


def pub_get():
    for name in PACKAGES:
        if not os.path.isdir(directory(name)):
            install(name)
    entries = [{"name": name, "rootUri": "file://" + directory(name),
                "packageUri": "lib/"} for name in PACKAGES]
    entries.append({"name": "app", "rootUri": "../", "packageUri": "lib/"})
    os.makedirs(".dart_tool", exist_ok=True)
    with open(".dart_tool/package_config.json", "w") as f:
        json.dump({"configVersion": 2, "packages": entries}, f)


if args[:2] == ["pub", "get"]:
    pub_get()
elif args[:3] == ["pub", "cache", "repair"]:
    if os.environ.get("FAKE_REPAIR_BROKEN"):
        sys.exit(0)
    failed = False
    for name in PACKAGES:
        if (os.path.isdir(directory(name)) and
                not os.path.isfile(os.path.join(directory(name), "pubspec.yaml"))):
            # Like pub: it cannot load the package, but it removes it.
            print('Failed to load package: Could not find a file named '
                  '"pubspec.yaml" in "' + directory(name) + '".')
            shutil.rmtree(directory(name))
            failed = True
        else:
            install(name)
    sys.exit(69 if failed else 0)
elif args[:2] == ["build", "apk"]:
    pub_get()
    if os.environ.get("FAKE_BUILD_FAILS"):
        print("FAILURE: Build failed with an exception.", file=sys.stderr)
        sys.exit(3)
    for name, (version, has_lib) in PACKAGES.items():
        library = os.path.join(directory(name), "lib", name + ".dart")
        if has_lib and not os.path.isfile(library):
            print("lib/app.dart:1:8: Error: Error when reading '" + library +
                  "': No such file or directory", file=sys.stderr)
            print("Target kernel_snapshot_program failed: Exception",
                  file=sys.stderr)
            sys.exit(1)
    out = "build/app/outputs/flutter-apk/app-release.apk"
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        f.write("fresh apk\n")
else:
    sys.exit(2)
"""


class PubCacheRepairTest(BuildFixture):
    """A package that lost its files must not stop the install, nor be built on."""

    FLUTTER = FAKE_PUB_FLUTTER

    def setUp(self):
        super().setUp()
        self.app = os.path.join(self.project, "lib", "app.dart")
        with open(self.app, "w") as f:
            f.write("import 'package:widget_kit/widget_kit.dart';\n")
        self.cache = os.path.join(self.tmp, "pub-cache", "hosted", "pub.dev")
        self.widget_kit = os.path.join(self.cache, "widget_kit-1.2.3")

    def fake_flutter(self, *args):
        env = dict(os.environ, FAKE_FLUTTER_LOG=self.flutter_log,
                   FAKE_PUB_CACHE=os.path.join(self.tmp, "pub-cache"))
        subprocess.run([self.flutter, *args], cwd=self.project, env=env,
                       check=True, capture_output=True)

    def cached_before_the_first_build(self):
        """A fresh checkout whose pub cache is full, but nothing says where."""
        self.fake_flutter("pub", "get")
        shutil.rmtree(os.path.join(self.project, ".dart_tool"))
        os.unlink(self.flutter_log)

    def built_before_the_app_changed(self):
        """A built app and a package configuration, and then an app change."""
        first = self.run_install()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        os.unlink(self.flutter_log)
        self.set_age(self.apk, -60)
        self.set_age(self.app, 0)

    def empty(self, directory):
        shutil.rmtree(directory)
        os.mkdir(directory)

    def test_a_damaged_cache_is_repaired_before_the_build(self):
        self.built_before_the_app_changed()
        self.empty(os.path.join(self.widget_kit, "lib"))
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("widget_kit 1.2.3: lib/ is empty", result.stdout)
        self.assertIn("Reinstalling the packages in pubspec.lock", result.stdout)
        self.assertEqual(self.builds(), ["pub cache repair", "pub get",
                                         "build apk --release"])
        self.assertTrue(os.path.isfile(
            os.path.join(self.widget_kit, "lib", "widget_kit.dart")))
        self.assertIn("Installed.", result.stdout)

    def test_damage_that_only_the_failed_build_shows_is_repaired(self):
        self.cached_before_the_first_build()
        self.empty(os.path.join(self.widget_kit, "lib"))
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # The first build is the one that wrote the package configuration.
        self.assertEqual(self.builds(), [
            "build apk --release", "pub cache repair", "pub get",
            "build apk --release"])
        self.assertIn("Error when reading", result.stderr)
        self.assertIn("widget_kit 1.2.3: lib/ is empty", result.stdout)
        self.assertIn("Building the release APK again", result.stdout)
        self.assertIn("Installed.", result.stdout)

    def test_a_package_that_is_only_a_hollow_directory_is_reinstalled(self):
        # `pub cache repair` fails for it (no pubspec.yaml to load) but removes
        # it, and `pub get` downloads it again.
        self.built_before_the_app_changed()
        shutil.rmtree(self.widget_kit)
        os.makedirs(os.path.join(self.widget_kit, "lib"))
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("widget_kit 1.2.3: pubspec.yaml is missing", result.stdout)
        self.assertEqual(self.builds(), ["pub cache repair", "pub get",
                                         "build apk --release"])
        self.assertTrue(os.path.isfile(
            os.path.join(self.widget_kit, "pubspec.yaml")))

    def test_a_complete_cache_is_left_alone(self):
        self.built_before_the_app_changed()
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.builds(), ["build apk --release"])
        self.assertNotIn("Reinstalling", result.stdout)
        self.assertNotIn("incomplete", result.stdout)

    def test_a_failed_build_that_is_not_the_cache_is_not_retried(self):
        self.built_before_the_app_changed()
        result = self.run_install(FAKE_BUILD_FAILS="1")
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertEqual(self.builds(), ["build apk --release"])
        self.assertIn("The build failed", result.stderr)
        self.assertIn("pub cache repair", result.stderr)
        self.assertNotIn("Installing", result.stdout)

    def test_a_cache_that_stays_broken_stops_after_one_repair(self):
        self.cached_before_the_first_build()
        self.empty(os.path.join(self.widget_kit, "lib"))
        result = self.run_install(FAKE_REPAIR_BROKEN="1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.builds(), [
            "build apk --release", "pub cache repair", "pub get"])
        self.assertIn("still incomplete", result.stderr)
        self.assertIn(self.widget_kit, result.stdout)
        self.assertNotIn("Installing", result.stdout)

    def test_a_known_broken_cache_that_cannot_be_repaired_still_builds(self):
        # The package configuration may be stale; the build is the judge.
        self.built_before_the_app_changed()
        self.empty(os.path.join(self.widget_kit, "lib"))
        result = self.run_install(FAKE_REPAIR_BROKEN="1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Building anyway", result.stdout)
        self.assertEqual(self.builds(), [
            "pub cache repair", "pub get", "build apk --release",
            "pub cache repair", "pub get"])

    def test_help_describes_the_cache_repair(self):
        result = subprocess.run([self.script, "--help"], capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertIn("pub cache repair", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
