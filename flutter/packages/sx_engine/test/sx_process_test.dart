import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

class _Os implements SxOs {
  var procs = <SxProc>[];
  var asks = 0, launches = 0;
  String? launchError;

  @override
  List<SxProc> processes() {
    asks++;
    return procs;
  }

  @override
  Future<String?> launch() async {
    launches++;
    return launchError;
  }

  @override
  Future<void> askToClose(List<SxProc> procs) async {}
}

void main() {
  group('Windows process names', () {
    test('ShowXpress counts, its installer, updater and helpers do not', () {
      expect(isSxProcessName(processNameOf('TheLightingController.exe')), isTrue);
      expect(isSxProcessName(processNameOf('ShowXpress.EXE')), isTrue);
      expect(isSxProcessName('thelightingcontroller'), isTrue);
      for (final n in ['ShowXpressSetup', 'TheLightingController_unins000', 'ShowXpressUpdater', 'SXHelper', 'ShowXpress Helper', 'explorer']) {
        expect(isSxProcessName(n), isFalse, reason: n);
      }
    });
  });

  group('Mac programs', () {
    test('only the main program counts, not helpers or SX Studio', () {
      for (final exe in [
        '/Applications/ShowXpress/TheLightingController.app/Contents/MacOS/TheLightingController',
        '/Users/dj/Applications/ShowXpress.app/Contents/MacOS/ShowXpress',
      ]) {
        expect(isMacSxExe(exe), isTrue, reason: exe);
      }
      for (final exe in [
        '/sbin/launchd',
        '/Applications/ShowXpress/TheLightingController.app/Contents/MacOS/TheLightingControllerHelper',
        '/Applications/SX Studio.app/Contents/MacOS/SXHelper',
        '/Applications/SX Studio.app/Contents/Resources/TheLightingController',
      ]) {
        expect(isMacSxExe(exe), isFalse, reason: exe);
      }
    });

    test('the app a program runs from', () {
      expect(
        macAppOf('/Applications/ShowXpress/TheLightingController.app/Contents/MacOS/TheLightingController'),
        '/Applications/ShowXpress/TheLightingController.app',
      );
      expect(macAppOf('/usr/bin/ps'), isNull);
    });

    test('the app with the interface driver next to it wins', () {
      const plain = '/Applications/TheLightingController.app', withDriver = '/Applications/ShowXpress/TheLightingController.app';
      expect(pickMacApp([plain, withDriver], (a) => a == withDriver), withDriver);
      expect(pickMacApp([plain, withDriver], (_) => false), plain);
      expect(pickMacApp([], (_) => true), isNull);
    });
  });

  group('the quit question', () {
    final quit = quitTexts(['[Texts]', 'Txt_quit=Voulez-vous vraiment &quitter ?', 'Txt_save=Save?']);
    DialogControl text(String t) => (cls: 'Static', text: t, id: 0xFFFF);
    DialogControl button(String t, int id) => (cls: 'Button', text: t, id: id);

    test('is answered with Yes, in any of ShowXpress\'s languages', () {
      expect(quitDialogYes([text('Do you really want to quit?'), button('&Yes', 6), button('&No', 7)], quit), 1);
      expect(quitDialogYes([text('Voulez-vous vraiment\r\nquitter ?'), button('&Oui', 6), button('&Non', 7)], quit), 1);
      expect(quitDialogYes([text('Do you really want to quit?'), button('OK', 1)], quit), 1);
    });

    test('a question about saving, or any other box, is left to the user', () {
      expect(quitDialogYes([text('Do you want to save the show?'), button('&Yes', 6), button('&No', 7), button('Cancel', 2)], quit), isNull);
      expect(quitDialogYes([text('Do you really want to quit?'), text('Unsaved changes.'), button('&Yes', 6)], quit), isNull);
      expect(quitDialogYes([text('Do you really want to quit?'), button('&No', 7)], quit), isNull);
    });
  });

  group('DesktopSxApp', () {
    test('asks for the process list at most once a second', () {
      final os = _Os()..procs = [(pid: 1, exe: 'x')];
      final sx = DesktopSxApp(os);
      expect(sx.running, isTrue);
      expect(sx.running, isTrue);
      expect(os.asks, 1);
    });

    test('launch says when ShowXpress is already open, and passes on a missing install', () async {
      final os = _Os()..procs = [(pid: 1, exe: 'x')];
      final sx = DesktopSxApp(os);
      final r = await sx.launch();
      expect(r.out, '  ShowXpress is already open');
      expect(r.extra['already'], isTrue);
      expect(os.launches, 0);
      os
        ..procs = []
        ..launchError = 'ShowXpress was not found in Applications.';
      expect((await sx.launch()).error, 'ShowXpress was not found in Applications.');
    });
  });
}
