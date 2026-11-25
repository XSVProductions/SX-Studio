import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_engine/sx_engine.dart';
import 'package:test/test.dart';

/// The fix the port makes to Google Drive sync: a file the last sync put on
/// Google Drive, and that has since left the show, is removed there. Nothing
/// else on Google Drive is ever removed.
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

  test('a file deleted from the show leaves Google Drive on the next sync', () {
    driveSync(env, at);
    expect(there('scenes/B.scex').existsSync(), isTrue);
    here('scenes/B.scex').deleteSync();

    final out = driveSync(env, at);
    expect(out, contains('REMOVED  1 file(s) from Google Drive that are no longer in the show'));
    expect(there('scenes/B.scex').existsSync(), isFalse);
    expect(there('scenes/A.scex').existsSync(), isTrue);
  });

  test('so an import no longer brings a deleted file back', () {
    driveSync(env, at);
    here('scenes/B.scex').deleteSync();
    driveSync(env, at);
    driveImport(env, at);
    expect(here('scenes/B.scex').existsSync(), isFalse);
    expect(here('scenes/A.scex').existsSync(), isTrue);
  });

  test('a file SX Studio did not put on Google Drive is never removed', () {
    there('notes from someone.txt')
      ..createSync(recursive: true)
      ..writeAsStringSync('mine');
    driveSync(env, at);
    driveSync(env, at);
    expect(there('notes from someone.txt').readAsStringSync(), 'mine');
  });

  test('a removed file that changed on Google Drive since is left alone', () {
    driveSync(env, at);
    here('scenes/B.scex').deleteSync();
    // another laptop synced a new B in the meantime
    there('scenes/B.scex')
      ..writeAsStringSync('newer B from the other laptop')
      ..setLastModifiedSync(DateTime.now().add(const Duration(minutes: 5)));

    final out = driveSync(env, at);
    expect(out, contains('1 file(s) no longer in the show were changed on Google Drive since the last sync - left alone'));
    expect(there('scenes/B.scex').readAsStringSync(), 'newer B from the other laptop');
    // and it is not ours any more, so a later sync leaves it too
    expect(driveSync(env, at), isNot(contains('REMOVED')));
    expect(there('scenes/B.scex').existsSync(), isTrue);
  });

  test('a file newer on Google Drive is not ours to remove later', () {
    there('scenes/B.scex')
      ..createSync(recursive: true)
      ..writeAsStringSync('B from the other laptop')
      ..setLastModifiedSync(DateTime.now().add(const Duration(hours: 1)));
    expect(driveSync(env, at), contains('1 file(s) are newer on Google Drive - left alone'));
    here('scenes/B.scex').deleteSync();
    driveSync(env, at);
    expect(there('scenes/B.scex').readAsStringSync(), 'B from the other laptop');
  });

  test('a record made for another Google Drive folder removes nothing', () {
    driveSync(env, at);
    final rec = here(syncFilesFile);
    rec.writeAsStringSync(rec.readAsStringSync().replaceFirst(jsonEncode(drive), jsonEncode('/elsewhere')));
    here('scenes/B.scex').deleteSync();
    expect(driveSync(env, at), isNot(contains('REMOVED')));
    expect(there('scenes/B.scex').existsSync(), isTrue);
  });

  test('the sync record stays on this computer', () {
    driveSync(env, at);
    expect(here(syncFilesFile).existsSync(), isTrue);
    expect(there(syncFilesFile).existsSync(), isFalse);
    // an import keeps this computer's record, not one found on Google Drive
    final mine = here(syncFilesFile).readAsStringSync();
    there(syncFilesFile).writeAsStringSync('{"target":"x","files":{}}');
    driveImport(env, at);
    expect(here(syncFilesFile).readAsStringSync(), mine);
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
