"""Checks the reference detector on the made-up tracks. Run: python3 test_detector.py"""

import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import detector as det  # noqa: E402
import synth_edm  # noqa: E402

FS = 44100


def times(d, kind):
    return [e.t for e in d.events if e.kind == kind]


def near(a, b, tol):
    return abs(a - b) <= tol


def beats_after(d, t0):
    return [e for e in d.events if e.kind == 'beat' and e.t > t0]


def check(name, ok, msg=''):
    print(('ok    ' if ok else 'FAIL  ') + name + ('' if ok else '  ' + msg))
    return ok


def main():
    good = True
    y, tr = synth_edm.main_track(FS)
    d = det.run(y, FS)
    dr = times(d, 'drop')
    good &= check('main: one drop, on time', len(dr) == 1 and near(dr[0], tr.drops[0], 0.05), str(dr))
    rt = times(d, 'return')
    good &= check('main: the break without a build ends in a return', len(rt) == 1 and near(rt[0], tr.returns[0], 0.1), str(rt))
    gp = times(d, 'gap')
    good &= check('main: the gap before the drop', len(gp) == 1 and tr.gaps[0][0] - 0.05 <= gp[0] <= tr.gaps[0][1], str(gp))
    st = [(e.t, e.extra) for e in d.events if e.kind == 'state']
    bu = [t for t, s in st if s == det.BUILD]
    good &= check('main: build starts in the build', len(bu) == 1 and tr.builds[0][0] <= bu[0] <= tr.builds[0][0] + 4, str(st))
    bpm = np.median([e.value for e in beats_after(d, 8)])
    good &= check('main: tempo', near(bpm, 128.0, 0.3), f'{bpm}')
    down = [e for e in beats_after(d, tr.drops[0] - 0.05) if abs(((e.t - tr.drops[0] + 0.2) % (4 * 60 / 128)) - 0.2) < 0.06]
    good &= check('main: bar 1 on the downbeats after the drop', all(e.extra == '1' for e in down) and len(down) > 20)
    y2 = y * 0.05
    d2 = det.run(y2, FS)
    good &= check('main at -26 dB: same drop', [round(t, 2) for t in times(d2, 'drop')] == [round(t, 2) for t in dr])

    y, tr = synth_edm.steady_track(FS)
    d = det.run(y, FS)
    good &= check('steady: no drop, no build', not times(d, 'drop') and not any(e.extra == det.BUILD for e in d.events if e.kind == 'state'))
    k = times(d, 'kick')
    hits = sum(1 for t in tr.kicks if any(abs(t - x) < 0.03 for x in k))
    good &= check('steady: kicks found within 30 ms', hits >= 0.97 * len(tr.kicks) and len(k) <= 1.03 * len(tr.kicks), f'{hits}/{len(tr.kicks)}, {len(k)} found')
    per = 60 / 124
    errs = [abs(((e.t - tr.kicks[0] + per / 2) % per) - per / 2) for e in beats_after(d, 8)]
    good &= check('steady: beat clock within 15 ms', np.percentile(errs, 95) < 0.015, f'{np.percentile(errs, 95)}')

    y, tr = synth_edm.halftime_track(FS)
    d = det.run(y, FS)
    dr = times(d, 'drop')
    good &= check('half-time: drop on time', len(dr) == 1 and near(dr[0], tr.drops[0], 0.05), str(dr))
    bpm = np.median([e.value for e in beats_after(d, tr.drops[0])])
    good &= check('half-time: tempo stays 140, not 70 or 93', near(bpm, 140.0, 0.5), f'{bpm}')

    y, tr = synth_edm.mix_track(FS)
    d = det.run(y, FS)
    late = [e.value for e in beats_after(d, 95)]
    good &= check('mix: follows the new track to 124', near(np.median(late), 124.0, 0.3) and min(late) > 123.0, f'{np.median(late)} {min(late)}')
    print('all good' if good else 'SOME FAILED')
    return 0 if good else 1


if __name__ == '__main__':
    sys.exit(main())
