import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:sx_api/sx_api.dart';

import 'app_state.dart';
import 'boot/boot.dart';
import 'boot/desktop_window.dart';
import 'shell.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // In a browser `?theme=light` picks the theme for this visit, for screenshots.
  final asked = ThemeMode.values.asNameMap()[Uri.base.queryParameters['theme']];
  final SxClient client;
  try {
    client = await boot();
  } on BootFailure catch (e) {
    runApp(_BootFailed(e.message));
    return;
  }
  runApp(SxStudio(client: client, themeMode: asked ?? await loadThemeMode(), desktop: !kIsWeb));
}

/// Why the app couldn't start, in place of the app.
class _BootFailed extends StatelessWidget {
  const _BootFailed(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'SX Studio',
    debugShowCheckedModeBanner: false,
    theme: sxTheme(),
    home: Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(message, style: TextStyle(color: Sx.text, fontSize: 14)),
        ),
      ),
    ),
  );
}

class SxStudio extends StatefulWidget {
  const SxStudio({super.key, required this.client, this.themeMode = ThemeMode.dark, this.desktop = false});

  final SxClient client;
  final ThemeMode themeMode;

  /// The laptop app, with a native window that closes and opens again
  /// ([windowChannel]). False in a browser and in tests.
  final bool desktop;

  @override
  State<SxStudio> createState() => _SxStudioState();
}

class _SxStudioState extends State<SxStudio> with WidgetsBindingObserver {
  /// The page's state. Null while the window is closed: the old page was
  /// gone then, so nothing polls the engine and its idle rule can run.
  AppState? _page;
  late ThemeMode _themeMode = widget.themeMode;

  /// Quitting the app (not closing its window, see [_closed]) stops the
  /// lights the engine is driving first.
  late final _exit = AppLifecycleListener(
    onExitRequested: () async {
      await shutdown();
      return AppExitResponse.exit;
    },
  );

  @override
  void initState() {
    super.initState();
    _exit; // a late field starts listening only once it is read
    WidgetsBinding.instance.addObserver(this);
    // In a browser `?tab=speed` opens straight on a tab.
    _open(Uri.base.queryParameters['tab'] ?? 'home');
    if (widget.desktop) windowChannel.setMethodCallHandler(_onWindow);
  }

  @override
  void dispose() {
    if (widget.desktop) windowChannel.setMethodCallHandler(null);
    _exit.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _page?.dispose();
    super.dispose();
  }

  void _open(String tab) {
    final page = _page = AppState(widget.client, tab: tab, themeMode: _themeMode)..addListener(_applyTheme);
    _themeMode = page.themeMode;
    _applyTheme();
  }

  Future<Object?> _onWindow(MethodCall call) async {
    switch (call.method) {
      case 'closed':
        await _closed();
      case 'opened':
        if (_page == null) setState(() => _open('home'));
    }
    return null;
  }

  /// The window was closed (the runner hid it). Like the old page going
  /// away: live output this window started stops (the old `beforeunload`),
  /// the screens go, and their polling with them. The engine carries on.
  Future<void> _closed() async {
    final page = _page;
    if (page == null) return;
    if (LiveWatch.mine) {
      try {
        await widget.client.liveStop();
      } on ApiException {
        // the engine's own timeout puts the lights out
      }
    }
    if (!mounted) return;
    setState(() => _page = null);
    // a hidden window draws no frames by itself
    SchedulerBinding.instance.scheduleForcedFrame();
    await SchedulerBinding.instance.endOfFrame.timeout(const Duration(seconds: 1), onTimeout: () {});
    page.dispose();
  }

  @override
  void didChangePlatformBrightness() => _applyTheme();

  /// Points [Sx] at the dark or the light colors. Widgets read those colors
  /// as plain getters, so nothing depends on them and a normal rebuild would
  /// skip most of the tree. This marks every widget to rebuild and repaint
  /// instead, which keeps each screen's state and its unsaved edits.
  void _applyTheme() {
    final page = _page;
    if (page == null) return;
    _themeMode = page.themeMode;
    final light = switch (page.themeMode) {
      ThemeMode.light => true,
      ThemeMode.dark => false,
      ThemeMode.system => WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.light,
    };
    if (light == Sx.isLight) return;
    Sx.use(light: light);
    if (!mounted) return;
    void visit(Element e) {
      e.markNeedsBuild();
      e.renderObject?.markNeedsPaint();
      e.visitChildren(visit);
    }

    setState(() {});
    context.visitChildElements(visit);
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    if (page == null) return const SizedBox.shrink();
    return AppScope(
      // a new page each time the window opens again, as the old one was
      key: ObjectKey(page),
      state: page,
      child: MaterialApp(title: 'SX Studio', debugShowCheckedModeBanner: false, theme: sxTheme(), home: const Shell()),
    );
  }
}
