import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

/// Google Drive sync and import, beyond what the parity test can reach: the
/// sync never removes anything on Google Drive, as the old `gdrive.ps1`, and
/// Windows finds Google Drive by drive letter G or a label saying Google.
void main() {
  late Directory tmp;
  late String show, drive;
  late DrivePlaces at;
  late ShowEnv env;

  File here(String rel) => File(p.join(show, rel));
  File there(String rel) => File(p.join(drive, rel));

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sx_gdrive_');
    show = p.join(tmp.path, 'LS', 'My Show');
    drive = p.join(tmp.path, 'My Drive', 'AWAAZ', 'Lighting', 'My Show');
    at = DrivePlaces(dest: drive, backups: p.join(tmp.path, 'backups'));
    env = ShowEnv(show);
    for (final f in ['Live/live.ini', 'scenes/A.scex', 'scenes/B.scex', 'fixtures.ini']) {
      here(f)
        ..createSync(recursive: true)
        ..writeAsStringSync('$f\r\n');
    }
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('a file deleted from the show stays on Google Drive, as the old sync left it', () {
    driveSync(env, at);
    here('scenes/B.scex').deleteSync();
    there('notes from someone.txt').writeAsStringSync('mine');

    final out = driveSync(env, at);
    expect(out.split('\n'), ['  Google Drive folder: $drive', '  CHANGED  0 file(s) copied, 3 already up to date']);
    expect(there('scenes/B.scex').existsSync(), isTrue);
    expect(there('notes from someone.txt').readAsStringSync(), 'mine');
    expect(Directory(show).listSync().map((e) => p.basename(e.path)), isNot(contains('gdrive_sync_files.json')));
  });

  test("the sync and import records stay on this computer, whatever their case", () {
    here('GDRIVE_SYNC.JSON').writeAsStringSync('{}');
    here('gdrive_import.json').writeAsStringSync('{}');
    driveSync(env, at);
    expect(
      Directory(drive).listSync().map((e) => p.basename(e.path).toLowerCase()),
      isNot(anyOf(contains('gdrive_sync.json'), contains('gdrive_import.json'))),
    );
  });

  test('Windows takes the first drive that is G or labelled Google, with My Drive on it', () {
    final have = {r'G:\My Drive', r'H:\My Drive', r'E:\My Drive', r'D:\My Drive'};
    String pick(List<(String, String)> drives) => pickMyDrive([for (final (l, n) in drives) (letter: l, label: n)], have.contains);
    expect(pick([('C', 'Windows'), ('D', 'Data'), ('G', '')]), r'G:\My Drive');
    expect(pick([('C', ''), ('E', 'GOOGLE DRIVE'), ('G', '')]), r'E:\My Drive');
    // a drive with My Drive on it but no Google label is not Google Drive
    expect(pick([('C', ''), ('D', 'Backup'), ('H', 'My Google Drive')]), r'H:\My Drive');
    expect(pick([('C', ''), ('D', 'Backup')]), '');
    // labelled Google, but no My Drive folder
    expect(pick([('F', 'Google Drive')]), '');
  });

  test('sync and import refuse while ShowXpress is open', () {
    final open = ShowEnv(show, sxRunning: () => true);
    expect(() => driveSync(open, at), throwsA(isA<ToolError>().having((e) => e.message, 'message', startsWith('ShowXpress is OPEN - NOTHING was copied'))));
    driveSync(env, at);
    expect(() => driveImport(open, at), throwsA(isA<ToolError>().having((e) => e.message, 'message', startsWith('ShowXpress is OPEN - NOTHING was changed'))));
  });

  test('no Google Drive on this computer', () {
    final none = DrivePlaces(dest: '', backups: at.backups);
    expect(() => driveSync(env, none), throwsA(isA<ToolError>().having((e) => e.message, 'message', contains('NOTHING was copied'))));
    expect(() => driveImport(env, none), throwsA(isA<ToolError>().having((e) => e.message, 'message', contains('NOTHING was changed'))));
    expect(drivePreview(env, none).found, isFalse);
  });

  test("a new laptop with no show takes the show's name from Google Drive", () {
    driveSync(env, at);
    final my = p.join(tmp.path, 'My Drive');
    expect(p.basename(showFromDrive(my, ToolError('no show'))), 'My Show');
    expect(() => showFromDrive(p.join(tmp.path, 'empty'), ToolError('no show')), throwsA(isA<ToolError>()));
  });

  test('the Google Drive folder set in settings wins while it exists', () {
    final my = Directory(p.join(tmp.path, 'My Drive'))..createSync();
    final cfg = Directory(p.join(tmp.path, 'cfg'))..createSync();
    File(p.join(cfg.path, 'settings.json')).writeAsStringSync(jsonEncode({'driveFolder': my.path}));
    final found = findDrive(cfg.path);
    expect(found.my, my.path);
    expect(drivePlaces(found, show, cfg.path).dest, drive);
  });
}
