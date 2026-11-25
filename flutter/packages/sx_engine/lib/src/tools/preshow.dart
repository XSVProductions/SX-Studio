import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sx_api/sx_api.dart';

import '../ps_compat.dart';
import '../show/live_ini.dart';
import '../show/movers.dart';
import '../show/show_env.dart';
import '../show/text_files.dart';
import '../system/laptop.dart';

// PRE-SHOW CHECK: one look before the guests arrive. Reads only.
//   Show:    ShowXpress open, DMX output on, Rig Test saved today, Tonight's
//            Rig matches it, movers aimed today
//   Gear:    APC mini plugged in, DMX interface plugged in, VirtualDJ beat
//            link (OS2L) connected
//   Laptop:  on charger, never sleeps on charger, USB power saving off, no
//            Windows restart waiting
// Gear and Laptop come from [Laptop] and only run on Windows.
//
// Port of `preshow.ps1`.

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

/// "today at 6:05 PM", "yesterday", "3 days ago (Nov 22)". US English, like
/// the old tool on an English Windows.
String preAgo(DateTime t, DateTime now) {
  final d = _day(now).difference(_day(t)).inHours ~/ 24;
  if (d <= 0) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return 'today at $h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  }
  if (d == 1) return 'yesterday';
  return '$d days ago (${_months[t.month - 1]} ${t.day})';
}

/// A JSON file of the show, or null when it isn't there. A broken file
/// throws, as it did in the old tool.
Json? _json(ShowEnv env, String name) {
  final f = env.file(name);
  if (!f.existsSync()) return null;
  try {
    final j = jsonDecode(readText(f.path));
    return j is Map ? j.cast<String, Object?>() : const {};
  } on FormatException {
    throw ToolError("$name in the show folder can't be read.");
  }
}

