# Flutter build measurements, as observed

Raw values behind [flutter-build-performance.md](../flutter-build-performance.md),
kept so a later change can be compared against them rather than against memory.

- **environment**: Flutter 3.47.7, Gradle 9.3.1, AGP 9.1.0, KGP 2.4.0, JDK 21, NDK 30.0.14904198, build-tools 36.1.0, compileSdk 36; flutter_tts 4.2.5, flutter_webrtc 1.6.3
- **default-build**: flutter build apk --release (all three ABIs): 108.5 MB, native-code 'arm64-v8a' 'armeabi-v7a' 'x86_64'
- **one-abi-build**: flutter build apk --release --target-platform android-arm64 --android-project-arg=harness.packageAbi=arm64-v8a: 37.8 MB, native-code 'arm64-v8a'
- **kgp-warning**: WARNING: Your app uses the following plugins that apply Kotlin Gradle Plugin (KGP): flutter_tts, flutter_webrtc / Future versions of Flutter will fail to build if your app uses plugins that apply KGP.
- **kgp-builtin-kotlin-true**: FAILURE: Failed to apply plugin 'kotlin-android' / Failed to apply plugin 'org.jetbrains.kotlin.android' (flutter_tts 4.2.5 applies KGP unconditionally)
- **gradle-parallel**: no change on the no-op path: median 5.6 s with and without org.gradle.parallel=true
- **gradle-caching**: worse on the no-op path: 98 s first, 12 s after, against 5-10 s without org.gradle.caching=true
- **configuration-cache**: fails: ReleaseMinSdkCheck is not serializable
