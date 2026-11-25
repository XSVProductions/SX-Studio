import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import 'app_state.dart';
import 'boot/boot.dart';
import 'shell.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // In a browser `?theme=light` picks the theme for this visit, for screenshots.
  final asked = ThemeMode.values.asNameMap()[Uri.base.queryParameters['theme']];
  runApp(SxStudio(client: await boot(), themeMode: asked ?? await loadThemeMode()));
}

class SxStudio extends StatefulWidget {
  const SxStudio({super.key, required this.client, this.themeMode = ThemeMode.dark});

  final SxClient client;
  final ThemeMode themeMode;

  @override
  State<SxStudio> createState() => _SxStudioState();
}

class _SxStudioState extends State<SxStudio> with WidgetsBindingObserver {
  // In a browser `?tab=speed` opens straight on a tab.
  late final _state = AppState(widget.client, tab: Uri.base.queryParameters['tab'] ?? 'home', themeMode: widget.themeMode);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _state.addListener(_applyTheme);
    _applyTheme();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _state.dispose();
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() => _applyTheme();

  /// Points [Sx] at the dark or the light colors. Widgets read those colors
  /// as plain getters, so nothing depends on them and a normal rebuild would
  /// skip most of the tree. This marks every widget to rebuild and repaint
  /// instead, which keeps each screen's state and its unsaved edits.
  void _applyTheme() {
    final light = switch (_state.themeMode) {
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
  Widget build(BuildContext context) => AppScope(
    state: _state,
    child: MaterialApp(title: 'SX Studio', debugShowCheckedModeBanner: false, theme: sxTheme(), home: const Shell()),
  );
}
