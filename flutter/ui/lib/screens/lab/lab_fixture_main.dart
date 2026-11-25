import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:sx_api/sx_api.dart';

import '../../app_state.dart';
import '../../boot/boot.dart';
import '../../theme.dart';
import 'lab_screen.dart';

/// Debug only: shows the SX Player screen drawn from `lab_fixture.json`
/// (`{board, layout, status}`), served next to `index.html`, so the screen
/// can be looked at before the engine has the player routes.
///
///     flutter build web -t lib/screens/lab/lab_fixture_main.dart -o /tmp/<you>/web
///
/// Put the fixture in that folder and serve it with `--web /tmp/<you>/web`.
/// Never part of the app.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final client = await boot();
  final r = await http.get(Uri.base.resolve('lab_fixture.json'));
  final j = (jsonDecode(utf8.decode(r.bodyBytes)) as Map).cast<String, Object?>();
  final fixture = LabFixture(
    board: LabBoard.fromJson(j.obj('board')),
    layout: PlayerLayout.fromJson(j.obj('layout')),
    status: LabStatus.fromJson(j.obj('status')),
  );
  runApp(
    AppScope(
      state: AppState(client, tab: 'lab'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: sxTheme(),
        home: Scaffold(
          body: SafeArea(
            child: Builder(builder: (c) => LabScreen(c, fixture: fixture)),
          ),
        ),
      ),
    ),
  );
}
