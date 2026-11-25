import 'dart:io';

// NovaStar NovaLCT (LED screens) has a USB scanner, MarsServerProvider, that
// grabs the DMX interface. The old server pauses it only when the user says
// so, on `/api/live/start` and `/api/lab/start`. Windows only.

/// Whether NovaLCT's USB scanner is running.
Future<bool> novaRunning() async {
  try {
    final r = await Process.run('tasklist', ['/FI', 'IMAGENAME eq MarsServerProvider.exe', '/NH']);
    return '${r.stdout}'.toLowerCase().contains('marsserverprovider');
  } on ProcessException {
    return false;
  }
}

/// Pauses NovaLCT's USB scanner and waits for it to let go of the interface.
/// NovaLCT starts it again by itself.
Future<void> pauseNova() async {
  try {
    await Process.run('taskkill', ['/F', '/IM', 'MarsServerProvider.exe']);
  } on ProcessException {
    // not there
  }
  await Future<void>.delayed(const Duration(milliseconds: 800));
}
