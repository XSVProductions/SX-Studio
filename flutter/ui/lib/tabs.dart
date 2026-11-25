import 'package:flutter/widgets.dart';

import 'screens/color/color_screen.dart';
import 'screens/aim/aim_screen.dart';
import 'screens/home/home_screen.dart';
import 'screens/lab/lab_screen.dart';
import 'screens/look/look_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'screens/apc/apc_screen.dart';
import 'screens/health/health_screen.dart';
import 'screens/pre/pre_screen.dart';
import 'screens/scene/scene_screen.dart';
import 'screens/move/move_screen.dart';
import 'screens/rig/rig_screen.dart';
import 'screens/rt/rt_screen.dart';
import 'screens/skip/skip_screen.dart';
import 'screens/speed/speed_screen.dart';
import 'widgets/sx_widgets.dart';
import 'theme.dart';

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
/// name, what Home says about it, and the screen it opens.
class TabDef {
  const TabDef(this.id, this.name, this.group, this.blurb, this.build);

  final String id;
  final String name;
  final TabGroup group;
  final String blurb;
  final WidgetBuilder build;
}

Widget _todo(BuildContext context) => ScreenBody(
  children: [SxCard(child: Text('Not ported yet.', style: Sx.sub))],
);

/// Every tab, in the old app's order. A screen replaces its `_todo` here.
const tabs = [
  TabDef('rt', 'Rig Test', TabGroup.gig, 'Which mover hangs where', RtScreen.new),
  TabDef('aim', 'Aim Movers', TabGroup.gig, "Fit the dance floor and AROUND ROOM to tonight's venue", AimScreen.new),
  TabDef('color', "Tonight's Color", TabGroup.gig, 'The decor color on the movers and uplights', ColorScreen.new),
  TabDef('pre', 'Pre-show Check', TabGroup.gig, 'One look before the guests arrive', PreScreen.new),
  TabDef('lab', 'SX Player', TabGroup.live, 'Play the show without ShowXpress', LabScreen.new),
  TabDef('auto', 'Auto Show', TabGroup.live, 'Your looks change every few bars while you mix', _todo),
  TabDef('rig', "Tonight's Rig", TabGroup.rig, 'Which movers are hung tonight', RigScreen.new),
  TabDef('skip', 'Skip Flash', TabGroup.rig, 'Which heads the flash skips', SkipScreen.new),
  TabDef('apc', 'APC mini', TabGroup.rig, 'Pads and their lights', ApcScreen.new),
  TabDef('speed', 'Speed Faders', TabGroup.rig, 'Which master fader each button follows', SpeedScreen.new),
  TabDef('scene', 'Scene Editor', TabGroup.edit, 'Edit step scenes', SceneScreen.new),
  TabDef('move', 'Movement Editor', TabGroup.edit, 'Edit generator movements', MoveScreen.new),
  TabDef('look', 'Looks', TabGroup.edit, 'Make color looks for the whole rig', LookScreen.new),
  TabDef('health', 'Health Check', TabGroup.edit, 'Find problems in the show', HealthScreen.new),
];

/// Builds the screen for a tab id. `home` and `settings` are not in [tabs].
Widget buildTab(BuildContext context, String id) {
  if (id == 'home') return const HomeScreen();
  if (id == 'settings') return const SettingsScreen();
  for (final t in tabs) {
    if (t.id == id) return t.build(context);
  }
  return _todo(context);
}
