# Flutter build performance and the Kotlin Gradle Plugin warnings

This records what an Android release build of `harness_client` costs, where the
time goes, what the `WARNING: Your app uses the following plugins that apply
Kotlin Gradle Plugin (KGP): flutter_tts, flutter_webrtc` line means, and which
changes were made and which were measured and rejected.

## Environment

| Component | Version |
| --- | --- |
| Flutter | 3.47.7 (`harness_client/.flutter-version`) |
| Gradle | 9.3.1 (`android/gradle/wrapper/gradle-wrapper.properties`) |
| Android Gradle Plugin | 9.1.0 (`android/settings.gradle.kts`) |
| Kotlin Gradle Plugin | 2.4.0 (`android/settings.gradle.kts`) |
| JDK | 21 |
| `flutter_tts` | 4.2.5 |
| `flutter_webrtc` | 1.6.3 |
| NDK / Build-Tools / compileSdk | 30.0.14904198 / 36.1.0 / 36 (`android/gradle.properties`) |

Measurements are wall-clock on this machine, 16 threads, with the SDK and pub
cache already populated: no download time is included. Every number below comes
from a release APK build, which is what `tool/qr_install.sh` and
`tool/check_build.sh` produce.

## Where the time goes

A cold release build (empty `build/`) takes 262-316 s across runs, 303 s in
the run of this tree that `tool/check_build.sh` made. The split, from the
Gradle `--profile` report and the Flutter build log:

| Phase | Cold | Warm, no change | Warm, one Dart file changed |
| --- | --- | --- | --- |
| Dependency resolution | < 1 s | < 1 s | < 1 s |
| Gradle configuration | ~4 s | ~2 s | ~2 s |
| Dart kernel snapshot | ~22 s | 0 | ~27 s |
| Native asset build hooks (`cnativeapi` C++, 3 ABIs) | ~196 s | 0 | 0 |
| Dart AOT snapshot (`gen_snapshot`, 3 ABIs) | ~23 s | 0 | ~18 s |
| Kotlin/Java compilation | ~1 s | 0 | 0 |
| R8 minification | ~25 s | 0 | 0 |
| `lintVital` | ~18 s | 0 | 0 |
| Native symbol merge | ~6 s | 0 | 0 |
| Packaging, resources | ~3 s | 0 | 0 |
| **Total** | **262-316 s** | **5-6 s** (18 s with a cold daemon) | **48-62 s** |

So the cold build is dominated by per-ABI work: `libcnativeapi.so` is compiled
with the NDK once per ABI (~65 s each) and `gen_snapshot` runs once per ABI.
Both are repeated for `arm64-v8a`, `armeabi-v7a` and `x86_64`, and the build
takes the same path whether the APK is destined for one phone or for many.

`flutter analyze` is ~20 s; `flutter test` is ~344 s (1744 passed, 16 skipped,
21 failed on this machine at `main` before this change, so those failures are
not from this work).

## The Kotlin Gradle Plugin warning

The warning is emitted by Flutter's Gradle plugin, not by Gradle or AGP.
`FlutterPluginUtils.detectApplyingKotlinGradlePlugin` walks the app's
subprojects, and `getSubprojectPluginState` reads each plugin's `build.gradle`
or `build.gradle.kts` and matches it against `kgpRegexGroovy` and
`kgpRegexKotlin`. Every library plugin whose file text matches is listed. The
check never runs the build file: it matches text. The message means "this
plugin applies the Kotlin Gradle Plugin itself", which is a
forward-compatibility notice: under AGP 9's built-in Kotlin
(`android.builtInKotlin=true`) a plugin must not apply KGP, because AGP applies
it.

The two plugins differ in why they are listed:

- **`flutter_webrtc` 1.6.3** guards its `apply plugin: 'kotlin-android'` behind
  an AGP-major-version check, so it is already correct under built-in Kotlin.
  The `apply` line is still in the file, so `kgpRegexGroovy` matches it. For
  this plugin the warning is a false positive: the line is inside the guard.
- **`flutter_tts` 4.2.5** applies KGP unconditionally and sets `kotlinOptions`,
  which built-in Kotlin does not provide. With `android.builtInKotlin=true` the
  build fails outright (`Failed to apply plugin
  'org.jetbrains.kotlin.android'`), which was measured directly.

