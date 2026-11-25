import 'dart:convert';
import 'dart:io';

import 'package:sx_api/sx_api.dart';

import '../show/show_env.dart';

/// A USB or other device Windows lists as present and working.
typedef PnpDevice = ({String name, String instanceId, String manufacturer});

/// The charger and battery, as Windows reports them.
typedef PowerInfo = ({String line, int percent, bool hasBattery});

/// What the Pre-show Check asks the laptop. Everything here comes from the
/// operating system, so the show-file checks stay testable without it.
class LaptopFacts {
  const LaptopFacts({
    this.devices = const [],
    this.tcpPorts = const [],
    this.virtualDj = false,
    this.power,
    this.sleepAc,
    this.usbSuspendAc,
    this.rebootPending = false,
  });

  /// Present devices with status OK (`Get-PnpDevice -PresentOnly`).
  final List<PnpDevice> devices;

  /// Local ports of established TCP connections (`Get-NetTCPConnection`).
  final List<int> tcpPorts;

  /// A `virtualdj*` process is running.
  final bool virtualDj;

  /// Null when Windows did not say.
  final PowerInfo? power;

  /// Seconds before the laptop sleeps on the charger (0 = never), or null
  /// when powercfg did not say.
  final int? sleepAc;

  /// USB selective suspend on the charger: 1 on, 0 off, null unknown.
  final int? usbSuspendAc;

  /// Windows Update or servicing wants a restart.
  final bool rebootPending;
}

/// The three things the Pre-show Check may change on the laptop.
enum LaptopFix { sleep, usb, restart }

/// The operating system, as far as the Pre-show Check needs it.
///
/// [WindowsLaptop] on Windows. Anywhere else [OtherLaptop], which says the
/// laptop checks only run on Windows, like the old app did on the Mac.
abstract class Laptop {
  /// The right one for this computer.
  factory Laptop() => Platform.isWindows ? WindowsLaptop() : const OtherLaptop();

  /// False where the controller, interface and laptop checks can't run.
  bool get windows;

  /// Asks Windows about devices, power and updates. Only called when [windows].
  LaptopFacts facts();

  /// Changes one power setting, or restarts Windows in one minute. Returns
  /// the report line. Refuses with `ToolError` when Windows says no.
  String fix(LaptopFix f);
}

/// Not Windows: the laptop checks don't run.
class OtherLaptop implements Laptop {
  const OtherLaptop();

  @override
  bool get windows => false;

  @override
  LaptopFacts facts() => const LaptopFacts();

  @override
  String fix(LaptopFix f) => throw ToolError('Only on Windows. NOTHING was changed.');
}

/// Asks Windows through one fixed PowerShell command. Nothing the user typed
/// goes into it.
class WindowsLaptop implements Laptop {
  WindowsLaptop();

  @override
  bool get windows => true;

  static const _usbGroup = '2a737441-1930-4402-8d77-b2bebba308a3';
  static const _usbSetting = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226';

  /// Prints one line of JSON with everything [facts] needs.
  static const _query = r'''
$ErrorActionPreference = 'SilentlyContinue'
$pnp = @(Get-PnpDevice -PresentOnly | Where-Object { $_.Status -eq 'OK' } | ForEach-Object { @{ n = "$($_.FriendlyName)"; i = "$($_.InstanceId)"; m = "$($_.Manufacturer)" } })
$tcp = @(Get-NetTCPConnection -State Established | ForEach-Object { [int]$_.LocalPort })
$vdj = [bool](Get-Process -Name 'virtualdj*')
Add-Type -AssemblyName System.Windows.Forms
$ps = [Windows.Forms.SystemInformation]::PowerStatus
function Get-AcIndex($sub, $set) {
  $o = & powercfg /q SCHEME_CURRENT $sub $set 2>$null | Out-String
  if ($o -match 'Current AC Power Setting Index:\s*0x([0-9a-fA-F]+)') { [Convert]::ToInt32($matches[1], 16) } else { $null }
}
$rb = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
@{ pnp = $pnp; tcp = $tcp; vdj = $vdj; line = "$($ps.PowerLineStatus)"; pct = [int]($ps.BatteryLifePercent * 100)
   battery = ("$($ps.BatteryChargeStatus)" -notmatch 'NoSystemBattery'); sleep = (Get-AcIndex 'SUB_SLEEP' 'STANDBYIDLE')
   usb = (Get-AcIndex '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'); reboot = $rb } | ConvertTo-Json -Depth 4 -Compress
''';

  @override
  LaptopFacts facts() {
    final r = Process.runSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', _query], stdoutEncoding: utf8);
    final line = const LineSplitter().convert('${r.stdout}').lastWhere((l) => l.startsWith('{'), orElse: () => '');
    if (line.isEmpty) return const LaptopFacts();
    final Json j;
    try {
      j = (jsonDecode(line) as Map).cast<String, Object?>();
    } on FormatException {
      return const LaptopFacts();
    }
    return LaptopFacts(
      devices: [for (final d in j.list('pnp', (d) => d)) (name: d.str('n'), instanceId: d.str('i'), manufacturer: d.str('m'))],
      tcpPorts: j.intList('tcp'),
      virtualDj: j.boolean('vdj'),
      power: (line: j.str('line'), percent: j.integer('pct'), hasBattery: j.boolean('battery')),
      sleepAc: j.integerOrNull('sleep'),
      usbSuspendAc: j.integerOrNull('usb'),
      rebootPending: j.boolean('reboot'),
    );
  }

  void _powercfg(List<String> args) {
    final r = Process.runSync('powercfg', args);
    if (r.exitCode != 0) throw ToolError('Windows said: ${'${r.stdout}${r.stderr}'.trim()} - NOTHING was changed.');
  }

  @override
  String fix(LaptopFix f) {
    switch (f) {
      case LaptopFix.sleep:
        _powercfg(['/change', 'standby-timeout-ac', '0']);
        return '  CHANGED  the laptop never goes to sleep on the charger now';
      case LaptopFix.usb:
        _powercfg(['/setacvalueindex', 'SCHEME_CURRENT', _usbGroup, _usbSetting, '0']);
        _powercfg(['/setactive', 'SCHEME_CURRENT']);
        return '  CHANGED  USB power saving (selective suspend) is off on the charger';
      case LaptopFix.restart:
        Process.runSync('shutdown.exe', ['/r', '/t', '60', '/c', 'SX Studio: restarting for Windows updates in 1 minute. Save your work.']);
        return "  CHANGED  Windows restarts in 1 minute (cancel: run 'shutdown /a')";
    }
  }
}