/// The Pre-show Check. Writes nothing.
PreReport preshowCheck(ShowEnv env, Laptop laptop) {
  final items = <PreItem>[];
  void add(String group, String level, String title, [String detail = '', String advice = '', String? fix, String fixLabel = '']) => items.add(
    PreItem(
      group: group,
      level: level,
      title: title,
      detail: detail,
      advice: advice,
      fix: fix != null && level != 'ok' ? PreFix(key: fix, label: fixLabel) : null,
    ),
  );
  final now = env.now();
  final today = _day(now);

  // ---- Show
  final sxOpen = env.sxRunning();
  if (sxOpen) {
    add('Show', 'ok', 'ShowXpress is open');
  } else {
    add(
      'Show',
      'warn',
      'ShowXpress is not open yet',
      'Some checks below use the last saved show.',
      'Open ShowXpress and load the Awaaz show.',
      'launch',
      'Launch ShowXpress',
    );
  }

  final live = LiveIni.read(env).keys('live');
  if (psEq(live['dmx_on'] ?? '', 'no')) {
    add('Show', 'error', 'DMX output is switched OFF in Live', 'No light will react to anything.', 'In ShowXpress Live, switch DMX output back on.');
  } else {
    add('Show', 'ok', 'DMX output is on in Live', sxOpen ? 'As last saved - ShowXpress is open, so a change made since then would not show here.' : '');
  }

  const rtAdvice = 'Press RIG ID on the SETUP page and do the Rig Test tab.';
  List<String>? rtHung;
  final rt = _json(env, 'rig_test.json');
  if (rt != null) {
    final t = DateTime.tryParse(rt.str('saved'))?.toLocal();
    if (t == null) throw ToolError("rig_test.json in the show folder can't be read.");
    rtHung = rt.strList('hung');
    if (_day(t) == today) {
      add('Show', 'ok', 'Rig Test saved ${preAgo(t, now)}', '${rtHung.length} movers placed on the trusses.');
    } else {
      add(
        'Show',
        'warn',
        'Rig Test last saved ${preAgo(t, now)}',
        'The 2D view may not match where the heads hang tonight.',
        rtAdvice,
        'tab:rt',
        'Open Rig Test',
      );
    }
  } else {
    add('Show', 'warn', 'Rig Test not done yet', '', rtAdvice, 'tab:rt', 'Open Rig Test');
  }

  final rigHung = _json(env, 'rig_state.json')?.strList('hung');
  if (rtHung != null && rtHung.isNotEmpty) {
    bool has(List<String> ids, String id) => ids.any((x) => psEq(x, id));
    final m140 = showMovers(env).where((m) => m.is140).toList();
    final rig140 = rigHung != null && rigHung.isNotEmpty ? m140.where((m) => has(rigHung, m.id)).toList() : m140;
    final rigIds = [for (final m in rig140) m.id];
    final diff = m140.where((m) => has(rtHung!, m.id) != has(rigIds, m.id)).toList();
    if (diff.isNotEmpty) {
      add(
        'Show',
        'warn',
        "Tonight's Rig doesn't match the Rig Test",
        'Different: ${diff.map((m) => '140 #${m.num}').join(', ')}.',
        "Save the Rig Test again with 'Also update Tonight's Rig' ticked, or fix it in the Tonight's Rig tab.",
        'tab:rig',
        "Open Tonight's Rig",
      );
    } else {
      add('Show', 'ok', "Tonight's Rig matches the Rig Test", '${rig140.length} of ${m140.length} 140s hung.');
    }
  }

  const aimAdvice = "Aim DF AIM (ADJUST) at tonight's floor, then Apply in the Aim Movers tab.";
  final aim = env.file('df_aim_state.json');
  if (aim.existsSync()) {
    final t = aim.lastModifiedSync();
    if (_day(t) == today) {
      add('Show', 'ok', 'Movers aimed ${preAgo(t, now)}');
    } else {
      add(
        'Show',
        'warn',
        'Movers last aimed ${preAgo(t, now)}',
        "Every venue is different - the movements may miss tonight's dancefloor.",
        aimAdvice,
        'tab:aim',
        'Open Aim Movers',
      );
    }
  } else {
    add('Show', 'warn', 'Movers not aimed yet', '', aimAdvice, 'tab:aim', 'Open Aim Movers');
  }

  // ---- Gear and Laptop (Windows only)
  if (!laptop.windows) {
    add('Gear', 'info', 'Controller, DMX interface and laptop checks only run on Windows');
    return PreReport(show: env.root, items: items);
  }
  final f = laptop.facts();
  if (f.devices.any((d) => RegExp('APC mini', caseSensitive: false).hasMatch(d.name))) {
    add('Gear', 'ok', 'APC mini is plugged in');
  } else {
    add(
      'Gear',
      'error',
      'APC mini not found',
      "The pads and speed faders won't work.",
      'Plug in the APC mini (try another USB port), then restart ShowXpress so it picks it up.',
    );
  }

  final dmxName = RegExp('D512|DMX|Nicolaudie|Sunlite|Chauvet|ShowXpress|Enttec|USB Serial Converter|FT232', caseSensitive: false);
  final dmxMaker = RegExp('EFK|Nicolaudie|Sunlite|Chauvet|FTDI|Enttec', caseSensitive: false);
  final dmx = f.devices
      .where((d) => RegExp('VID_1069', caseSensitive: false).hasMatch(d.instanceId) || dmxName.hasMatch(d.name) || dmxMaker.hasMatch(d.manufacturer))
      .toList();
  if (dmx.isNotEmpty) {
    add('Gear', 'ok', 'DMX interface is plugged in', dmx.map((d) => d.name).toSet().join(', '));
  } else {
    add(
      'Gear',
      'error',
      'No DMX interface found',
      'Without it no light gets any signal.',
      'Plug in the DMX interface and check the DMX cable to the first light. If it is plugged in and this still shows, tell me what it is called in Device Manager.',
    );
  }

  // ShowXpress's own settings sit two folders above the show.
  final os2l = psMap<String>();
  final paramIni = p.join(p.dirname(p.dirname(env.root)), 'param.ini');
  if (File(paramIni).existsSync()) {
    final rx = RegExp(r'^(OS2L\w+) = (.*)$', caseSensitive: false);
    for (final l in readLines(paramIni)) {
      final m = rx.firstMatch(l);
      if (m != null) os2l[m[1]!] = m[2]!.trim();
    }
  }
  final port = (os2l['OS2LPORT'] ?? '').isNotEmpty ? psInt(os2l['OS2LPORT']) : 7350;
  if (!psEq(os2l['OS2LENABLE'] ?? '', 'yes')) {
    add(
      'Gear',
      'info',
      'VirtualDJ beat link is off in ShowXpress',
      'Beat scenes follow the BPM / audio beat instead.',
      'To use it: ShowXpress Preferences > Network > Virtual DJ: Enable.',
    );
  } else if (f.tcpPorts.contains(port)) {
    add('Gear', 'ok', 'VirtualDJ is connected (beat link)');
  } else if (f.virtualDj) {
    add(
      'Gear',
      'warn',
      'VirtualDJ is running but not connected to ShowXpress',
      "Beat scenes won't follow the music from VirtualDJ.",
      'Restart VirtualDJ after ShowXpress is open, and make sure both are on the same network.',
    );
  } else {
    add(
      'Gear',
      'info',
      'VirtualDJ is not connected',
      "Fine if VirtualDJ runs on the other laptop and isn't open yet, or you're using the BPM / audio beat.",
      'Open VirtualDJ after ShowXpress - it connects by itself.',
    );
  }

  final pw = f.power;
  if (pw != null && psEq(pw.line, 'Online')) {
    add('Laptop', 'ok', 'On the charger', pw.hasBattery ? 'Battery ${pw.percent}%.' : '');
  } else if (pw != null && psEq(pw.line, 'Offline')) {
    add('Laptop', 'error', 'Running on battery (${pw.percent}%)', 'The laptop could die or slow down mid-show.', 'Plug in the charger.');
  }

  final sleep = f.sleepAc;
  if (sleep == 0) {
    add('Laptop', 'ok', 'Never sleeps on the charger');
  } else if (sleep != null) {
    add(
      'Laptop',
      'warn',
      'Goes to sleep after ${psRound(sleep / 60)} min on the charger',
      'If nobody touches it (dinner, speeches) the lights freeze.',
      'Settings > System > Power & sleep > "When plugged in, PC goes to sleep after" = Never.',
      'sleep',
      'Never sleep on charger',
    );
  }
  if (f.usbSuspendAc == 1) {
    add(
      'Laptop',
      'warn',
      'USB power saving is on',
      'Windows can switch off an idle USB port - the DMX interface or APC can drop out.',
      'Control Panel > Power Options > Change plan settings > Change advanced power settings > USB settings > USB selective suspend > Plugged in: Disabled.',
      'usb',
      'Turn USB power saving off',
    );
  } else if (f.usbSuspendAc == 0) {
    add('Laptop', 'ok', 'USB power saving is off');
  }

  if (f.rebootPending) {
    add(
      'Laptop',
      'warn',
      'Windows wants to restart for updates',
      'It could restart by itself during the event.',
      'Restart the laptop now, before the show.',
      'restart',
      'Restart now',
    );
  } else {
    add('Laptop', 'ok', 'No Windows restart waiting');
  }
  return PreReport(show: env.root, items: items);
}

/// Applies one of the laptop fixes: `sleep`, `usb` or `restart`. Returns the report text.
String preshowFix(Laptop laptop, String fixId) {
  if (!laptop.windows) throw ToolError('Only on Windows. NOTHING was changed.');
  final f = LaptopFix.values.where((x) => psEq(x.name, fixId)).firstOrNull;
  if (f == null) throw ToolError("Unknown fix '$fixId'. NOTHING was changed.");
  return laptop.fix(f);
}
