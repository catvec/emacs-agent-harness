// The window each desktop runner opens: the size of a desktop, and the
// smallest a person may drag it to.  The pages need room for the navigation
// pane beside the chat, and the client is not a phone app in a desktop frame.
//
// These are source files no Dart test can run: the test reads them, so that a
// runner that loses its size, or a Windows runner that is not there, fails
// here rather than in a build nobody ran.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: path);
  return file.readAsStringSync();
}

void main() {
  test('macOS opens at 1280x820 and stops at 760x560', () {
    final window = _read('macos/Runner/MainFlutterWindow.swift');
    expect(
      window,
      contains('contentMinSize = NSSize(width: 760, height: 560)'),
    );
    expect(
      window,
      contains('setContentSize(NSSize(width: 1280, height: 820))'),
    );
  });

  test('Linux opens at 1280x820 and stops at 760x560', () {
    final application = _read('linux/runner/my_application.cc');
    expect(
      application,
      contains('gtk_window_set_default_size(window, 1280, 820);'),
    );
    expect(application, contains('geometry.min_width = 760;'));
    expect(application, contains('geometry.min_height = 560;'));
    expect(application, contains('GDK_HINT_MIN_SIZE'));
    expect(application, contains('gtk_window_set_title(window, "Harness");'));
  });

  test('the Linux runner is a whole one', () {
    for (final path in const [
      'linux/CMakeLists.txt',
      'linux/flutter/CMakeLists.txt',
      'linux/flutter/generated_plugin_registrant.cc',
      'linux/runner/CMakeLists.txt',
      'linux/runner/main.cc',
      'linux/runner/my_application.cc',
      'linux/runner/my_application.h',
    ]) {
      expect(File(path).existsSync(), isTrue, reason: path);
    }
    expect(_read('.metadata'), contains('platform: linux'));
  });

  test('only the app\'s own sources are compiled with -Werror', () {
    // apply_standard_settings runs for the plugins as well, and their sources
    // come from the pub cache, where a warning a newer compiler learns to make
    // is not ours to fix.  Clang 23 added -Wunused-but-set-global and
    // flutter_webrtc 1.6.3 sets a Windows-only messenger pointer on Linux, so
    // `-Werror` there stopped `flutter build linux` outright:
    //
    //   flutter_common.cc:13:14: error: variable 'g_host_messenger' set but not
    //   used [-Werror,-Wunused-but-set-global]
    //
    // No Dart test builds the desktop app, so the files are read instead.  The
    // prose in them may name the flag; the compile options may not.
    final flags = RegExp(r'^\s*target_compile_options\(.*$', multiLine: true);
    final standard = _read('linux/CMakeLists.txt');
    final inherited = flags
        .allMatches(standard)
        .map((match) => match.group(0)!)
        .where((line) => line.contains('-Werror'));
    expect(
      inherited,
      isEmpty,
      reason:
          'linux/CMakeLists.txt apply_standard_settings is applied to every '
          'plugin, whose sources are not ours: -Werror there breaks the Linux '
          'build on a plugin warning',
    );
    expect(standard, contains('target_compile_options(\${TARGET} PRIVATE -Wall)'));
    expect(
      _read('linux/runner/CMakeLists.txt'),
      contains('target_compile_options(\${BINARY_NAME} PRIVATE -Werror)'),
      reason:
          'the app\'s own sources must stay held to -Werror: they are ours to '
          'keep warning-free',
    );
  });

  test('Windows opens at 1280x820 and stops at 760x560', () {
    final main = _read('windows/runner/main.cpp');
    expect(main, contains('Win32Window::Size size(1280, 820);'));
    expect(main, contains('window.Create(L"Harness"'));
    expect(
      main,
      contains('window.SetMinimumSize(Win32Window::Size(760, 560));'),
    );
    final window = _read('windows/runner/win32_window.cpp');
    expect(window, contains('case WM_GETMINMAXINFO:'));
    expect(window, contains('ptMinTrackSize.x'));
    expect(window, contains('ptMinTrackSize.y'));
  });

  test('the Windows runner is a whole one', () {
    for (final path in const [
      'windows/CMakeLists.txt',
      'windows/flutter/CMakeLists.txt',
      'windows/flutter/generated_plugin_registrant.cc',
      'windows/runner/CMakeLists.txt',
      'windows/runner/flutter_window.cpp',
      'windows/runner/main.cpp',
      'windows/runner/win32_window.cpp',
      'windows/runner/Runner.rc',
      'windows/runner/resources/app_icon.ico',
    ]) {
      expect(File(path).existsSync(), isTrue, reason: path);
    }
    expect(
      _read('windows/runner/Runner.rc'),
      contains('VALUE "ProductName", "Harness"'),
    );
    expect(_read('.metadata'), contains('platform: windows'));
  });
}
