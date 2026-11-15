#!/usr/bin/env python3
"""Drive the real Harness Android app on a disposable emulator, against a local
WebRTC receiver, and record what actually happened.

This is the emulator half of the live camera / screen-share evidence.  It is
not a unit test and it is not a mock: it installs the APK the repository
builds, launches it, types into its real forms, taps the same controls a person
taps, and reads the receiver's own log for what arrived.

    python3 e2e/media_emulator.py --phase all --out /tmp/media-e2e
    python3 e2e/media_emulator.py --phase status --out /tmp/media-e2e

Why one call: this host has no `/dev/kvm` and cannot create one (the sandbox
denies `mknod` and there is no device node), so the emulator runs under TCG
software emulation and a boot takes minutes.  A run therefore boots, installs
and drives in one process; `--phase` exists for a quick look at a running
device, not for splitting the evidence run.

What is real in a run, and what is not:

  * real: the APK, the app's own `WebRtcMediaCapturePlatform`, the Android
    camera service and the emulator's synthetic camera, MediaProjection and its
    consent dialog, the MediaProjection foreground service and its
    notification, libwebrtc's encoder, DTLS/SRTP, the app's own signalling
    request, the receiver's decoding, and the ACP request the app makes for a
    frame.
  * not real: the receiver is a local aiortc peer, not a production provider;
    the camera's picture is the emulator's synthetic scene, not a person or a
    room; the harness is `tool/mock_harness_server.dart`, a local ACP peer that
    answers `session/media` and traces prompts, not a real harness with a
    model; the machine is an emulator without hardware acceleration, not a
    phone.  docs/live-video-screen-share.md says what each of those leaves
    unproven.

Every observation is written as one JSON object a line to `<out>/run.jsonl`,
and each scenario also to `<out>/<scenario>.json`.  Screenshots go to
`<out>/shots`.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CLIENT = os.path.dirname(HERE)
REPO = os.path.dirname(CLIENT)
PACKAGE = "app.harness.client"
# The launcher activity's class, as the installed package names it.  The
# application id and the Kotlin package differ (`app.harness.client` against
# `app.harness.harness_client`), so a shorthand `PACKAGE/.MainActivity` names a
# class that does not exist; the driver reads the real one from the package
# manager instead of guessing it.
ACTIVITY_PLACEHOLDER = f"{PACKAGE}/.MainActivity"
AVD_NAME = "media-e2e-34"
SNAPSHOT_NAME = "media-e2e-prepared"
CAMERA = "android.permission.CAMERA"
RECORD_AUDIO = "android.permission.RECORD_AUDIO"
MOCK_PORT = 4277
TRACK_PORT = 8099
FRAME_PORT = 8098



def _default_host() -> str:
    """This machine's address on the network the guest reaches.

    A guest on the emulator's NAT can reach the host's LAN address but
    not its loopback, and the media path is UDP: it cannot travel
    through `adb reverse` the way the ACP socket does.
    """
    try:
        result = subprocess.run(
            ["sh", "-c", "ip -4 route get 1.1.1.1 2>/dev/null"],
            capture_output=True, text=True, timeout=10,
        )
        for token in result.stdout.split():
            if token == "src" and result.stdout.split().index(token) + 1 < len(
                result.stdout.split()
            ):
                parts = result.stdout.split()
                return parts[parts.index(token) + 1]
    except Exception:
        pass
    return "127.0.0.1"

def log(out: str, event: str, **fields) -> None:
    record = {"event": event, "at": time.strftime("%Y-%m-%dT%H:%M:%S"), **fields}
    line = json.dumps(record, sort_keys=True)
    print(line, flush=True)
    with open(os.path.join(out, "run.jsonl"), "a") as handle:
        handle.write(line + "\n")


class Run:
    """The emulator, adb, the mock harness and the receivers, as one directory
    holds them."""

    def __init__(self, arguments) -> None:
        self.out = os.path.abspath(arguments.out)
        os.makedirs(os.path.join(self.out, "shots"), exist_ok=True)
        self.sdk = arguments.sdk or os.environ.get("ANDROID_HOME", "")
        self.python = arguments.python or sys.executable
        self.dart = arguments.dart or ""
        self.flutter = arguments.flutter or ""
        self.avd_home = os.path.join(self.out, "avd")
        self.serial = arguments.serial or "emulator-5556"
        self.adb = os.path.join(self.sdk, "platform-tools", "adb")
        self.emulator = os.path.join(self.sdk, "emulator", "emulator")
        self.mock_port = arguments.acp_port
        self.track_port = arguments.port
        self.frame_port = arguments.frame_port
        self.model = arguments.model
        # The host's own address on the network the guest can reach, not
        # 127.0.0.1: the ACP socket is TCP and travels through `adb
        # reverse`, but the media path is UDP, and a guest told to send
        # its RTP to its own loopback never reaches a receiver on this
        # machine -- the app then reports the call failed, which reads
        # exactly like a client that cannot send video.
        self.host = arguments.host or _default_host()
        # The ACP socket is TCP through adb reverse, so its address is
        # the guest's own loopback.
        self.acp_host = "127.0.0.1"
        # A run that wipes the data image starts from a clean guest, which is
        # what makes an install and a launch reproducible after a killed run.
        self.wipe = bool(getattr(arguments, "fresh", False))
        self._activity = ""
        self.boot_timeout = float(getattr(arguments, "boot_timeout", 1800))
        if not os.path.exists(self.adb):
            raise SystemExit(f"no adb under {self.sdk}")
        self.env = dict(
            os.environ,
            ANDROID_HOME=self.sdk,
            ANDROID_SDK_ROOT=self.sdk,
            ANDROID_AVD_HOME=self.avd_home,
            ANDROID_EMULATOR_HOME=os.path.join(self.out, "emu-home"),
        )
        self.env.pop("DISPLAY", None)

    # -- adb -----------------------------------------------------------------

    def sh(self, command: list[str], check: bool = False, timeout: int = 300,
           cwd: str | None = None, env: dict | None = None):
        result = subprocess.run(
            command,
            env=env or self.env,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout,
            errors="replace",
        )
        if check and result.returncode != 0:
            raise SystemExit(
                f"failed: {' '.join(command)}\n{result.stdout}\n{result.stderr}"
            )
        return result

    def device(self, *arguments: str, check: bool = False, timeout: int = 300):
        return self.sh(
            [self.adb, "-s", self.serial, *arguments], check=check, timeout=timeout
        )

    def shell(self, command: str, check: bool = False, timeout: int = 300) -> str:
        return self.device("shell", command, check=check, timeout=timeout).stdout

    def online(self) -> bool:
        return self.serial in self.sh([self.adb, "devices"]).stdout

    # -- the emulator --------------------------------------------------------

    def create_avd(self) -> None:
        """Make this run's AVD its own, under `<out>/avd`.

        `avdmanager` writes an `.ini` whose `path=` is absolute, so a run that
        only copies a directory still uses the AVD the `.ini` names -- two runs
        then fight over one AVD and "Running multiple emulators with the same
        AVD" hides the real state.  The `.ini` is therefore rewritten here to
        point at this run's own directory.
        """
        os.makedirs(self.avd_home, exist_ok=True)
        directory = os.path.join(self.avd_home, f"{AVD_NAME}.avd")
        ini = os.path.join(self.avd_home, f"{AVD_NAME}.ini")
        self.tune_avd(directory)
        if os.path.isdir(directory):
            if os.path.exists(ini):
                with open(ini) as handle:
                    points_here = f"path={directory}" in handle.read()
                if not points_here:
                    with open(ini, "w") as handle:
                        handle.write(
                            "avd.ini.encoding=UTF-8\n"
                            f"path={directory}\n"
                            "target=android-34\n"
                        )
                    log(self.out, "avd-ini-repointed", path=directory)
            else:
                with open(ini, "w") as handle:
                    handle.write(
                        "avd.ini.encoding=UTF-8\n"
                        f"path={directory}\n"
                        "target=android-34\n"
                    )
                log(self.out, "avd-ini-written", path=directory)
            return
        manager = os.path.join(self.sdk, "cmdline-tools", "latest", "bin", "avdmanager")
        result = subprocess.run(
            [manager, "create", "avd", "-n", AVD_NAME, "-k",
             "system-images;android-34;default;x86_64", "-d", "pixel_5", "--force"],
            env=self.env, capture_output=True, text=True, input="no\n", timeout=300,
        )
        log(self.out, "avd-created", ok=result.returncode == 0, detail=result.stdout[-400:])

    def tune_avd(self, directory: str) -> None:
        """Give the guest the resources this host actually has.

        The `pixel_5` profile asks for four cores and 2 GB.  Under TCG that is
        not enough to keep SystemUI, the launcher and a release Flutter app
        inside Android's input-dispatch deadlines: systemui ANRs in a loop and
        the app is killed for an input dispatch it never got.  The cores and
        memory below are the host's, not the profile's.
        """
        path = os.path.join(directory, "config.ini")
        if not os.path.isdir(directory) or not os.path.exists(path):
            return
        wanted = {
            "hw.cpu.ncore": "8",
            "hw.ramSize": "4G",
            "vm.heapSize": "512M",
        }
        with open(path) as handle:
            lines = handle.read().splitlines()
        changed = []
        seen = set()
        out = []
        for line in lines:
            key = line.split("=")[0].strip()
            if key in wanted:
                seen.add(key)
                value = wanted[key]
                if line.strip() != f"{key} = {value}":
                    changed.append(f"{key}={value}")
                out.append(f"{key} = {value}")
            else:
                out.append(line)
        for key, value in wanted.items():
            if key not in seen:
                out.append(f"{key} = {value}")
                changed.append(f"{key}={value}")
        with open(path, "w") as handle:
            handle.write("\n".join(out) + "\n")
        if changed:
            log(self.out, "avd-tuned", values=changed)
            # A snapshot holds the guest's own copy of the hardware it was
            # saved on.  Changing the cores or the RAM makes it unloadable, and
            # this emulator's answer to an unloadable snapshot is not a cold
            # boot but a start that never finishes.  Forgetting it is what makes
            # the next start a boot again.
            self.forget_snapshot()

    def forget_snapshot(self) -> None:
        """Drop a snapshot that no longer matches this AVD's hardware."""
        path = os.path.join(
            self.avd_home, f"{AVD_NAME}.avd", "snapshots", SNAPSHOT_NAME)
        if not os.path.isdir(path):
            return
        shutil.rmtree(path, ignore_errors=True)
        log(self.out, "snapshot-forgotten", name=SNAPSHOT_NAME, path=path)

    def clear_locks(self) -> None:
        """Remove what a killed emulator left behind in the AVD directory.

        A run that is cancelled (a tool timeout, a taken slot) leaves the
        emulator process dead and its lock files in place.  The next start
        then refuses with "Running multiple emulators with the same AVD",
        which would otherwise be indistinguishable from a slow boot.
        """
        directory = os.path.join(self.avd_home, f"{AVD_NAME}.avd")
        removed = []
        if not os.path.isdir(directory):
            return
        for name in os.listdir(directory):
            if not name.endswith(".lock"):
                continue
            path = os.path.join(directory, name)
            try:
                os.remove(path)
                removed.append(name)
            except OSError:
                pass
        if removed:
            log(self.out, "locks-cleared", files=removed)

    def snapshot_exists(self) -> bool:
        """Whether this run's AVD holds the prepared snapshot."""
        path = os.path.join(
            self.avd_home, f"{AVD_NAME}.avd", "snapshots", SNAPSHOT_NAME)
        return os.path.isdir(path) and bool(os.listdir(path))

    def save_snapshot(self, force: bool = False) -> None:
        """Save the booted, prepared guest, for the next run to resume from.

        The save stops the guest for a while, so an existing snapshot is
        left alone unless FORCE says this run has something new in it.
        """
        if self.wipe:
            return
        if self.snapshot_exists() and not force:
            log(self.out, "snapshot-kept", name=SNAPSHOT_NAME)
            return
        result = self.sh(["timeout", "300", self.adb, "-s", self.serial,
                          "emu", "avd", "snapshot", "save", SNAPSHOT_NAME],
                         timeout=330)
        saved = self.snapshot_exists()
        log(self.out, "snapshot-saved", name=SNAPSHOT_NAME, saved=saved,
            output=(result.stdout + result.stderr).strip()[-300:])

    def kill_emulator(self, seconds: float = 90) -> None:
        """Stop any emulator of this run's AVD and wait until it is gone.

        The graceful shutdown the emulator does on SIGTERM takes tens of
        seconds on this host, and until it finishes QEMU still holds the
        images ("Failed to get write lock", "Is another process using the
        image?").  Waiting for the process is what makes the next start work.
        """
        pattern = os.path.join(self.avd_home, f"{AVD_NAME}.avd")

        def alive() -> list[int]:
            result = self.sh(["pgrep", "-f", pattern])
            pids = []
            for line in result.stdout.splitlines():
                line = line.strip()
                # `pgrep -f` also matches this driver's own command line.
                if line.isdigit() and int(line) != os.getpid():
                    pids.append(int(line))
            return pids

        pids = alive()
        if not pids:
            return
        for pid in pids:
            try:
                os.kill(pid, 15)
            except OSError:
                pass
        deadline = time.time() + seconds
        while time.time() < deadline and alive():
            time.sleep(2)
        for pid in alive():
            try:
                os.kill(pid, 9)
            except OSError:
                pass
            time.sleep(1)
        log(self.out, "emulator-killed", pids=pids, left=alive())
        time.sleep(3)

    def start_emulator(self) -> None:
        """Start the emulator, from the run's snapshot when it has one.

        A cold boot of this image is 6 to 13 minutes under TCG, and the driver
        is killed with the tool call that started it, so a run that needs a
        second look would pay that boot again.  A snapshot of the booted,
        prepared guest turns that into seconds; it is saved by [save_snapshot]
        once the guest is ready, and never loaded by a `--fresh` run.
        """
        console = open(os.path.join(self.out, "emulator.out"), "a")
        snapshot = ["-snapshot", SNAPSHOT_NAME, "-no-snapshot-save"]
        if self.wipe or not self.snapshot_exists():
            snapshot = ["-no-snapshot"]
        subprocess.Popen(
            [
                self.emulator, "-avd", AVD_NAME,
                "-no-window", "-no-boot-anim", *snapshot,
                # The live path opens the microphone; the voice call cannot
                # start without one.  This host has no sound device, so the
                # guest's audio HAL is the emulator's own (capture is silence
                # and nothing of this machine is recorded), and host audio is
                # off so no host device is ever opened.
                "-audio", "none",
                "-gpu", "swiftshader_indirect",
                # This host has no KVM: TCG software emulation only.
                "-accel", "off",
                "-port", self.serial.rsplit("-", 1)[-1],
                # A synthetic, disposable camera scene: no person, no room,
                # and nothing from this machine's real camera.
                "-camera-back", "emulated", "-camera-front", "emulated",
                "-no-metrics",
            ],
            env=self.env, stdout=console, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        log(self.out, "emulator-started", serial=self.serial)

    def wipe_data(self) -> None:
        """Forget the AVD's data partition.

        The driver is killed with the tool call that started it, so the guest
        never shuts down cleanly; a data image left half-written by that is
        the difference between an app that starts and one whose start never
        spawns a process.  A run that begins from a clean data image is both
        reproducible and cheaper to reason about than one that inherits a
        killed boot.
        """
        directory = os.path.join(self.avd_home, f"{AVD_NAME}.avd")
        if not os.path.isdir(directory):
            return
        removed = []
        for name in os.listdir(directory):
            if not name.startswith("userdata-qemu.img"):
                continue
            try:
                os.remove(os.path.join(directory, name))
                removed.append(name)
            except OSError:
                pass
        if removed:
            log(self.out, "data-wiped", files=removed)

    def await_boot(self, seconds: float) -> bool:
        """Wait until Android is up *and* its services answer.

        `sys.boot_completed` goes to 1 before the package manager is ready on
        this software-emulated host; an install in that window fails with
        "Can't find service: package" and costs the whole boot.
        """
        self.sh([self.adb, "stop-server"])
        started = time.time()
        deadline = started + seconds
        self.sh([self.adb, "start-server"])
        # A snapshot resume comes up in seconds; a cold boot in minutes.  Log
        # which one it was, so a slow run is not mistaken for a regression.
        booted_at = None
        while time.time() < deadline:
            if self.online():
                booted = self.shell("getprop sys.boot_completed").strip()
                if booted == "1":
                    if booted_at is None:
                        booted_at = time.time()
                        log(self.out, "booted", seconds=round(booted_at - started, 1))
                    if "found" in self.shell("service check package"):
                        log(self.out, "services-ready",
                            seconds=round(time.time() - booted_at, 1))
                        return True
            time.sleep(6)
        return False

    def boot(self) -> None:
        """Start the emulator if it is not already up, and wait for Android."""
        if self.online():
            return
        self.create_avd()
        # A previous run that was cut short can leave a process, its locks and
        # a half-written data image behind; clearing all three is what lets a
        # second attempt start, and start an app.
        self.kill_emulator()
        self.clear_locks()
        if self.wipe:
            self.wipe_data()
        self.start_emulator()
        # A snapshot saved by an emulator with other hardware settings does not
        # load: the guest says so in emulator.out (`Length mismatch ... error
        # while loading state for instance ... device 'ram'`) and cold-boots
        # anyway.  Waiting the whole timeout for a boot that is not coming is
        # what makes such a run cost two boots.  A short wait first, then the
        # snapshot is forgotten and the cold boot is the one that is waited for.
        if self.snapshot_exists() and not self.wipe:
            if self.await_boot(min(self.boot_timeout, 240)):
                return
            log(self.out, "snapshot-unusable", name=SNAPSHOT_NAME)
            self.kill_emulator()
            self.forget_snapshot()
            self.clear_locks()
            self.start_emulator()
        # A clean boot of this image is 8 to 13 minutes under TCG; the ceiling
        # is a runaway guard, not an estimate.
        if self.await_boot(self.boot_timeout):
            return
        # One more try: a start that raced the dying process, or an adb server
        # that outlived the guest, fails before Android ever runs.
        log(self.out, "boot-retry", seconds=self.boot_timeout)
        self.kill_emulator()
        self.clear_locks()
        self.start_emulator()
        if self.await_boot(self.boot_timeout):
            return
        raise SystemExit(
            f"the emulator did not finish booting in {self.boot_timeout}s")

    def prepare(self) -> None:
        """Make the emulator a plausible phone: awake, unlocked, animations off."""
        self.boot()
        self.shell("input keyevent KEYCODE_WAKEUP")
        self.shell("wm dismiss-keyguard")
        self.shell("settings put global window_animation_scale 0")
        self.shell("settings put global transition_animation_scale 0")
        self.shell("settings put global animator_duration_scale 0")
        self.shell("settings put system screen_off_timeout 2147483647")
        # The display must stay awake *and* unlocked: a locked screen renders
        # black, so `screencap` gives a black PNG and every tap lands on the
        # keyguard instead of the app, which looks exactly like an app that
        # ignores its controls.
        self.shell("svc power stayon true")
        self.shell("settings put secure lock_screen_lock_after_timeout 2147483647")
        self.shell("locksettings set-disabled true")
        self.shell("input keyevent KEYCODE_WAKEUP")
        self.shell("wm dismiss-keyguard")
        # The ANR dialogs are *shown*, not hidden: on a guest this slow the
        # app will occasionally miss an input deadline, and an ANR whose
        # dialog is hidden is an app the system kills without asking.  A
        # dialog the driver can answer with "Wait" is an app that
        # survives it, which is the difference between a slow run and a
        # failed one.
        self.shell("settings put global hide_error_dialogs 0")
        # Half the Pixel 5 panel: the same phone shape, a quarter of the
        # pixels for the software renderer to fill on this KVM-less host.
        self.shell("wm size 540x1170")
        self.shell("wm density 220")
        for port in (self.mock_port, self.track_port, self.frame_port):
            self.device("reverse", f"tcp:{port}", f"tcp:{port}")
        self.start_logcat()
        # Booted is not the same as usable: the guest's own processes
        # are still starting and restarting.  Everything below drives an
        # app, and an app driven on a guest that is still booting is
        # killed for the input it cannot answer in time.
        self.settle_guest()
        log(
            self.out,
            "prepared",
            model=self.shell("getprop ro.product.model").strip(),
            release=self.shell("getprop ro.build.version.release").strip(),
            sdk=self.shell("getprop ro.build.version.sdk").strip(),
            abi=self.shell("getprop ro.product.cpu.abi").strip(),
            fingerprint=self.shell("getprop ro.build.fingerprint").strip(),
            host_date=self.shell("date -u +%Y-%m-%dT%H:%M:%SZ").strip(),
        )

    def start_logcat(self) -> None:
        """Keep the device's log for the whole run.

        When the app leaves the foreground or a capture fails, the reason is
        in the system log (an ANR, a permission refusal, a native crash), not
        on the screen the run can see.  The capture is adb's own `logcat`,
        filtered to the app and the system's activity decisions.
        """
        path = os.path.join(self.out, "logcat.txt")
        handle = open(path, "a")
        self.device("logcat", "-c")
        subprocess.Popen(
            [self.adb, "-s", self.serial, "logcat", "-v", "threadtime"],
            env=self.env, stdout=handle, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        log(self.out, "logcat", path=path)

    def logcat_tail(self, lines: int = 60) -> str:
        """The last lines of the run's own log capture."""
        path = os.path.join(self.out, "logcat.txt")
        if not os.path.exists(path):
            return ""
        with open(path, errors="replace") as handle:
            return "".join(handle.readlines()[-lines:])

    # -- the app -------------------------------------------------------------
    def clear_app(self) -> None:
        """Forget what the last run left in the app's own storage.

        The seed the E2E build writes is the connection and the voice
        provider; a run that starts from the previous run's values
        would report a state nobody set.  Clearing the app's data is
        the guest's own "clear storage", and the app is installed
        again afterwards because clearing it uninstalls nothing but
        does take its permissions.
        """
        self.shell("pm clear " + PACKAGE)
        log(self.out, "app-cleared", package=PACKAGE)


    def build_apk(self) -> None:
        """Build the APK this run installs, with the run's own addresses.

        The app is built from this checkout with `E2E`, the semantics flag
        the screenshot run uses, and two more defines naming the local
        peers: without them the run would have to type an address and a
        realtime endpoint into the app's forms on a software-emulated
        guest, which costs minutes per field.  Nothing of this build is
        the app a person installs; a release build carries no such seed.
        """
        if not self.flutter:
            raise SystemExit("no flutter: pass --flutter to build the APK")
        log(self.out, "building", apk="app-release.apk")
        # `flutter` needs the toolchain the client's own script sets up
        # -- the JDK and the SDK on PATH -- not just ANDROID_HOME: without
        # them Gradle never starts and the build hangs until the timeout.
        toolchain = self.sh(["bash", "tool/client_toolchain.sh"], cwd=CLIENT,
                            timeout=300)
        env = dict(self.env)
        for line in toolchain.stdout.splitlines():
            line = line.strip()
            if not line.startswith("export "):
                continue
            name, _, value = line[len("export "):].partition("=")
            if name:
                env[name] = os.path.expandvars(value)
        env["PATH"] = env.get("PATH", "")
        log(self.out, "toolchain", java=env.get("JAVA_HOME", "")[-24:],
            sdk=env.get("ANDROID_HOME", "")[-24:])
        result = self.sh(
            [self.flutter, "build", "apk", "--release",
             "--dart-define=E2E=true",
             f"--dart-define=E2E_ACP=ws://{self.acp_host}:{self.mock_port}/acp",
             f"--dart-define=E2E_REALTIME=http://{self.host}:{self.track_port}/voice",
             f"--dart-define=E2E_REALTIME_MODEL={self.model}"],
            cwd=CLIENT, timeout=3600, env=env)
        log(self.out, "built", ok=result.returncode == 0,
            tail=(result.stdout + result.stderr).strip()[-600:])
        if result.returncode != 0:
            raise SystemExit("the APK did not build")

    def apk(self) -> str:
        for name in ("app-release.apk", "app-debug.apk"):
            path = os.path.join(CLIENT, "build", "app", "outputs", "flutter-apk", name)
            if os.path.exists(path):
                return path
        raise SystemExit(
            "no APK: build it first (flutter build apk --release --dart-define=E2E=true)"
        )

    def install(self) -> None:
        apk = self.apk()
        self.shell("pm uninstall " + PACKAGE)
        # The package service can refuse for a moment after a boot on this
        # host; a retry costs seconds where a failed run costs the boot.
        for attempt in range(5):
            result = self.device("install", "-r", "-g", apk, timeout=1800)
            if result.returncode == 0 and "Success" in result.stdout:
                log(self.out, "installed", attempt=attempt + 1,
                    apk=os.path.relpath(apk, CLIENT),
                    bytes=os.path.getsize(apk), output=result.stdout.strip())
                return
            log(self.out, "install-failed", attempt=attempt + 1,
                output=(result.stdout + result.stderr).strip()[-400:])
            if "Can't find service" not in result.stdout + result.stderr:
                break
            time.sleep(20)
        raise SystemExit("the APK did not install")

    def installed(self) -> bool:
        return "package:" in self.shell(f"pm list packages {PACKAGE}")

    def activity(self) -> str:
        """The app's launcher activity, as the package manager names it.

        `am start -n app.harness.client/.MainActivity` fails with "Activity
        class does not exist": the manifest declares the activity by the
        Gradle *namespace* (`app.harness.harness_client.MainActivity`) while
        the application id is `app.harness.client`, so the shorthand does not
        resolve.  The component is read from the installed package (and from
        the APK when the system cannot answer yet), never guessed.
        """
        if self._activity:
            return self._activity
        for attempt in range(6):
            text = self.shell(
                f"cmd package resolve-activity --brief -a android.intent.action.MAIN "
                f"-c android.intent.category.LAUNCHER {PACKAGE}")
            for line in text.splitlines():
                line = line.strip()
                if "/" in line and line.startswith(PACKAGE):
                    self._activity = line
                    log(self.out, "activity", component=line, source="package manager")
                    return line
            time.sleep(5)
        found = self.apk_activity() or ACTIVITY_PLACEHOLDER
        self._activity = found
        log(self.out, "activity", component=found, source="apk")
        return found

    def apk_activity(self) -> str:
        """The launcher activity named in the APK's manifest."""
        tools = sorted(
            (os.path.join(self.sdk, "build-tools", name)
             for name in os.listdir(os.path.join(self.sdk, "build-tools"))),
            reverse=True) if os.path.isdir(os.path.join(self.sdk, "build-tools")) else []
        binary = tools[0] + "/aapt2" if tools else ""
        if not binary or not os.path.exists(binary):
            return ""
        result = self.sh([binary, "dump", "xmltree", "--file", "AndroidManifest.xml",
                          self.apk()], timeout=120)
        for line in result.stdout.splitlines():
            if "android:name" in line and "MainActivity" in line:
                name = line.split('"')[1] if '"' in line else ""
                if name:
                    return f"{PACKAGE}/{name}"
        return ""

    def logcat_crash(self) -> str:
        """What the last start said, when the app is not in front."""
        return self.shell(
            "logcat -d -t 400 | grep -E "
            "'AndroidRuntime|FATAL|harness|ActivityManager: Start proc|Force finishing' "
            "| tail -40"
        ).strip()

    def settle_guest(self, seconds: float = 300) -> bool:
        """Wait for the guest's own processes to stop ANR-ing.

        A cold boot under TCG leaves SystemUI, the launcher and the
        phone app starting and restarting for minutes.  SystemUI is
        what draws a window transition, so an app started while it
        is restarting never gets a focused window -- and the input
        the driver then sends to that app is what the system
        charges to it as an ANR.  A guest that has gone quiet is
        the precondition for driving anything at all.

        The display is woken here too: a guest that slept renders
        black, and a black screenshot is indistinguishable from an
        app that did nothing.
        """
        deadline = time.time() + seconds
        quiet_since = time.time()
        seen = 0
        while time.time() < deadline:
            tail = self.shell("logcat -d -t 200", timeout=120)
            anrs = sum(
                1 for line in tail.splitlines()
                if "ANR in " in line and "app.harness" not in line)
            if anrs > seen:
                seen = anrs
                quiet_since = time.time()
            elif time.time() - quiet_since >= 60:
                log(self.out, "guest-settled",
                    seconds=round(time.time() - quiet_since, 1),
                    anrs=seen)
                return True
            time.sleep(6)
        log(self.out, "guest-busy", anrs=seen)
        return False

    def launch(self) -> None:
        """Bring the app to the front, and keep asking while the system is slow.

        Under TCG the first start of a release Flutter build takes tens of
        seconds to draw, and the system's own processes ANR and restart in
        the meantime.  A second `am start` while the first transition is
        still pending wedges the window manager: the activity record then
        never adds a window, every input event waits on it, and the
        system charges those events to the app as an ANR.  So the start
        is made once, and what is waited for is the app being resumed
        *and* focused -- the two things input needs.  A timeout ANR
        dialog over the app is answered with "Wait".
        """
        self.shell("am force-stop " + PACKAGE)
        time.sleep(3)
        self.shell(f"am start -n {self.activity()}", timeout=600)
        log(self.out, "am-start", activity=self.activity())
        deadline = time.time() + 600
        while time.time() < deadline:
            state = self.resumed()
            if not state.startswith("not-front"):
                log(self.out, "launched", activity=self.activity(),
                    state=state[:200], pid=self.app_pid())
                return
            xml = self.dump()
            if "isn't responding" in xml or "is not responding" in xml:
                self.dismiss_anr(xml)
            time.sleep(6)
        log(self.out, "launch-slow", state=self.resumed()[:200],
            crash=self.logcat_crash()[:2000])
        raise SystemExit("the app did not come to the front")

    def shot(self, name: str, limit: float = 30.0) -> str:
        """A PNG of what the device is showing, as `screencap` gives it."""
        path = os.path.join(self.out, "shots", f"{name}.png")
        deadline = time.time() + limit
        while True:
            result = subprocess.run(
                [self.adb, "-s", self.serial, "exec-out", "screencap", "-p"],
                env=self.env, capture_output=True, timeout=300,
            )
            if result.returncode == 0 and len(result.stdout) > 4096:
                with open(path, "wb") as handle:
                    handle.write(result.stdout)
                log(self.out, "screenshot", name=name, bytes=len(result.stdout))
                return path
            if time.time() > deadline:
                log(self.out, "screenshot-failed", name=name)
                return ""
            time.sleep(1)

    def dismiss_anr(self, xml: str) -> str:
        """Answer the system's "isn't responding" dialog and read the tree again.

        Under TCG software emulation the launcher can be slow enough for
        Android to offer its ANR dialog over the app.  "Wait" is what a person
        presses; it leaves the app where it was.
        """
        if "isn't responding" not in xml and "is not responding" not in xml:
            return xml
        for text in ("Wait", "Close app", "OK"):
            found = self.named(xml, text)
            if found:
                x, y = found[0]["centre"]
                self.shell(f"input tap {x} {y}")
                log(self.out, "tap", key=text, name="anr dialog")
                time.sleep(3)
                return self.dump("window-after-anr")
        return xml

    def focused(self) -> str:
        """What the window manager says has the focus."""
        return self.shell(
            "dumpsys window | grep -m1 mCurrentFocus").strip()

    def settled(self, seconds: float = 90) -> bool:
        """Wait until the app has a focused window that can take input.

        Flutter on this host can be drawing its first frames for a minute, and
        an input event that arrives while no window has focus is dispatched to
        nothing, which the system charges to the app as an ANR.  Waiting for a
        focused window is what makes a tap land on a control.
        """
        deadline = time.time() + seconds
        while time.time() < deadline:
            if not self.resumed().startswith("not-front"):
                return True
            time.sleep(2)
        log(self.out, "not-settled", state=self.resumed()[:200])
        return False

    def keep_awake(self) -> None:
        """Wake the display and unlock it if it slept.

        A guest whose screen is off renders black: every screenshot is
        a black rectangle and every tap lands on the keyguard, which
        looks exactly like an app that ignores its controls.
        """
        power = self.shell("dumpsys power | grep -m1 mWakefulness")
        if "Awake" in power:
            return
        log(self.out, "display-asleep", power=power.strip()[:120])
        self.shell("input keyevent KEYCODE_WAKEUP")
        time.sleep(2)
        self.shell("wm dismiss-keyguard")
        time.sleep(2)

    def resumed(self) -> str:
        """Whether the app is the resumed activity *and* holds the focus.

        Two different things, and input needs both: the activity has
        to be resumed (its window added and its transition finished)
        and the window manager has to have given that window the
        focus.  Input that arrives with only one of the two waits,
        and the system charges the wait to the app as an ANR
        ("Application does not have a focused window").
        """
        top = self.shell(
            "dumpsys activity activities | grep -m1 topResumedActivity",
            timeout=120).strip()
        focus = self.shell(
            "dumpsys window | grep -m1 mCurrentFocus", timeout=120).strip()
        state = f"{top}\n{focus}"
        if PACKAGE in top and PACKAGE in focus:
            return state
        # Not both yet: say what is there, for the log.
        return "not-front\n" + state

    def ensure_front(self, attempts: int = 2) -> bool:
        """Bring the app back to the front if something took the focus.

        The app leaves the foreground on its own under this host's load:
        the system's ANR handling, the lock screen or the launcher can
        take the focus between two adb commands, and every tap then
        lands somewhere else.  It is started again only when it is
        not the resumed activity, and the wait is for the system's
        own report rather than for a focus string: a second start
        during a pending transition wedges the window manager, and
        the input that follows is charged to the app as an ANR.
        """
        for attempt in range(attempts):
            state = self.resumed()
            if not state.startswith("not-front"):
                return True
            self.dismiss_anr(self.dump())
            log(self.out, "front-lost", attempt=attempt + 1,
                state=state[:200])
            self.shell(f"am start -n {self.activity()}")
            deadline = time.time() + 90
            while time.time() < deadline:
                if not self.resumed().startswith("not-front"):
                    return True
                time.sleep(4)
        state = self.resumed()
        log(self.out, "front", state=state[:200])
        return not state.startswith("not-front")

    def dump(self, name: str = "window") -> str:
        """The accessibility tree: what the screen offers, as text.

        The APK is built with `--dart-define=E2E=true`, which turns Flutter's
        semantics tree on, so the app's labels and buttons are in the tree and
        a tap can be aimed at what a control says rather than a guessed pixel.
        `uiautomator dump` with no file writes the tree to stdout: one guest
        process instead of one to write a file and another to read it back,
        which matters because every process start on a guest without hardware
        acceleration is slow and this driver dumps constantly.
        """
        if not self.online():
            log(self.out, "device-gone", name=name)
            return ""
        for _ in range(4):
            text = self.shell("uiautomator dump /dev/tty")
            if "<hierarchy" not in text:
                # Some builds refuse the stdout sink; the file is then
                # the only way to read the tree.  The file is removed
                # before the dump: a dump that fails leaves the previous
                # screen's tree behind, and reading it back reports a
                # screen the device left minutes ago.
                remote = "/data/local/tmp/window.xml"
                self.shell("rm -f " + remote)
                self.shell("uiautomator dump " + remote)
                text = self.shell("cat " + remote)
            if "<hierarchy" in text:
                with open(os.path.join(self.out, f"{name}.xml"), "w") as handle:
                    handle.write(text)
                if "isn't responding" in text and not name.startswith("window-after"):
                    return self.dismiss_anr(text)
                return text
            log(self.out, "dump-failed", name=name,
                detail=text.strip()[-160:])
            time.sleep(1)
        return ""

    @staticmethod
    def nodes(xml: str) -> list[dict]:
        found = []
        for node in re.findall(r"<node[^>]*>", xml):
            def attribute(name: str) -> str:
                match = re.search(r'%s="([^"]*)"' % name, node)
                return match.group(1) if match else ""

            bounds = re.search(r'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', node)
            if not bounds:
                continue
            x1, y1, x2, y2 = map(int, bounds.groups())
            found.append(
                {
                    "raw": node,
                    "text": attribute("text"),
                    "desc": attribute("content-desc"),
                    "cls": attribute("class"),
                    "bounds": (x1, y1, x2, y2),
                    "centre": ((x1 + x2) // 2, (y1 + y2) // 2),
                }
            )
        return found

    def named(self, xml: str, key: str) -> list[dict]:
        """Nodes whose text or content-desc names KEY."""
        return [
            node
            for node in self.nodes(xml)
            if key == node["text"] or key == node["desc"] or key in node["desc"]
        ]

    def wait_for(self, key: str, name: str = "", seconds: float = 90) -> str:
        deadline = time.time() + seconds
        while time.time() < deadline:
            xml = self.dump()
            if key in xml:
                log(self.out, "found", key=key, name=name)
                return xml
            # A dump is a guest process and a full accessibility traversal:
            # polling it every couple of seconds starves the very frame the
            # wait is for.
            time.sleep(25)
        log(self.out, "not-found", key=key, name=name)
        return ""

    def tap(self, key: str, name: str = "", pause: float = 3.0,
            seconds: float = 90, expect: str = "",
            point: tuple[int, int] | None = None):
        """Tap the centre of the first node that names KEY.

        With POINT, a tree that does not name KEY falls back to that
        point: the voice screen's media bar does not always reach the
        accessibility tree on this guest, and the screenshots that
        follow every tap are what shows what it did.  Each attempt is
        one dump, because a dump is a guest process and the driver
        makes hundreds of them.
        """
        deadline = time.time() + seconds
        attempts = 0
        missed = 0
        self.keep_awake()
        self.settled()
        while time.time() < deadline:
            xml = self.dump()
            if expect and expect in xml:
                log(self.out, "tap-settled", key=key, name=name,
                    expect=expect)
                return True
            found = self.named(xml, key)
            if not found and point is not None and missed >= 2:
                x, y = point
                self.shell(f"input tap {x} {y}")
                attempts += 1
                log(self.out, "tap-point", key=key, name=name,
                    at=[x, y], attempt=attempts)
                time.sleep(pause)
                if not expect:
                    return True
                missed = 0
                continue
            if not found:
                missed += 1
                time.sleep(6)
                continue
            x, y = found[0]["centre"]
            self.shell(f"input tap {x} {y}")
            attempts += 1
            log(self.out, "tap", key=key, name=name, at=[x, y],
                attempt=attempts)
            time.sleep(pause)
            if not expect:
                return True
        log(self.out, "tap-missing", key=key, name=name, expect=expect,
            attempts=attempts)
        return False

    def advance(self, key: str, expect: str, name: str = "",
                seconds: float = 900, tries: int = 3) -> bool:
        """Tap KEY and wait for EXPECT, re-tapping only if KEY is still there.

        A route-changing tap cannot be repeated blindly: once the new
        screen is up, a second tap at the same point lands on whatever
        the new screen put there.  So a re-tap happens only when the
        tree still names the control that was tapped -- the screen
        that tap should have left -- and never while the new screen
        is on its way.
        """
        self.keep_awake()
        self.settled()
        deadline = time.time() + seconds
        attempts = 0
        while time.time() < deadline:
            if not self.app_alive():
                log(self.out, "app-died", during=f"advance to {expect}",
                    crash=self.logcat_crash()[-600:])
                self.shot("died-" + slug(expect))
                return False
            xml = self.dump()
            if expect in xml:
                log(self.out, "advanced", key=key, name=name,
                    expect=expect, attempts=attempts)
                return True
            found = self.named(xml, key)
            if not found or attempts >= tries:
                # Either the tap is on its way or the control is
                # gone: wait, do not tap again.
                time.sleep(15)
                continue
            x, y = found[0]["centre"]
            self.shell(f"input tap {x} {y}")
            attempts += 1
            log(self.out, "tap", key=key, name=name, at=[x, y],
                attempt=attempts)
            time.sleep(20)
        log(self.out, "advance-missing", key=key, name=name,
            expect=expect, attempts=attempts,
            screen=self.screen_text()[:600])
        return False

    def tap_point(self, x: int, y: int, name: str = "", pause: float = 3.0):
        self.shell(f"input tap {x} {y}")
        log(self.out, "tap", name=name, at=[x, y])
        time.sleep(pause)

    def type_text(self, text: str) -> None:
        self.shell("input text '%s'" % text.replace(" ", "%s"))

    # -- permissions and the platform ---------------------------------------

    def grant(self, permission: str) -> None:
        self.shell(f"pm grant {PACKAGE} {permission}")
        log(self.out, "granted", permission=permission)

    def revoke(self, permission: str) -> None:
        self.shell(f"pm revoke {PACKAGE} {permission}")
        log(self.out, "revoked", permission=permission)

    def permission_state(self, permission: str) -> str:
        text = self.shell(f"dumpsys package {PACKAGE} | grep -A2 '{permission}'")
        return "granted" if "granted=true" in text else "not granted"

    def foreground_services(self) -> list[dict]:
        """The app's running services, as the system reports them."""
        text = self.shell(f"dumpsys activity services {PACKAGE}")
        services = []
        for block in text.split("ServiceRecord"):
            if "ScreenShareService" not in block:
                continue
            found = re.search(r"foregroundServiceType=([^\s\]]+)", block)
            services.append(
                {
                    "raw": re.sub(r"\s+", " ", block.strip())[:400],
                    "foreground": "isForeground=true" in block,
                    "type": found.group(1) if found else "",
                }
            )
        return services

    def notifications(self) -> list[str]:
        text = self.shell(f"dumpsys notification --noredact | grep -A3 '{PACKAGE}'")
        return [line.strip() for line in text.splitlines() if line.strip()][:20]

    def camera_clients(self) -> list[str]:
        text = self.shell("dumpsys media.camera | grep -i 'client\\|active'")
        return [line.strip() for line in text.splitlines() if line.strip()][:12]

    def app_pid(self) -> str:
        return self.shell(f"pidof {PACKAGE}").strip()

    def app_alive(self) -> bool:
        """Whether the app's own process is still there.

        A wait whose app has died must not spend its whole
        timeout on a screen that cannot appear: the reason is
        in the device log, and the caller records it and goes
        on.  The launcher that replaces the app keeps the
        accessibility tree non-empty, so a dump cannot tell.
        """
        return bool(self.app_pid())

    def clock_offset(self) -> dict:
        """The device clock against this host's, from two readings.

        A latency is `receiver arrival - capturedAt`, and the two clocks are
        not the same clock.  The device's `date` and the host's are read as
        close together as adb allows, twice; the smaller difference bounds the
        offset better than one reading does.
        """
        readings = []
        for _ in range(2):
            before = time.time()
            device = self.shell("date +%s.%N").strip()
            after = time.time()
            try:
                readings.append(float(device) - (before + after) / 2)
            except ValueError:
                pass
            time.sleep(0.4)
        if not readings:
            return {"seconds": 0.0, "readings": []}
        return {
            "seconds": round(min(readings, key=abs), 3),
            "readings": [round(value, 3) for value in readings],
        }

    # -- the local peers -----------------------------------------------------

    def listening(self, port: int, path: str = "/health") -> bool:
        probe = self.sh(["curl", "-sf", f"http://127.0.0.1:{port}{path}"], timeout=20)
        return probe.returncode == 0

    def start_receiver(self, port: int, mode: str) -> None:
        if self.listening(port):
            log(self.out, "receiver-already-listening", port=port, mode=mode)
            return
        handle = open(os.path.join(self.out, f"receiver-{mode}.out"), "a")
        subprocess.Popen(
            [self.python, os.path.join(HERE, "media_receiver.py"),
             "--port", str(port), "--out", self.out, "--mode", mode],
            stdout=handle, stderr=subprocess.STDOUT, start_new_session=True,
        )
        for _ in range(60):
            if self.listening(port):
                log(self.out, "receiver-started", port=port, mode=mode)
                return
            time.sleep(0.5)
        raise SystemExit(f"the {mode} receiver did not start")

    def start_mock(self) -> None:
        if self.listening(self.mock_port, "/"):
            log(self.out, "mock-already-listening", port=self.mock_port)
            return
        trace = os.path.join(self.out, "acp-trace.jsonl")
        handle = open(os.path.join(self.out, "mock.out"), "a")
        command = [self.dart, "run", "tool/mock_harness_server.dart",
                   "--port", str(self.mock_port), "--task-sessions", "--trace", trace]
        subprocess.Popen(
            command, cwd=CLIENT, env=dict(os.environ, PUB_CACHE=os.environ.get("PUB_CACHE", "")),
            stdout=handle, stderr=subprocess.STDOUT, start_new_session=True,
        )
        # `dart run` compiles before it listens, so this waits longer than the
        # Python receiver does.
        for _ in range(240):
            if self.listening(self.mock_port, "/"):
                log(self.out, "mock-started", port=self.mock_port, trace=trace)
                return
            time.sleep(1)
        raise SystemExit("the mock harness did not start")

    def receiver_summary(self, port: int) -> dict:
        probe = self.sh(["curl", "-sf", f"http://127.0.0.1:{port}/health"], timeout=30)
        if probe.returncode != 0 or not probe.stdout.strip():
            return {}
        return json.loads(probe.stdout)

    # -- what the app sent ---------------------------------------------------

    def trace(self) -> list[dict]:
        """Every ACP request the app made, as the mock harness traced it."""
        path = os.path.join(self.out, "acp-trace.jsonl")
        if not os.path.exists(path):
            return []
        records = []
        with open(path) as handle:
            for line in handle:
                line = line.strip()
                if line:
                    try:
                        records.append(json.loads(line))
                    except ValueError:
                        pass
        return records

    def frames_to_chat(self) -> list[dict]:
        """The prompt blocks that carried an image, newest last."""
        found = []
        for record in self.trace():
            if record.get("method") != "session/prompt":
                continue
            blocks = (record.get("params") or {}).get("prompt") or []
            for block in blocks:
                if not isinstance(block, dict) or block.get("type") != "content":
                    continue
                content = block.get("content") or {}
                if content.get("type") != "image":
                    continue
                found.append(
                    {
                        "at": record.get("at"),
                        "mime": content.get("mimeType"),
                        "bytes": content.get("dataBytes"),
                        "sha256": content.get("dataSha256"),
                        "label": (content.get("_harness") or {}).get("label"),
                        "text": next(
                            (
                                (other.get("content") or {}).get("text")
                                for other in blocks
                                if isinstance(other, dict)
                                and other.get("type") == "content"
                                and (other.get("content") or {}).get("type") == "text"
                            ),
                            None,
                        ),
                    }
                )
        return found

    # -- driving the real UI -------------------------------------------------

    def field_below(self, label: str, index: int = 0) -> dict | None:
        """The first editable field below the text LABEL, by its own bounds."""
        xml = self.dump()
        labels = [
            node for node in self.nodes(xml)
            if label in (node["text"], node["desc"])
        ]
        if not labels:
            log(self.out, "field-label-missing", label=label)
            return None
        bottom = labels[0]["bounds"][3]
        editable = [
            node for node in self.nodes(xml)
            if "EditText" in node["cls"] and node["bounds"][1] >= bottom
        ]
        editable.sort(key=lambda node: node["bounds"][1])
        if len(editable) <= index:
            log(self.out, "field-missing", label=label, found=len(editable))
            return None
        return editable[index]

    def set_field(self, label: str, value: str, index: int = 0) -> None:
        """Replace the text of the field under LABEL with VALUE.

        The field is focused with a tap, cleared, and typed into.
        The tree is *not* asked what the field holds: Flutter's text
        fields report an empty string to the accessibility dump on this
        guest, so a clear sized from it deletes nothing and every
        attempt appends another copy of the value.  The clear is
        therefore a fixed, generous run of DEL after MOVE_END, which
        is one `input` process however many keys it carries.
        """
        if not self.ensure_front():
            log(self.out, "field-front-missing", label=label)
            return
        field = self.field_below(label, index)
        if field is None:
            log(self.out, "field-missing", label=label)
            return
        x, y = field["centre"]
        # The keyboard opens with an animation the guest renders
        # slowly; typing before it has settled goes to the
        # previous screen.
        self.shell(f"input tap {x} {y}")
        time.sleep(8)
        self.shell("input keyevent KEYCODE_MOVE_END", timeout=180)
        self.shell("input keyevent " + " ".join(["KEYCODE_DEL"] * 64),
                   timeout=300)
        self.type_text(value)
        time.sleep(4)
        after = self.field_below(label, index) or {}
        log(self.out, "field", label=label, now=value,
            read_back=(after.get("text") or "")[:120])
        # The keyboard covers the lower half of the screen; dismissing
        # it puts the form back the way a person sees it before the
        # next control.  BACK is only sent while the keyboard is
        # actually shown: on a screen without one it leaves the app.
        if "mInputShown=true" in self.shell(
                "dumpsys input_method | grep -m1 mInputShown"):
            self.shell("input keyevent KEYCODE_BACK")
            time.sleep(3)

    def dismiss_resume_card(self) -> bool:
        """A device that remembers its harness opens on the resume card."""
        xml = self.dump()
        if "Use another address" not in xml and "resume-change" not in xml:
            return False
        self.tap("Use another address", "the resume card's change control", pause=2)
        return True

    def connect(self, address: str) -> None:
        """Type the address into the real connect screen and press Connect."""
        if not self.wait_for("SERVER ADDRESS", "the connect screen", seconds=300):
            if not self.dismiss_resume_card():
                self.shot("01-connect-missing")
                raise SystemExit("the app did not show the connect screen")
            if not self.wait_for("SERVER ADDRESS", "the connect form", seconds=120):
                raise SystemExit("the connect form did not appear")
        self.set_field("SERVER ADDRESS", address)
        self.shot("01-connect")
        # Connect is a route change: the tap is repeated only while the
        # form is still the screen, so it can never land on the list.
        if not self.advance("Connect", "Sessions", "Connect"):
            self.shot("01-connect-failed")
            raise SystemExit("the app did not reach its session list")
        self.shot("02-sessions")

    def screen_text(self) -> str:
        """Every label the screen offers, one a line: what it says, as text."""
        lines = []
        for node in self.nodes(self.dump()):
            for value in (node["desc"], node["text"]):
                if value and value not in lines:
                    lines.append(value)
        return "\n".join(lines)

    def open_a_session(self) -> None:
        """Open a conversation from the list, as a person does."""
        if not self.advance("Design the merge queue", "Voice mode",
                            "a conversation"):
            self.shot("02-session-missing")
            raise SystemExit("the sessions list named no conversation to open")
        self.shot("03-conversation")

    def open_voice(self) -> None:
        """Open voice mode from the conversation's composer."""
        # The voice screen builds an audio pipeline before it draws, and
        # on this guest that takes minutes; the wait is for the app.  The
        # tap itself is by the composer's own control, and the wait is for
        # the voice screen's header, which the tree does carry.
        # The screen's own content, not its settings gear: the gear's
        # tooltip is not in this guest's tree, and waiting for it cost
        # half an hour a run before it was noticed.
        if not self.advance("Voice mode", "Pipeline", "Voice mode",
                            seconds=900):
            # A call that failed is still the voice screen, and the
            # settings its gear opens are still there: the run
            # continues from it rather than throwing the boot away.
            xml = self.dump()
            if "Camera" not in xml and "Voice" not in xml:
                self.shot("04-voice-failed")
                raise SystemExit("voice mode did not open")
            log(self.out, "voice-screen-without-settings",
                status=self.media_status(xml))
        self.shot("04-voice")

    # Where the voice screen draws its media bar and call controls, in
    # the 540 x 1170 the driver sets.  The bar's buttons are drawn by
    # a painter of their own and are not in the accessibility tree of
    # this guest, so a run aims at the layout the screenshots show.
    MEDIA_BAR = {
        "camera": (107, 886),
        "screen": (248, 886),
        "frame": (409, 886),
        "mute": (91, 1054),
        "pause": (181, 1054),
        "interrupt": (270, 1054),
        "end": (357, 1054),
        "retry": (444, 1054),
        "provider": (474, 72),
    }

    def tap_bar(self, control: str, name: str = "",
                pause: float = 6.0) -> None:
        """Tap a media-bar or call control by the layout, then look."""
        x, y = self.MEDIA_BAR[control]
        self.keep_awake()
        self.shell(f"input tap {x} {y}")
        log(self.out, "tap-bar", control=control, name=name,
            at=[x, y])
        time.sleep(pause)
        self.shot("bar-" + (slug(name) or control))

    def tap_media(self, x: int, y: int, name: str) -> None:
        """Tap a media control by where the app draws it.

        The voice screen's media bar is drawn by a painter of its own
        and its buttons do not always reach the accessibility tree on
        this guest: a dump of that screen can come back empty while the
        screenshot shows it.  The point is read from the app's own
        layout -- the bar sits above the call controls, a third of
        the width each -- and every tap is followed by a screenshot,
        so what it did is on record.
        """
        self.keep_awake()
        self.shell(f"input tap {x} {y}")
        log(self.out, "tap", key=name, name="media bar", at=[x, y])
        time.sleep(8)
        self.shot("media-" + slug(name))

    def media_status(self, xml: str = "") -> str:
        """The media bar's status line, as the widget shows it."""
        if not xml:
            self.keep_awake()
        xml = xml or self.dump()
        for node in self.nodes(xml):
            if node["desc"].startswith(("Camera ", "Screen ")) and (
                "live" in node["desc"]
                or "off" in node["desc"]
                or "frames" in node["desc"]
                or "preview" in node["desc"]
                or "paused" in node["desc"]
                or "suspended" in node["desc"]
                or "denied" in node["desc"]
                or "revoked" in node["desc"]
                or "unavailable" in node["desc"]
                or "failed" in node["desc"]
                or "starting" in node["desc"]
            ):
                return node["desc"]
        for node in self.nodes(xml):
            if node["text"].startswith(("Camera ", "Screen ")):
                return node["text"]
        return ""

    def await_status(self, name: str, seconds: float = 180, until=None) -> str:
        """Wait until the media status names a state UNTIL accepts."""
        accept = until or (
            lambda text: bool(text)
            and not re.search(r"off|starting|checking", text, re.IGNORECASE)
        )
        deadline = time.time() + seconds
        last = ""
        while time.time() < deadline:
            if not self.app_alive():
                log(self.out, "app-died", during=f"status {name}",
                    crash=self.logcat_crash()[-600:])
                self.shot("died-" + slug(name))
                return "app died"
            text = self.media_status()
            if text and text != last:
                log(self.out, "media-status", name=name, status=text)
                last = text
            if accept(text):
                self.shot(f"{name}-{slug(text)}")
                return text
            # A dump is a guest process and a full accessibility
            # traversal, and this guest is emulated in software.  A
            # wait that dumps every few seconds starves the app's own
            # network stack, and a live call then drops with ICE
            # consent failures -- a driver that breaks what it measures.
            time.sleep(15)
        log(self.out, "media-status-timeout", name=name, status=last)
        self.shot(f"{name}-timeout")
        return last

    def await_status_is(self, wanted: str, name: str, seconds: float = 120) -> str:
        """Wait for the bar to say WANTED, or for the receiver to have frames.

        This guest cannot answer an accessibility dump while a video
        track is live, so a state the bar would show is not always
        readable.  The wait ends early, and says so, when the receiver
        has already seen the thing the state is about: the frames are
        the evidence, the label is the app's own claim.
        """
        source = "screen" if "Screen" in wanted else "camera"
        before = self._frames(self.receiver_summary(self.track_port),
                              source)
        deadline = time.time() + seconds
        while time.time() < deadline:
            text = self.media_status()
            if text == wanted:
                self.shot(f"{name}-{slug(text)}")
                return text
            live = wanted.endswith(" live")
            now = self._frames(self.receiver_summary(self.track_port),
                               source)
            if live and now > before:
                log(self.out, "status-from-receiver", wanted=wanted,
                    source=source, frames=now, name=name)
                self.shot(f"{name}-from-receiver")
                return f"{wanted} (unread; {now} frames arrived)"
            time.sleep(12)
        log(self.out, "media-status-timeout", name=name, status="")
        self.shot(f"{name}-timeout")
        return ""

    def set_live_voice(self, endpoint: str, model: str) -> None:
        """Point the voice screen at a live endpoint, through its own sheet."""
        if not self.wait_for("Pipeline", "the voice screen", seconds=600):
            raise SystemExit("no voice screen to configure")
        # The header's provider chip opens the same sheet as its gear.
        if not self.advance("Pipeline", "Provider", "Voice settings"):
            # The header's provider chip is a coordinate the run knows
            # from the screen it just took; a failed call's tree is
            # often too big for the guest to answer, and the chip is
            # still drawn in the same place.
            self.tap_media(475, 105, "the provider chip")
            if not self.wait_for("Provider", "Voice settings", seconds=240):
                self.shot("05-settings-failed")
                raise SystemExit("the voice settings sheet did not open")
        if not self.advance("Live", "Realtime endpoint", "the Live provider"):
            self.shot("05-live-fields-failed")
            raise SystemExit("the Live fields did not appear")
        self.shot("05-settings-live")
        self.set_field("Realtime endpoint", endpoint)
        self.set_field("Realtime model", model)
        self.shot("06-settings-filled")
        if not self.advance("Save", "Camera", "Save the voice settings"):
            self.shot("07-save-failed")
            raise SystemExit("the settings sheet did not close")
        self.shot("07-voice-live")

    def await_offer(self, port: int, after: int, seconds: float = 180) -> dict:
        """Wait for the receiver to log a new offer, and return that offer."""
        deadline = time.time() + seconds
        while time.time() < deadline:
            if not self.app_alive():
                log(self.out, "app-died", during="offer",
                    crash=self.logcat_crash()[-600:])
                return {}
            summary = self.receiver_summary(port)
            offers = summary.get("offers") or []
            if len(offers) > after:
                log(
                    self.out,
                    "offer",
                    port=port,
                    video_mlines=offers[-1].get("video_mlines"),
                    audio_mlines=offers[-1].get("audio_mlines"),
                    model=offers[-1].get("model"),
                )
                return offers[-1]
            time.sleep(3)
        log(self.out, "offer-missing", port=port)
        return {}

    def wait_for_track(self, port: int, before: dict, source: str, seconds: float = 120) -> dict:
        """Wait for the receiver to count frames on SOURCE, and say how many."""
        was = (before.get("tracks") or {}).get(source) or {}
        was_frames = was.get("frames", 0)
        deadline = time.time() + seconds
        while time.time() < deadline:
            if not self.app_alive():
                log(self.out, "app-died", during=f"track {source}",
                    crash=self.logcat_crash()[-600:])
                return {}
            now = self.receiver_summary(port)
            entry = (now.get("tracks") or {}).get(source) or {}
            if entry.get("frames", 0) > was_frames:
                log(
                    self.out,
                    "track-frames",
                    source=source,
                    frames=entry.get("frames"),
                    size=[entry.get("width"), entry.get("height")],
                    first_at=entry.get("first_at"),
                    last_at=entry.get("last_at"),
                )
                return entry
            time.sleep(3)
        log(self.out, "track-missing", source=source)
        return {}

    @staticmethod
    def _frames(summary: dict, source: str) -> int:
        """How many frames the receiver counted for SOURCE so far."""
        entry = (summary.get("tracks") or {}).get(source) or {}
        return int(entry.get("frames") or 0)

    @staticmethod
    def track_delta(entry: dict) -> dict:
        return {
            key: entry.get(key)
            for key in ("frames", "width", "height", "first_at", "last_at",
                        "first_pts", "last_pts", "max_gap_ms", "gaps")
        }

    # -- scenarios -----------------------------------------------------------

    def scenario_camera(self) -> dict:
        """Camera: refusal, start, track delivery, pause, still, lifecycle, stop."""
        report: dict = {"source": "camera", "port": self.track_port}
        before = self.receiver_summary(self.track_port)
        report["status_off"] = self.media_status()
        self.shot("10-camera-off")

        # 1. The system's own permission dialog, refused by a tap.
        report["camera_permission_before"] = self.permission_state(CAMERA)
        self.revoke(CAMERA)
        self.tap_bar("camera", "Camera with the permission off")
        denied = self.accept_permission_dialog(allow=False)
        report["permission_dialog"] = denied
        report["status_refused"] = self.await_status_is(
            "Camera permission denied", "11-camera-refused", seconds=90
        )
        self.shot("11-camera-refused")
        report["permission_after_refusal"] = self.permission_state(CAMERA)
        report["offers_after_refusal"] = len(
            (self.receiver_summary(self.track_port).get("offers") or [])
        )

        # 2. Granted, started by a press, and carried on a real track.
        self.grant(CAMERA)
        report["camera_permission_granted"] = self.permission_state(CAMERA)
        self.tap_bar("camera", "Camera")
        allowed = self.accept_permission_dialog(allow=True)
        report["permission_dialog_granted"] = allowed
        report["status_live"] = self.await_status_is(
            "Camera live", "12-camera-live", seconds=180
        )
        report["camera_clients"] = self.camera_clients()
        report["track"] = self.wait_for_track(self.track_port, before, "camera")
        report["status_live_again"] = self.media_status()
        self.shot("12-camera-live")

        # 3. Pause: the app says paused and the sender stops producing frames.
        paused_before = self.receiver_summary(self.track_port)
        self.tap_bar("pause", "conversation pause")
        report["status_paused"] = self.await_status_is(
            "Camera paused", "13-camera-paused", seconds=90
        )
        time.sleep(6)
        paused_after = self.receiver_summary(self.track_port)
        report["frames_while_paused"] = self._frames(
            paused_after, "camera") - self._frames(paused_before, "camera")
        self.shot("13-camera-paused")

        # 4. Resume: frames flow again.
        self.tap_bar("pause", "conversation resume")
        report["status_resumed"] = self.await_status_is(
            "Camera live", "14-camera-resumed", seconds=120
        )
        report["track_after_resume"] = self.wait_for_track(
            self.track_port, paused_after, "camera", seconds=60
        )
        self.shot("14-camera-resumed")

        # 5. One press sends one still to the conversation, as an ACP image.
        if self.tap_bar("frame", "Frame to chat"):
            blocks = self.frames_to_chat()
            report["frames_to_chat"] = blocks[-2:]
            if blocks and blocks[-1].get("sha256"):
                report["chat_frame"] = blocks[-1]
            self.shot("15-frame-to-chat")

        # 6. The app goes to the background: the capture stops, and does not
        #    come back by itself.
        report["services_before_background"] = self.foreground_services()
        self.shell("input keyevent KEYCODE_HOME")
        time.sleep(6)
        report["status_background"] = self.media_status()
        self.shot("16-camera-background")
        self.shell(f"am start -n {self.activity()}")
        time.sleep(10)
        report["status_after_return"] = self.media_status()
        self.shot("17-camera-returned")
        report["track_after_background"] = self.track_delta(
            (self.receiver_summary(self.track_port).get("tracks") or {}).get("camera", {})
        )

        # 7. One step off, and the camera is released.
        self.tap_bar("camera", "Camera off")
        report["status_stopped"] = self.await_status_is(
            "Camera off", "18-camera-stopped", seconds=90
        )
        report["camera_clients_after_stop"] = self.camera_clients()
        report["after"] = self.track_delta(
            (self.receiver_summary(self.track_port).get("tracks") or {})
            .get("camera", {}))
        self.shot("18-camera-stopped")
        self.record("camera", report)
        return report

    def scenario_capture(self, source: str) -> dict:
        """One capture source, driven by the layout, measured at the receiver.

        The accessibility tree of this guest cannot carry the voice
        screen's media bar, and polling it starves the app's own network
        stack until a live call drops.  So the controls are tapped where
        the screenshots show them, and what happened is read from the
        receiver, which is the only place a delivered frame exists.
        """
        port = self.track_port
        report: dict = {"source": source, "port": port}
        self.shot(f"50-{source}-before")
        before = self.receiver_summary(port)
        report["offers_before"] = len(before.get("offers") or [])

        # The permission the source needs, granted up front: the run is
        # about the capture path, not the dialog, and a dialog on a guest
        # this slow costs minutes.
        if source == "camera":
            self.grant(CAMERA)
        if source == "camera":
            report["permission"] = self.permission_state(CAMERA)

        self.tap_bar(source, source)
        if source == "screen":
            report["consent"] = self.accept_media_projection(accept=True)
            report["services"] = self.foreground_services()
        report["track"] = self.wait_for_track(port, before, source,
                                                seconds=240)
        report["camera_clients"] = self.camera_clients()
        self.shot(f"51-{source}-live")

        # Let it run, then read what arrived: a live track that is
        # attached and never decoded is not a delivered picture.
        time.sleep(20)
        live = self.receiver_summary(port)
        entry = (live.get("tracks") or {}).get(source) or {}
        report["live"] = self.track_delta(entry)
        report["last_png"] = entry.get("last_png")
        report["first_png"] = entry.get("first_png")
        report["size"] = [entry.get("width"), entry.get("height")]
        self.shot(f"52-{source}-running")

        # One step off: the same control, and the sender stops.
        self.tap_bar(source, source + " off")
        time.sleep(8)
        stopped = self.receiver_summary(port)
        report["after_stop"] = self.track_delta(
            (stopped.get("tracks") or {}).get(source) or {})
        report["services_after_stop"] = self.foreground_services()
        report["camera_clients_after_stop"] = self.camera_clients()
        self.shot(f"53-{source}-stopped")
        self.record(f"capture-{source}", report)
        return report

    def scenario_screen(self) -> dict:
        """Phone screen: MediaProjection consent, foreground service, delivery."""
        report: dict = {"source": "screen", "port": self.track_port}
        before = self.receiver_summary(self.track_port)
        self.shot("20-screen-off")

        # 1. Refusal at the system's own consent dialog.
        self.tap_bar("screen", "Screen")
        report["consent_refused"] = self.accept_media_projection(accept=False)
        report["status_after_refusal"] = self.await_status_is(
            "Screen permission denied", "21-screen-refused", seconds=90
        )
        self.shot("21-screen-refused")
        report["services_after_refusal"] = self.foreground_services()

        # 2. Consent given: the foreground service and the projection.
        self.tap_bar("screen", "Screen")
        report["consent_accepted"] = self.accept_media_projection(accept=True)
        report["services"] = self.foreground_services()
        report["notifications"] = self.notifications()
        report["status_live"] = self.await_status_is(
            "Screen live", "22-screen-live", seconds=240
        )
        self.shot("22-screen-live")
        report["track"] = self.wait_for_track(self.track_port, before, "screen")
        self.shell("cmd statusbar expand-notifications")
        time.sleep(3)
        report["notification_shot"] = self.shot("23-screen-notification")
        self.shell("cmd statusbar collapse")
        time.sleep(2)

        # 3. The received picture is the device's own screen: compare what the
        #    receiver decoded with what the device showed at nearly the same
        #    moment.
        report["content"] = self.compare_screen(self.track_port)

        # 4. One step off: the service and the projection both go.
        self.tap_bar("screen", "Screen off")
        report["status_stopped"] = self.await_status_is(
            "Screen off", "24-screen-stopped", seconds=120
        )
        report["services_after_stop"] = self.foreground_services()
        report["notifications_after_stop"] = self.notifications()
        report["after"] = self.track_delta(
            (self.receiver_summary(self.track_port).get("tracks") or {})
            .get("screen", {}))
        self.shot("24-screen-stopped")
        self.record("screen", report)
        return report

    def scenario_frames(self) -> dict:
        """A provider that takes stills, not tracks: sampled frames, measured."""
        report: dict = {"port": self.frame_port}
        before = self.receiver_summary(self.frame_port)
        self.set_live_voice(f"http://{self.host}:{self.frame_port}/voice", self.model)
        report["offer"] = self.await_offer(self.frame_port, len(before.get("offers") or []))
        report["status_off"] = self.media_status()
        self.tap_bar("camera", "Camera")
        report["status_frames"] = self.await_status_is(
            "Camera frames · 1/s", "30-camera-frames", seconds=180
        )
        report["camera_clients"] = self.camera_clients()
        # Let the sampling loop deliver a handful of stills.
        deadline = time.time() + 60
        while time.time() < deadline:
            if (self.receiver_summary(self.frame_port).get("frames") or 0) >= 3:
                break
            time.sleep(3)
        after = self.receiver_summary(self.frame_port)
        report["frames"] = after.get("frame_index") or []
        report["clock_offset"] = self.clock_offset()
        report["latency"] = self.frame_latency(report["frames"], report["clock_offset"])
        self.shot("30-camera-frames")
        self.tap_bar("camera", "Camera off")
        report["status_stopped"] = self.await_status_is(
            "Camera off", "31-camera-frames-stopped", seconds=90
        )
        self.shot("31-camera-frames-stopped")
        self.record("frames", report)
        return report

    def scenario_kill(self) -> dict:
        """Disconnect cleanup: the process dies, nothing keeps capturing."""
        report: dict = {}
        self.set_live_voice(f"http://{self.host}:{self.track_port}/voice", self.model)
        before = self.receiver_summary(self.track_port)
        self.tap_bar("camera", "Camera")
        report["status_live"] = self.await_status_is(
            "Camera live", "40-kill-live", seconds=180
        )
        report["track"] = self.wait_for_track(self.track_port, before, "camera")
        report["camera_clients"] = self.camera_clients()
        self.shell("am force-stop " + PACKAGE)
        time.sleep(6)
        report["pid_after_kill"] = self.app_pid()
        report["services_after_kill"] = self.foreground_services()
        report["camera_clients_after_kill"] = self.camera_clients()
        report["after"] = self.track_delta(
            (self.receiver_summary(self.track_port).get("tracks") or {})
            .get("camera", {}))
        self.shot("41-kill")
        self.record("kill", report)
        return report

    # -- the system's dialogs ------------------------------------------------

    def accept_permission_dialog(self, allow: bool, seconds: float = 45) -> bool:
        """Answer the runtime permission dialog, as a person does."""
        deadline = time.time() + seconds
        wanted = (
            ["While using the app", "Allow"]
            if allow
            else ["Don't allow", "Deny"]
        )
        while time.time() < deadline:
            xml = self.dump("permission")
            if "permission" not in xml.lower() and "allow" not in xml.lower():
                time.sleep(1)
                continue
            for text in wanted:
                found = self.named(xml, text)
                if found:
                    x, y = found[0]["centre"]
                    self.shell(f"input tap {x} {y}")
                    log(self.out, "tap", key=text, name="permission dialog")
                    time.sleep(4)
                    return True
            time.sleep(2)
        log(self.out, "permission-dialog-missing", allow=allow)
        return False

    def accept_media_projection(self, accept: bool, seconds: float = 60) -> bool:
        """Answer the system's MediaProjection consent, as a person does."""
        deadline = time.time() + seconds
        wanted = ["Start now", "Start recording", "Share"] if accept else ["Cancel"]
        while time.time() < deadline:
            xml = self.dump("projection")
            for text in wanted:
                found = self.named(xml, text)
                if found:
                    x, y = found[0]["centre"]
                    self.shell(f"input tap {x} {y}")
                    log(self.out, "tap", key=text, name="MediaProjection")
                    time.sleep(5)
                    return True
            time.sleep(2)
        log(self.out, "projection-dialog-missing", accept=accept)
        return False

    # -- comparing what arrived with what was on screen ----------------------

    def compare_screen(self, port: int) -> dict:
        """How much the received screen frame looks like the device's screen.

        The receiver saved the last decoded frame of the screen track; this
        takes a screenshot of the device at nearly the same moment and compares
        them as small greyscale images.  A recursive share -- the app showing
        itself -- is expected here and is what makes the comparison meaningful.
        """
        summary = self.receiver_summary(port)
        received = ((summary.get("tracks") or {}).get("screen") or {}).get("last_png")
        shot = self.shot("25-screen-compare")
        if not received or not shot or not os.path.exists(received):
            return {"compared": False, "received": received, "shot": shot}
        script = os.path.join(HERE, "compare_frames.py")
        if not os.path.exists(script):
            return {"compared": False, "reason": "no compare_frames.py"}
        result = self.sh([self.python, script, received, shot], timeout=120)
        try:
            return json.loads(result.stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            return {"compared": False, "output": result.stdout[-400:]}

    # -- measurements --------------------------------------------------------

    @staticmethod
    def frame_latency(frames: list[dict], offset: dict) -> dict:
        """capturedAt -> receiver arrival, for the stills that carry both."""
        import datetime

        def parse(text: str) -> float | None:
            if not text:
                return None
            try:
                return datetime.datetime.fromisoformat(
                    text.replace("Z", "+00:00")
                ).timestamp()
            except ValueError:
                return None

        seconds = offset.get("seconds") or 0.0
        measured = []
        for frame in frames:
            captured = parse(frame.get("captured_at") or "")
            arrived = parse(frame.get("at") or "")
            if captured is None or arrived is None:
                continue
            # The device's clock is `seconds` ahead of this host's.
            measured.append(round((arrived - (captured - seconds)) * 1000.0, 1))
        if not measured:
            return {"samples": 0}
        ordered = sorted(measured)
        return {
            "samples": len(ordered),
            "ms": measured,
            "min_ms": ordered[0],
            "median_ms": ordered[len(ordered) // 2],
            "max_ms": ordered[-1],
        }

    # -- record --------------------------------------------------------------

    def record(self, name: str, report: dict) -> None:
        with open(os.path.join(self.out, f"{name}.json"), "w") as handle:
            json.dump(report, handle, indent=2, sort_keys=True)
        log(self.out, f"{name}-report", **{
            key: value
            for key, value in report.items()
            if key not in ("track", "frames", "notifications", "services")
        })


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="/tmp/media-e2e")
    parser.add_argument("--sdk", default=os.environ.get("ANDROID_HOME"))
    parser.add_argument("--python", default=None)
    parser.add_argument("--dart", default=None)
    parser.add_argument("--flutter", default=None)
    parser.add_argument("--port", type=int, default=TRACK_PORT)
    parser.add_argument("--frame-port", type=int, default=FRAME_PORT)
    parser.add_argument("--serial", default=None)
    parser.add_argument("--phase", default="status")
    parser.add_argument("--acp-port", type=int, default=MOCK_PORT)
    parser.add_argument(
        "--host", default=None,
        help="this machine's address as the guest reaches it")
    parser.add_argument("--model", default="local-test-receiver")
    parser.add_argument("--only", default="", help="a comma separated subset of the scenarios")
    parser.add_argument(
        "--boot-timeout", type=float, default=1800,
        help="seconds a single emulator start may take before it is retried")
    parser.add_argument(
        "--no-build", action="store_true",
        help="use the APK already installed instead of building one")
    parser.add_argument(
        "--fresh", action="store_true",
        help="wipe the AVD's data image first: a clean guest, a fresh install")
    arguments = parser.parse_args()
    run = Run(arguments)
    log(run.out, "phase", name=arguments.phase)
    only = {name for name in arguments.only.split(",") if name}
    if arguments.phase == "status":
        print(run.sh([run.adb, "devices"], check=True).stdout)
        if run.online():
            print("camera:", run.permission_state(CAMERA))
            print("pid:", run.app_pid())
            print("services:", json.dumps(run.foreground_services()))
            print("status:", run.media_status())
        return 0
    if arguments.phase == "install":
        # Boot, install the APK this run would drive and save the guest, so a
        # later run resumes in seconds instead of paying a cold boot again.
        run.prepare()
        if not arguments.no_build:
            run.build_apk()
        run.install()
        run.save_snapshot(force=True)
        return 0
    if arguments.phase == "smoke":
        # Boot, install and reach the voice screen, then stop: what the
        # driving below needs, checked without spending a whole run on it.
        run.prepare()
        run.start_mock()
        run.start_receiver(run.track_port, "tracks")
        run.start_receiver(run.frame_port, "frames")
        run.build_apk()
        run.install()
        run.clear_app()
        run.grant(RECORD_AUDIO)
        run.launch()
        run.open_a_session()
        run.open_voice()
        run.await_offer(run.track_port, 0)
        log(run.out, "smoke-status", status=run.media_status())
        run.shot("90-smoke")
        return 0

    if arguments.phase == "capture":
        # One source, by the layout, measured at the receiver: the
        # short run that answers whether a phone's camera and screen
        # reach a peer at all, without the tree the guest cannot
        # answer while a track is live.
        run.prepare()
        run.start_mock()
        run.start_receiver(run.track_port, "tracks")
        run.start_receiver(run.frame_port, "frames")
        if not arguments.no_build:
            run.build_apk()
            run.install()
        run.clear_app()
        run.grant(RECORD_AUDIO)
        run.launch()
        run.open_a_session()
        run.open_voice()
        run.await_offer(run.track_port, 0)
        report = {}
        for source in (arguments.only or "camera").split(","):
            report[source] = run.scenario_capture(source)
        run.record("capture", report)
        return 0

    if arguments.phase != "all":
        raise SystemExit(f"unknown phase {arguments.phase}")

    run.prepare()
    run.start_mock()
    run.start_receiver(run.track_port, "tracks")
    run.start_receiver(run.frame_port, "frames")
    if not run.installed():
        run.install()
    # The refusal scenario answers the runtime dialog itself, so the camera
    # permission starts off; the microphone is granted up front because the
    # voice call needs it and its dialog is not what this run is about.
    if not arguments.no_build:
        run.build_apk()
        run.install()
    run.clear_app()
    run.grant(RECORD_AUDIO)
    run.launch()
    run.open_a_session()
    run.open_voice()
    run.await_offer(run.track_port, 0)

    report: dict = {"platform": {
        "model": run.shell("getprop ro.product.model").strip(),
        "release": run.shell("getprop ro.build.version.release").strip(),
        "sdk": run.shell("getprop ro.build.version.sdk").strip(),
        "fingerprint": run.shell("getprop ro.build.fingerprint").strip(),
        "accel": "none (TCG, no /dev/kvm)",
    }}
    if not only or "camera" in only:
        report["camera"] = run.scenario_camera()
    if not only or "screen" in only:
        report["screen"] = run.scenario_screen()
    if not only or "frames" in only:
        report["frames"] = run.scenario_frames()
    if not only or "kill" in only:
        report["kill"] = run.scenario_kill()
    run.record("report", report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
