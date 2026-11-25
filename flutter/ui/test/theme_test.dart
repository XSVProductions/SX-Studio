import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sx_api/sx_api.dart';
import 'package:sx_studio/app_state.dart';
import 'package:sx_studio/main.dart';
import 'package:sx_studio/shell.dart';
import 'package:sx_studio/theme.dart';

void main() {
  tearDown(() => Sx.use(light: false));

  testWidgets('switching the theme recolors the screen and keeps its state', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final client = SxClient(
      Uri.parse('http://laptop'),
      token: 't',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'ok': true,
            'open': false,
            'q': {'items': <Object>[], 'reopen': true},
          }),
          200,
        ),
      ),
    );
    await tester.pumpWidget(SxStudio(client: client));
    await tester.pump();

    // A Home tile listens to nothing, so only the rebuild of every widget reaches it.
    Color? tagColor() => tester.widget<Text>(find.text('STEP 01')).style?.color;
    final shell = tester.state(find.byType(Shell));
    final dark = tagColor();

    AppScope.read(tester.element(find.byType(Shell))).setThemeMode(ThemeMode.light);
    await tester.pumpAndSettle();

    expect(Sx.isLight, isTrue);
    expect(tagColor(), Sx.accent);
    expect(tagColor(), isNot(dark));
    expect(tester.state(find.byType(Shell)), same(shell));
    expect((await SharedPreferences.getInstance()).getString('theme'), 'light');

    // Take the app down so its status timer stops.
    await tester.pumpWidget(const SizedBox());
  });
}
