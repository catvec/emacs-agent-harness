#!/usr/bin/env python3
"""Tests for tool/voice_audio_probe.sh: which device a run may touch.

Run from harness_client:

    python3 tool/test_voice_audio_probe.py

The probe installs an app, speaks aloud and moves the media volume, so the
one thing it must never do on its own is choose a person's phone.  These
tests drive it with a fake adb: the emulator is chosen when one is
attached, a phone is never chosen, a phone run needs its owner's permission
named on the command line, and a phone run cannot raise the volume above
the level the phone already had.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest

TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
PROBE = os.path.join(TOOL_DIR, "voice_audio_probe.sh")
PHONE = "adb-R5CWA0ZLF2T-LXX5ft._adb-tls-connect._tcp"

FAKE_ADB = '''#!/usr/bin/env python3
import os, sys
state = os.environ["FAKE_ADB_STATE"]
args = sys.argv[1:]
with open(os.path.join(state, "log"), "a") as log:
    log.write(" ".join(args) + "\\n")
if args == ["devices"]:
    print("List of devices attached")
    with open(os.path.join(state, "devices")) as f:
        sys.stdout.write(f.read())
    sys.exit(0)
if "--stream" in args and "--get" in args:
    levels = os.path.join(state, "levels")
    if os.path.exists(levels):
        with open(levels) as f:
            left = [line.strip() for line in f if line.strip()]
        level = left.pop(0) if len(left) > 1 else (left[0] if left else "4")
        with open(levels, "w") as f:
            f.write("\\n".join(left) + "\\n")
    else:
        level = "4"
    print("volume is " + level + " in range [0..15]")
    sys.exit(0)
if "getprop" in args:
    print("fake")
    sys.exit(0)
sys.exit(0)
'''


class VoiceAudioProbeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="harness-voice-probe-test-")
        self.state = os.path.join(self.tmp, "state")
        os.makedirs(self.state)
        self.adb = os.path.join(self.tmp, "adb")
        with open(self.adb, "w") as f:
            f.write(FAKE_ADB)
        os.chmod(self.adb, 0o755)
        self.apk = os.path.join(self.tmp, "app.apk")
        with open(self.apk, "w") as f:
            f.write("fake apk")
        self.out = os.path.join(self.tmp, "out")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def attached(self, *serials):
        with open(os.path.join(self.state, "devices"), "w") as f:
            for serial in serials:
                f.write(serial + "\tdevice\n")

    def run_probe(self, *args):
        env = dict(os.environ)
        env.update(ADB=self.adb, FAKE_ADB_STATE=self.state,
                   HARNESS_VOICE_PROBE_PACE="0",
                   HARNESS_VOICE_PROBE_OUT=self.out)
        return subprocess.run(
            [PROBE, "--no-build", "--apk", self.apk, *args],
            capture_output=True, text=True, timeout=120, env=env)

    def calls(self):
        log = os.path.join(self.state, "log")
        if not os.path.exists(log):
            return []
        with open(log) as f:
            return f.read().splitlines()

    def targets(self):
        """The serials every -s call named, in the order first seen."""
        seen = []
        for call in self.calls():
            words = call.split()
            if len(words) >= 2 and words[0] == "-s" and words[1] not in seen:
                seen.append(words[1])
        return seen

    def volumes_set(self):
        """Every media volume level the run set, in order."""
        levels = []
        for call in self.calls():
            words = call.split()
            if "--stream" in words and "--set" in words:
                levels.append(words[words.index("--set") + 1])
        return levels

    # The phone is never chosen, however it is attached.

    def test_phone_alone_is_never_chosen(self):
        self.attached(PHONE)
        result = self.run_probe()
        self.assertEqual(4, result.returncode, result.stdout + result.stderr)
        self.assertIn("no emulator is attached", result.stderr)
        self.assertEqual(["devices"], self.calls(),
                         "a phone-only run must not reach the phone")

    def test_no_device_at_all_is_no_device(self):
        self.attached()
        result = self.run_probe()
        self.assertEqual(4, result.returncode, result.stdout + result.stderr)
        self.assertEqual(["devices"], self.calls())

    def test_a_phone_is_refused_as_device(self):
        self.attached(PHONE)
        result = self.run_probe("--device", PHONE)
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("a phone is run with --real-device", result.stderr)
        self.assertEqual([], self.calls(), "nothing may reach a device")

    def test_a_real_device_without_its_owners_permission_is_refused(self):
        self.attached(PHONE)
        result = self.run_probe("--real-device", PHONE)
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("--owner-permission", result.stderr)
        self.assertEqual([], self.calls(), "nothing may reach a device")

    def test_the_permission_alone_is_refused(self):
        self.attached("emulator-5556")
        result = self.run_probe("--owner-permission")
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("an emulator needs none", result.stderr)
        self.assertEqual([], self.calls())

    def test_an_emulator_is_not_a_real_device(self):
        self.attached("emulator-5556")
        result = self.run_probe("--real-device", "emulator-5556",
                                "--owner-permission")
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("an emulator is run with --device", result.stderr)
        self.assertEqual([], self.calls())

    def test_both_device_flags_is_refused(self):
        self.attached("emulator-5556", PHONE)
        result = self.run_probe("--device", "emulator-5556",
                                "--real-device", PHONE,
                                "--owner-permission")
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("not both", result.stderr)
        self.assertEqual([], self.calls())

    def test_two_emulators_need_a_name(self):
        self.attached("emulator-5556", "emulator-5558")
        result = self.run_probe()
        self.assertEqual(2, result.returncode, result.stdout + result.stderr)
        self.assertIn("more than one emulator", result.stderr)
        self.assertEqual(["devices"], self.calls())

    # The emulator is the default, and a phone beside it is left alone.

    def test_the_emulator_is_chosen_and_the_phone_left_alone(self):
        self.attached(PHONE, "emulator-5556")
        result = self.run_probe()
        self.assertEqual(["emulator-5556"], self.targets(),
                         "every call must go to the emulator:\n"
                         + "\n".join(self.calls()))
        self.assertIn("leaving the phone " + PHONE + " alone",
                      result.stdout)

    def test_a_named_emulator_is_used(self):
        self.attached("emulator-5556", "emulator-5558")
        self.run_probe("--device", "emulator-5558")
        self.assertEqual(["emulator-5558"], self.targets())

    def test_the_emulator_run_moves_the_volume_both_ways(self):
        self.attached("emulator-5556")
        self.run_probe()
        self.assertEqual(["7", "2", "13", "4"], self.volumes_set())

    # A phone run needs its owner's permission, and cannot get louder.

    def test_a_permitted_phone_run_stays_at_its_owners_level(self):
        self.attached(PHONE)
        result = self.run_probe("--real-device", PHONE,
                                "--owner-permission")
        self.assertEqual([PHONE], self.targets())
        self.assertEqual(["4", "2", "4", "4"], self.volumes_set(),
                         "7 and 13 are louder than the phone's 4")
        self.assertIn("would be louder than this phone is (4)",
                      result.stdout)
        self.assertIn("PHONE " + PHONE, result.stdout)

    def test_a_phone_run_puts_its_owners_level_back(self):
        self.attached(PHONE)
        self.run_probe("--real-device", PHONE, "--owner-permission")
        self.assertEqual("4", self.volumes_set()[-1])

    def test_a_phone_run_respects_a_level_lowered_meanwhile(self):
        """Its owner may turn it down while the run speaks; the run may not
        put it back up."""
        self.attached(PHONE)
        # 4 at the start, then 1 from the second reading on.
        with open(os.path.join(self.state, "levels"), "w") as f:
            f.write("4\n4\n4\n1\n")
        result = self.run_probe("--real-device", PHONE,
                                "--owner-permission")
        self.assertEqual(["4", "2", "1", "1"], self.volumes_set(),
                         "7 and 13 must not pass the level it is at")
        self.assertIn("would be louder than this phone is (1)",
                      result.stdout)

    # The help is the header, not the body of the script.

    def test_help_is_the_header(self):
        result = subprocess.run([PROBE, "--help"], capture_output=True,
                                text=True, timeout=60)
        self.assertEqual(0, result.returncode)
        self.assertIn("--real-device SERIAL", result.stdout)
        self.assertIn("--owner-permission", result.stdout)
        self.assertNotIn("tool_dir=", result.stdout)


if __name__ == "__main__":
    unittest.main()
