import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/state/app_controller.dart';
import 'src/state/settings_controller.dart';
import 'src/ui/adaptive/platform_style.dart';
import 'src/ui/app_scope.dart';
import 'src/ui/screens/connect_screen.dart';
import 'src/ui/screens/home_shell.dart';
import 'src/ui/theme/harness_theme.dart';

class HarnessApp extends StatefulWidget {
  const HarnessApp({super.key, required this.settings, this.appController});

  final SettingsController settings;
  final AppController? appController;

  @override
  State<HarnessApp> createState() => _HarnessAppState();
}

class _HarnessAppState extends State<HarnessApp> with WidgetsBindingObserver {
  late final AppController _app;
  final _navigator = GlobalKey<NavigatorState>();
  bool _inSession = false;

  @override
  void initState() {
    super.initState();
    _app = widget.appController ?? AppController(settings: widget.settings);
    _inSession = _app.hasSession;
    _app.addListener(_sessionChanged);
    WidgetsBinding.instance.addObserver(this);
    // A device that remembers its harness goes back in as the app opens.
    // With the settings read already (see `main`), that starts before the
    // first frame, which is then not the form for an address and a secret
    // that the device holds.
    if (widget.settings.loaded) unawaited(_app.resume());
    _configure();
  }

  /// A conversation or a sheet is opened on top of the home screens, on the
  /// navigator.  When the session ends (the harness turned the device away,
  /// the person disconnected) the home screens give way to the connection
  /// screen, and whatever was opened on them must go too, not stay up over
  /// it.  What was typed in them is kept ([AppController.drafts]).
  void _sessionChanged() {
    final inSession = _app.hasSession;
    if (_inSession && !inSession) {
      _navigator.currentState?.popUntil((route) => route.isFirst);
    }
    _inSession = inSession;
  }

  /// A phone puts a connection to sleep without a word while the app is
  /// away, and the person who comes back should not be the first to find
  /// out: check it, and connect again if it died.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_app.resumed());
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _app.setForeground(false);
      case AppLifecycleState.inactive:
        // Only a moment: a permission dialog, the notification shade.
        break;
    }
  }

  /// Read local preferences in the background.  The client's first screen is
  /// the connection screen, and it must not wait for the platform's
  /// preference store: a plugin that is missing, blocked or unresponsive used
  /// to leave the app on a splash screen, with no way to enter an address.
  Future<void> _configure() async {
    try {
      await widget.settings.load();
    } catch (error) {
      // SettingsController.load already falls back to its defaults; this
      // catch keeps a test or a platform override from taking the app down
      // before the connection screen is shown.
      debugPrint('Harness: could not load local settings: $error');
      return;
    }
    if (!mounted) return;
    // What the device remembers is known now (a no-op when it began already).
    unawaited(_app.resume());
    if (!kIsWeb) return;
    final query = Uri.base.queryParameters;
    final platform = query['platform']?.toLowerCase();
    if (platform == 'cupertino' || platform == 'apple' || platform == 'ios') {
      await widget.settings.setPreviewPlatform(PreviewPlatform.cupertino);
    } else if (platform == 'material' || platform == 'android') {
      await widget.settings.setPreviewPlatform(PreviewPlatform.material);
    }
    switch (query['theme']) {
      case 'light':
        await widget.settings.setThemeMode(ThemeMode.light);
      case 'dark':
        await widget.settings.setThemeMode(ThemeMode.dark);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _app.removeListener(_sessionChanged);
    _app.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.settings,
      builder: (context, _) {
        final style = widget.settings.useCupertino
            ? HarnessPlatformStyle.cupertino
            : HarnessPlatformStyle.material;
        return HarnessStyle(
          style: style,
          child: HarnessScope(
            app: _app,
            settings: widget.settings,
            child: MaterialApp(
              navigatorKey: _navigator,
              title: 'Harness',
              debugShowCheckedModeBanner: false,
              theme: HarnessTheme.material(Brightness.light),
              darkTheme: HarnessTheme.material(Brightness.dark),
              themeMode: widget.settings.themeMode,
              locale: const Locale('en'),
              supportedLocales: const [Locale('en')],
              localizationsDelegates: const [
                DefaultWidgetsLocalizations.delegate,
                DefaultMaterialLocalizations.delegate,
                DefaultCupertinoLocalizations.delegate,
              ],
              builder: (context, child) {
                if (style == HarnessPlatformStyle.cupertino) {
                  return CupertinoTheme(
                    data: HarnessTheme.cupertino(Theme.of(context).brightness),
                    child: child ?? const SizedBox.shrink(),
                  );
                }
                return child ?? const SizedBox.shrink();
              },
              home: _RootGate(app: _app),
            ),
          ),
        );
      },
    );
  }
}

class _RootGate extends StatelessWidget {
  const _RootGate({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final Widget child;
        // Out of touch for a while is still the session: the screens stay
        // up, with what was typed on them, while the app connects again.
        if (app.hasSession) {
          child = HomeShell(key: const ValueKey('home'), app: app);
        } else {
          child = ConnectScreen(key: const ValueKey('connect'), app: app);
        }
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: child,
        );
      },
    );
  }
}