Neither plugin has a newer release: `flutter_tts` 4.2.5 and `flutter_webrtc`
1.6.3 are the latest published versions, so there is nothing to upgrade to.
Removing the warning therefore means changing pinned dependencies to
unreleased code, which this change does not do.

What the build uses today is `android.builtInKotlin=false` with KGP 2.4.0,
which is Flutter's own default and what its migration tool writes. It builds
correctly. The warning is a notice about a future AGP default, not a cause of
slowness: Kotlin compilation of these two plugins costs about 1 s on a cold
build and nothing at all on a warm one.

The version relationship is not incidental: AGP 9.1.0 ships built-in Kotlin,
KGP 2.4.0 is the version this project pins for the plugins that still apply it,
and Flutter 3.47.7's template is what sets `builtInKotlin=false`. Moving any of
the three means re-checking the other two.

## What was changed

**`tool/qr_install.sh` builds for the connected phone's ABI.** The installer
already has adb before it builds. If exactly one phone is connected (or
`--device` names one) and adb can report its `ro.product.cpu.abi`, the build is
narrowed to that ABI with `--target-platform`, and the app packs only that ABI's
libraries. A cold build for one ABI takes 168 s instead of 262 s, an
incremental build 49 s instead of 54 s, and the APK is 37.8 MB instead of 108.5
MB (`aapt2 dump badging` then says `native-code: 'arm64-v8a'` rather than all
three). The installed app is the same code on the same phone.

The narrowing does not happen where the APK is meant for something else:
`--serve` hands the APK to whatever scans the code, `--apk` installs a named
file, and a debug build is the developer's own. If no phone is connected, or
adb cannot say its ABI, the build stays as it was and covers all three ABIs.
`--target-abi` sets the ABI explicitly. Two ABIs cannot live in one
`app-release.apk`: a build for another ABI replaces it.

**`android/app/build.gradle.kts` packs only the named ABI.** Flutter's plugin
fills `abiFilters` with all three ABIs before the app's `android` block runs,
and the manifest's `native-code` list is read from it. Narrowing the build with
`--target-platform` without narrowing `abiFilters` would leave a manifest
claiming the APK supports ABIs whose libraries are not in it. The property
`harness.packageAbi`, which the installer passes, clears the filters to the one
ABI. Without the property nothing changes.

## What was measured and rejected

- `org.gradle.parallel=true`: no change to the no-op path (median 5.6 s both
  ways). The slow tasks are single tasks, not parallelizable ones.
- `org.gradle.caching=true`: made the no-op build worse (98 s the first time,
  12 s after) against 5-10 s without it.
- The configuration cache: fails on `ReleaseMinSdkCheck`, which is not
  serializable.
- Kotlin incremental compilation is already off, deliberately, and stays off:
  `gradle.properties` explains the stale-path bug it caused, and the measured
  cost of compiling these plugins from scratch is a few seconds.
- Disabling `lintVital` or dropping native debug symbols would remove real work
  (~24 s and ~6 s), but each removes a check or a capability the build
  currently has, so neither is a build-speed fix.
- Upgrading AGP, Gradle, Kotlin or Flutter: none of the measured cost is in
  them, and each upgrade needs the plugin compatibility re-checked.

## Reproducing the measurements

The numbers above come from release APK builds of this app with the pinned
toolchain. To reproduce them:

```sh
cd harness_client
flutter clean                      # cold
time flutter build apk --release   # all three ABIs
time flutter build apk --release --target-platform android-arm64 \
  --android-project-arg=harness.packageAbi=arm64-v8a
```

For the phase split, add `--profile` to the Gradle invocation through
`android/gradlew` and read `android/build/reports/profile/`, or read the
timestamps Flutter prints for its own steps.

## When to revisit

- When `flutter_tts` or `flutter_webrtc` releases a version that does not apply
  KGP itself: the warning goes away and `builtInKotlin` can be turned on, with
  the plugins re-checked against it.
- When AGP 10 removes `newDsl` and `builtInKotlin`: the two flags in
  `gradle.properties` and the plugins must move together.
- If the per-ABI native build hooks ever become a build-time complaint again,
  the lever is which ABIs a build covers, not the Gradle settings: that is what
  the measurements above say.
