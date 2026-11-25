import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';
import 'package:sx_release/sx_release.dart';

import '../show/show_env.dart';

/// Saves what [from] serves into [to]. Throws when it can't, `DownloadMissing`
/// when GitHub has no such file.
typedef Download = Future<void> Function(Uri from, File to);

/// Starts a program that keeps running after SX Studio has closed.
typedef StartDetached = Future<void> Function(String exe, List<String> args);

/// Installs an update in two steps. [download] fetches the release's
/// `release.json`, checks its signature against the release key built in,
/// then downloads the installer it names and checks its size and SHA-256.
/// Once SX Studio has stopped (lights out, the player and the phone listener
/// closed), [launch] starts the installer with the arguments the signed file
/// gives, and the installer opens the new version.
///
/// Port of the `/api/update/install` branch of `df_aim_gui.ps1`. The old one
/// trusted whatever `.exe` the release had and had a PowerShell script wait
/// for it. On the Mac the `.pkg` opens for the user to follow, then the app in
/// Applications opens, as before.
class UpdateInstaller {
  UpdateInstaller({required this.appExe, bool? mac, Download? download, StartDetached? start, String? tempDir, this.publicKey = releasePublicKey})
    : mac = mac ?? Platform.isMacOS,
      _download = download ?? httpSave,
      _start = start ?? _detached,
      _temp = tempDir ?? Directory.systemTemp.path;

  /// The installed app's program (`sx_studio.exe`).
  final String appExe;
  final bool mac;

  /// The release key's public half. Tests use their own.
  final String publicKey;
  final Download _download;
  final StartDetached _start;
  final String _temp;

  /// The checked installer, waiting for SX Studio to stop. Null before
  /// [download] and after [launch].
  String? get ready => _ready?.path;
  ({String path, List<String> args})? _ready;

  /// Downloads and checks [u]'s release. Throws `ToolError`:
  /// - `This update isn't signed by SX Studio. It was not installed.` when
  ///   `release.json` is missing, its signature doesn't check out, or it is
  ///   another version's;
  /// - `No newer version found on GitHub.` when it names no installer for
  ///   this computer;
  /// - `Download failed: ...` when a download fails;
  /// - `The download was damaged. Try again.` when the installer isn't the
  ///   one it names. A damaged file is deleted.
  Future<void> download(UpdateInfo u) async {
    _ready = null;
    final asset = Uri.parse(u.asset);
    final manifestFile = File(p.join(_temp, 'sxh_$manifestName'));
    final sigFile = File(p.join(_temp, 'sxh_$signatureName'));
    try {
      await _download(siblingAsset(asset, manifestName), manifestFile);
      await _download(siblingAsset(asset, signatureName), sigFile);
    } on DownloadMissing {
      throw ToolError(unsignedMessage);
    } on Object catch (err) {
      throw ToolError('Download failed: ${_why(err)}');
    }
    final ReleaseManifest manifest;
    try {
      manifest = await verifyManifest(manifestFile.readAsBytesSync(), sigFile.readAsStringSync(), publicKey: publicKey);
    } on ReleaseError catch (e) {
      throw ToolError(e.message);
    } on FileSystemException {
      throw ToolError(unsignedMessage);
    } finally {
      _delete(manifestFile);
      _delete(sigFile);
    }
    // a signed file from an older release put next to a newer tag
    if (manifest.version != u.latest) throw ToolError(unsignedMessage);
    final entry = manifest.platforms[mac ? 'mac' : 'windows'];
    if (entry == null) throw ToolError('No newer version found on GitHub.');
    final from = siblingAsset(asset, entry.file);
    if (!isGithubDownload(from)) throw ToolError('No newer version found on GitHub.');
    final installer = File(p.join(_temp, safeFileName(entry.file)));
    try {
      await _download(from, installer);
    } on Object catch (err) {
      throw ToolError('Download failed: ${_why(err)}');
    }
    try {
      await checkInstaller(installer, entry);
    } on ReleaseError catch (e) {
      throw ToolError(e.message);
    }
    _ready = (path: installer.path, args: entry.args);
  }

  /// Starts the installer [download] saved, once. Call it after SX Studio
  /// has stopped. Does nothing when there is none.
  Future<void> launch() async {
    final installer = _ready;
    if (installer == null) return;
    _ready = null;
    if (mac) {
      await _start('/bin/bash', ['-c', "open -W ${_sh(installer.path)}; sleep 1; open '/Applications/SX Studio.app'"]);
    } else {
      await _start(installer.path, installer.args);
    }
  }
}

/// [name] with anything but letters, digits, `_`, `.` and `-` made `_`,
/// as the old `-replace '[^\w\.-]', '_'`.
String safeFileName(String name) => name.replaceAll(RegExp(r'[^\w.-]'), '_');

String _why(Object err) => switch (err) {
  HttpException(:final message) => message,
  SocketException(:final message) => message,
  FileSystemException(:final message) => message,
  _ => '$err',
};

void _delete(File f) {
  try {
    if (f.existsSync()) f.deleteSync();
  } on FileSystemException {
    // the temp folder clears itself
  }
}

// A path inside single quotes. A user name can hold an apostrophe.
String _sh(String s) => "'${s.replaceAll("'", r"'\''")}'";

Future<void> _detached(String exe, List<String> args) => Process.start(exe, args, mode: ProcessStartMode.detached);
