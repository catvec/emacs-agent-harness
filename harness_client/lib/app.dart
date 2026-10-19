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

class _HarnessAppState extends State<HarnessApp> {
  late final AppController _app;

  @override
  void initState() {
    super.initState();
    _app = widget.appController ?? AppController(settings: widget.settings);
    _configure();
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
    if (!mounted || !kIsWeb) return;
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
        if (app.phase == ConnectionPhase.connected) {
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
