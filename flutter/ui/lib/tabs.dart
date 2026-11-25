import 'package:flutter/widgets.dart';

import 'screens/home/home_screen.dart';
import 'screens/move/move_screen.dart';
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
  TabDef('rt', 'Rig Test', TabGroup.gig, 'Which mover hangs where', _todo),
  TabDef('aim', 'Aim Movers', TabGroup.gig, "Fit the dance floor and AROUND ROOM to tonight's venue", _todo),
  TabDef('color', "Tonight's Color", TabGroup.gig, 'The decor color on the movers and uplights', _todo),
  TabDef('pre', 'Pre-show Check', TabGroup.gig, 'One look before the guests arrive', _todo),
  TabDef('lab', 'SX Player', TabGroup.live, 'Play the show without ShowXpress', _todo),
  TabDef('auto', 'Auto Show', TabGroup.live, 'Your looks change every few bars while you mix', _todo),
  TabDef('rig', "Tonight's Rig", TabGroup.rig, 'Which movers are hung tonight', _todo),
  TabDef('skip', 'Skip Flash', TabGroup.rig, 'Which heads the flash skips', _todo),
  TabDef('apc', 'APC mini', TabGroup.rig, 'Pads and their lights', _todo),
  TabDef('speed', 'Speed Faders', TabGroup.rig, 'Which master fader each button follows', SpeedScreen.new),
  TabDef('scene', 'Scene Editor', TabGroup.edit, 'Edit step scenes', _todo),
  TabDef('move', 'Movement Editor', TabGroup.edit, 'Edit generator movements', MoveScreen.new),
  TabDef('look', 'Looks', TabGroup.edit, 'Make color looks for the whole rig', _todo),
  TabDef('health', 'Health Check', TabGroup.edit, 'Find problems in the show', _todo),
];

/// Builds the screen for a tab id. `home` and `settings` are not in [tabs].
Widget buildTab(BuildContext context, String id) {
  if (id == 'home') return const HomeScreen();
  if (id == 'settings') return _todo(context);
  for (final t in tabs) {
    if (t.id == id) return t.build(context);
  }
  return _todo(context);
}
