import 'dart:convert';
import 'dart:ffi';

// The Mac's own calls, all in the system library every program has loaded.
final _sys = DynamicLibrary.process();
final _malloc = _sys.lookupFunction<Pointer<Void> Function(IntPtr), Pointer<Void> Function(int)>('malloc');
final _free = _sys.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('free');
final _listAllPids = _sys.lookupFunction<Int32 Function(Pointer<Void>, Int32), int Function(Pointer<Void>, int)>('proc_listallpids');
final _pidPath = _sys.lookupFunction<Int32 Function(Int32, Pointer<Void>, Uint32), int Function(int, Pointer<Void>, int)>('proc_pidpath');

/// [bytes] of native memory on a Mac. Free it with [macFree].
Pointer<T> macAlloc<T extends NativeType>(int bytes) {
  final p = _malloc(bytes);
  if (p.address == 0) throw StateError('out of memory');
  return p.cast<T>();
}

void macFree(Pointer<NativeType> p) => _free(p.cast<Void>());

/// The running programs on a Mac, each with its program file's full path,
/// read from the system's process table (libproc).
///
/// The old app asked `ps` for this. Inside the app that took 45 ms on a fast
/// Mac, and the engine asks once a second, so every other call waited behind
/// it. This takes about a millisecond. A process that has finished but is
/// still listed (a zombie) has no path and is left out, as `ps`'s `Z` ones were.
List<({int pid, String exe})> macProcesses() {
  const pathMax = 4096; // PROC_PIDPATHINFO_MAXSIZE
  final room = _listAllPids(nullptr, 0) + 64; // a few may start in between
  if (room <= 64) return const [];
  final pids = macAlloc<Int32>(room * 4), path = macAlloc<Uint8>(pathMax);
  try {
    final n = _listAllPids(pids.cast(), room * 4);
    final found = <({int pid, String exe})>[];
    for (var i = 0; i < n && i < room; i++) {
      final len = _pidPath(pids[i], path.cast(), pathMax);
      if (len > 0) found.add((pid: pids[i], exe: utf8.decode(path.asTypedList(len), allowMalformed: true)));
    }
    return found;
  } finally {
    macFree(pids);
    macFree(path);
  }
}
