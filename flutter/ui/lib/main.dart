import 'package:flutter/material.dart';
import 'package:sx_api/sx_api.dart';

import 'app_state.dart';
import 'boot/boot.dart';
import 'shell.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(SxStudio(client: await boot()));
}

class SxStudio extends StatefulWidget {
  const SxStudio({super.key, required this.client});

  final SxClient client;

  @override
  State<SxStudio> createState() => _SxStudioState();
}

class _SxStudioState extends State<SxStudio> {
  // In a browser `?tab=speed` opens straight on a tab.
  late final _state = AppState(widget.client, tab: Uri.base.queryParameters['tab'] ?? 'home');

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppScope(
    state: _state,
    child: MaterialApp(title: 'SX Studio', debugShowCheckedModeBanner: false, theme: sxTheme(), home: const Shell()),
  );
}
