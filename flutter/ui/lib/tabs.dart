import 'package:flutter/widgets.dart';

import 'screens/auto/auto_screen.dart';
import 'screens/color/color_screen.dart';
import 'screens/aim/aim_screen.dart';
import 'screens/home/home_screen.dart';
import 'screens/lab/lab_screen.dart';
import 'screens/look/look_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'screens/apc/apc_screen.dart';
import 'screens/apc40/apc40_screen.dart';
import 'screens/health/health_screen.dart';
import 'screens/pre/pre_screen.dart';
import 'screens/scene/scene_screen.dart';
import 'screens/move/move_screen.dart';
import 'screens/rig/rig_screen.dart';
import 'screens/rt/rt_screen.dart';
import 'screens/skip/skip_screen.dart';
import 'screens/speed/speed_screen.dart';

/// The groups the tab bar and the Home screen sort tabs into.
enum TabGroup {
  gig('Before the gig'),
  live('Live'),
  rig('Rig & Control'),
  edit('Editors');

  const TabGroup(this.title);

  final String title;
}

/// One tab: its id (the old app's ids, kept so settings carry over), its
/// name and the screen it opens.
class TabDef {
  const TabDef(this.id, this.name, this.group, this.build);

  final String id;
  final String name;
  final TabGroup group;
  final WidgetBuilder build;
}

/// Every tab, in the old app's order.
const tabs = [
  TabDef('rt', 'Rig Test', TabGroup.gig, RtScreen.new),
  TabDef('aim', 'Aim Movers', TabGroup.gig, AimScreen.new),
  TabDef('color', "Tonight's Color", TabGroup.gig, ColorScreen.new),
  TabDef('pre', 'Pre-show Check', TabGroup.gig, PreScreen.new),
  TabDef('lab', 'SX Player', TabGroup.live, LabScreen.new),
  TabDef('auto', 'Auto Show', TabGroup.live, AutoScreen.new),
  TabDef('rig', "Tonight's Rig", TabGroup.rig, RigScreen.new),
  TabDef('skip', 'Skip Flash', TabGroup.rig, SkipScreen.new),
  TabDef('apc', 'APC mini', TabGroup.rig, ApcScreen.new),
  TabDef('apc40', 'APC40', TabGroup.rig, Apc40Screen.new),
  TabDef('speed', 'Speed Faders', TabGroup.rig, SpeedScreen.new),
  TabDef('scene', 'Scene Editor', TabGroup.edit, SceneScreen.new),
  TabDef('move', 'Movement Editor', TabGroup.edit, MoveScreen.new),
  TabDef('look', 'Looks', TabGroup.edit, LookScreen.new),
  TabDef('health', 'Health Check', TabGroup.edit, HealthScreen.new),
];

/// True for a tab the app has: one of [tabs], `home` or `settings`.
bool knownTab(String id) => id == 'home' || id == 'settings' || tabs.any((t) => t.id == id);

/// Builds the screen for a tab id. `home` and `settings` are not in [tabs].
/// An unknown id gets Home, as the old `setTab` did.
Widget buildTab(BuildContext context, String id) {
  if (id == 'settings') return const SettingsScreen();
  for (final t in tabs) {
    if (t.id == id) return t.build(context);
  }
  return const HomeScreen();
}
