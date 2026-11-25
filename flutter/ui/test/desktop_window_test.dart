import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sx_api/sx_api.dart';
import 'package:sx_studio/boot/boot_io.dart';
import 'package:sx_studio/boot/desktop_window.dart';
import 'package:sx_studio/main.dart';
import 'package:sx_studio/shell.dart';

/// A pretend engine that counts the window's status polls and keeps POSTs.
class _Engine {
  var polls = 0;
  final posts = <String>[];

  late final mock = MockClient((r) async {
    if (r.method == 'POST') posts.add(r.url.path);
    final Object answer = switch (r.url.path) {
      '/api/sx' => () {
        polls++;
        return {
          'ok': true,
          'open': false,
          'q': {'items': <Object>[], 'reopen': true},
        };
      }(),
      '/api/settings' => {'ok': true, 'settings': const SxSettings().toJson(), 'ver': '2.0.0', 'phone': false},
      _ => {'ok': true},
    };
    return http.Response(jsonEncode(answer), 200);
  });

  SxClient client() => SxClient(Uri.parse('http://laptop'), token: 't', client: LiveWatch(mock));
}

void main() {
  tearDown(() => LiveWatch.mine = false);

  group('closing the window', () {
    /// The runner tells the app its window was closed or opened again.
    Future<void> window(WidgetTester tester, String method) async {
      final done = tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        windowChannel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
        (_) {},
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await done;
      await tester.pump();
    }

    Future<_Engine> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1300, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final engine = _Engine();
      await tester.pumpWidget(SxStudio(client: engine.client(), desktop: true));
      await tester.pump();
      await tester.pump();
      return engine;
    }

    testWidgets('takes the page down and stops polling; opening shows a fresh Home', (tester) async {
      final engine = await pump(tester);
      expect(find.byType(Shell), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(engine.polls, greaterThan(0));

      await window(tester, 'closed');
      expect(find.byType(Shell), findsNothing);
      final polls = engine.polls;
      await tester.pump(const Duration(seconds: 30));
      expect(engine.polls, polls, reason: 'a closed window must not keep the engine awake');
      expect(engine.posts, isNot(contains('/api/live/stop')));

      await window(tester, 'opened');
      expect(find.byType(Shell), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(engine.polls, greaterThan(polls));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('stops live output this window started, as the old page did', (tester) async {
      final engine = await pump(tester);
      await engine.client().run('/api/live/start');
      expect(LiveWatch.mine, isTrue);
      await window(tester, 'closed');
      expect(engine.posts, contains('/api/live/stop'));
      expect(LiveWatch.mine, isFalse);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('the running copy', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('sx_boot_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('the info file is the old one, per port', () {
      expect(infoFile(appPort).uri.pathSegments.last, 'showxpress_helper_gui.json');
      expect(infoFile(47390).uri.pathSegments.last, 'showxpress_helper_gui_47390.json');
      final f = File('${tmp.path}/info.json');
      writeInfo(f, url: 'http://localhost:47321/?t=ab', pid: 1234, ver: '2.0.0');
      expect(readInfo(f), (url: 'http://localhost:47321/?t=ab', pid: 1234, ver: '2.0.0'));
      // the PowerShell app's file, written by ConvertTo-Json
      f.writeAsStringSync('{\r\n    "url":  "http://localhost:47321/?t=cd",\r\n    "pid":  "88",\r\n    "ver":  "1.9.9"\r\n}');
      expect(readInfo(f), (url: 'http://localhost:47321/?t=cd', pid: 88, ver: '1.9.9'));
      f.writeAsStringSync('not json');
      expect(readInfo(f), isNull);
      expect(readInfo(File('${tmp.path}/none.json')), isNull);
    });

    test('only the old app or this one is replaced', () {
      for (final n in ['pwsh.exe', 'powershell.exe', 'PowerShell.EXE', 'sx_studio.exe', 'sx_studio', 'pwsh']) {
        expect(isAppProcess(n), isTrue, reason: n);
      }
      for (final n in [null, 'chrome.exe', 'pwsh_other.exe', 'my_sx_studio.exe']) {
        expect(isAppProcess(n), isFalse, reason: n);
      }
      expect(processName(pid)?.toLowerCase(), isNotNull);
      expect(processName(0), isNull);
    });

    test('the phone page is the web folder shipped next to the app', () {
      final exe = '${tmp.path}${Platform.pathSeparator}sx_studio.exe';
      final web = '${tmp.path}${Platform.pathSeparator}web';
      if (!Platform.isMacOS) expect(bundledWeb(exe), web, reason: 'missing: still where it should be');
      Directory(web).createSync();
      File('$web/index.html').writeAsStringSync('<html></html>');
      expect(bundledWeb(exe), web);
    });
  });

  test('LiveWatch follows only POSTs to start and stop', () async {
    final engine = _Engine();
    final c = LiveWatch(engine.mock);
    await c.get(Uri.parse('http://laptop/api/live/start'));
    expect(LiveWatch.mine, isFalse);
    await c.post(Uri.parse('http://laptop/api/live/start'));
    expect(LiveWatch.mine, isTrue);
    await c.post(Uri.parse('http://laptop/api/live/frame'));
    expect(LiveWatch.mine, isTrue);
    await c.post(Uri.parse('http://laptop/api/live/stop'));
    expect(LiveWatch.mine, isFalse);
  });
}
