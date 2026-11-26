import 'dart:ffi';
import 'dart:io';

import '../player/win32.dart';

/// What the user sees when the driver answers but finds no interface.
/// The hub retries on this one, since the interface can take a moment to be
/// free after ShowXpress closes.
const dmxNotFound =
    'The DMX interface (D512S) was not found. Check its USB cable - unplug it, plug it back in, wait a few seconds - and try again. '
    'ShowXpress must stay closed.';

// ---------------------------------------------------------------- is the interface still plugged in?

final _cfgmgr = DynamicLibrary.open('cfgmgr32.dll');
final _locate = _cfgmgr.lookupFunction<Uint32 Function(Pointer<Uint32>, Pointer<Uint16>, Uint32), int Function(Pointer<Uint32>, Pointer<Uint16>, int)>(
  'CM_Locate_DevNodeW',
);
final _listSize = _cfgmgr.lookupFunction<Uint32 Function(Pointer<Uint32>, Pointer<Uint16>, Uint32), int Function(Pointer<Uint32>, Pointer<Uint16>, int)>(
  'CM_Get_Device_ID_List_SizeW',
);
final _list = _cfgmgr
    .lookupFunction<Uint32 Function(Pointer<Uint16>, Pointer<Uint16>, Uint32, Uint32), int Function(Pointer<Uint16>, Pointer<Uint16>, int, int)>(
      'CM_Get_Device_ID_ListW',
    );
final _regProp = _cfgmgr
    .lookupFunction<
      Uint32 Function(Uint32, Uint32, Pointer<Uint32>, Pointer<Uint16>, Pointer<Uint32>, Uint32),
      int Function(int, int, Pointer<Uint32>, Pointer<Uint16>, Pointer<Uint32>, int)
    >('CM_Get_DevNode_Registry_PropertyW');

/// The interface's Windows device, watched so the player can notice it being
/// unplugged and open it again when it is back.
///
/// Port of the device lookup at the end of `player.ps1` (USB vendor 1069,
/// the D512S family, else a USB device with the interface's name) and of
/// `Present`. The old app found the device with `Get-CimInstance
/// Win32_PnPEntity`. This asks the Configuration Manager directly, which is
/// where that list comes from.
///
/// Not run on real hardware.
class EfkDevice {
  EfkDevice._(this.id);

  /// The device instance id, for example `USB\VID_1069&PID_0001\...`.
  final String id;

  /// The interface's device, or null when it can't be found (then the player
  /// never reports it lost, like the old one).
  static EfkDevice? find(String ifaceName) {
    if (!Platform.isWindows) return null;
    try {
      final ids = _usbDevices();
      final vid = ids.where((d) => d.toUpperCase().startsWith(r'USB\VID_1069&'));
      if (vid.isNotEmpty) return EfkDevice._(vid.first);
      final nm = ifaceName.split('|').first.trim().toLowerCase();
      for (final d in ids) {
        final n = _deviceName(d);
        if (n != null && n.trim().toLowerCase() == nm) return EfkDevice._(d);
      }
    } on Object {
      // no Configuration Manager: don't watch
    }
    return null;
  }

  /// True while Windows has the device.
  bool present() {
    final w = toWide(id), inst = winAlloc<Uint32>(4);
    try {
      return _locate(inst, w, 0) == 0;
    } on Object {
      return true;
    } finally {
      winFree(w);
      winFree(inst);
    }
  }
}

/// Device ids of the USB devices that are plugged in.
List<String> _usbDevices() {
  const filter = 0x1 | 0x100; // CM_GETIDLIST_FILTER_ENUMERATOR | CM_GETIDLIST_FILTER_PRESENT
  final usb = toWide('USB'), len = winAlloc<Uint32>(4);
  try {
    if (_listSize(len, usb, filter) != 0) return const [];
    final n = len.value;
    final buf = winAlloc<Uint16>(n * 2 + 2);
    try {
      if (_list(usb, buf, n, filter) != 0) return const [];
      // a list of zero-terminated strings, ended by an empty one
      final all = String.fromCharCodes(buf.asTypedList(n));
      return all.split('\u0000').where((s) => s.isNotEmpty).toList();
    } finally {
      winFree(buf);
    }
  } finally {
    winFree(usb);
    winFree(len);
  }
}

/// What Device Manager calls the device: its friendly name, else its description.
String? _deviceName(String id) {
  final w = toWide(id), inst = winAlloc<Uint32>(4), buf = winAlloc<Uint16>(1024), len = winAlloc<Uint32>(4);
  try {
    if (_locate(inst, w, 0) != 0) return null;
    for (final prop in [0x0D, 0x01]) {
      // CM_DRP_FRIENDLYNAME, CM_DRP_DEVICEDESC
      len.value = 1024;
      if (_regProp(inst.value, prop, nullptr, buf, len, 0) == 0) return fromWide(buf, max: 511);
    }
    return null;
  } finally {
    winFree(w);
    winFree(inst);
    winFree(buf);
    winFree(len);
  }
}
