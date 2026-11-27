"""Runs the music detector over a recording and shows what it found.

    python3 analyze.py set.wav                  # any format ffmpeg reads
    python3 analyze.py set.mp3 --from 600 --to 900
    python3 analyze.py --synth main             # a made-up track with known answers

Writes <name>_timeline.png (levels, sections, build level, hits) and
<name>_events.csv next to the recording, and prints a summary. With --synth
it also scores the result against the known answers.
"""

from __future__ import annotations

import argparse
import csv
import os
import subprocess
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import detector as det  # noqa: E402
import synth_edm  # noqa: E402

FS = 44100


def load(path: str, t0: float | None, t1: float | None) -> np.ndarray:
    cmd = ['ffmpeg', '-v', 'error']
    if t0:
        cmd += ['-ss', str(t0)]
    cmd += ['-i', path]
    if t1:
        cmd += ['-t', str(t1 - (t0 or 0))]
    cmd += ['-ac', '1', '-ar', str(FS), '-f', 'f32le', '-']
    raw = subprocess.run(cmd, check=True, capture_output=True).stdout
    return np.frombuffer(raw, dtype='<f4').astype(np.float64)


def match(found: list[float], truth: list[float], tol: float) -> tuple[int, int, int]:
    """Greedy one-to-one matching. Returns (hits, misses, extras)."""
    f = sorted(found)
    used = [False] * len(f)
    hits = 0
    j0 = 0
    for t in sorted(truth):
        while j0 < len(f) and f[j0] < t - tol:
            j0 += 1
        j = j0
        while j < len(f) and f[j] <= t + tol:
            if not used[j]:
                used[j] = True
                hits += 1
                break
            j += 1
    return hits, len(truth) - hits, len(f) - hits


def score(d: det.Detector, truth: synth_edm.Truth) -> dict:
    ev = d.events
    kicks = [e.t for e in ev if e.kind == 'kick']
    snares = [e.t for e in ev if e.kind == 'snare']
    beats = [e for e in ev if e.kind == 'beat']
    drops = [e.t for e in ev if e.kind == 'drop']
    rets = [e.t for e in ev if e.kind == 'return']
    gaps = [e.t for e in ev if e.kind == 'gap']
    out = {}
    for name, f, tr in (('kick', kicks, truth.kicks), ('snare', snares, truth.snares)):
        h, m, x = match(f, tr, 0.05)
        p = h / max(1, h + x)
        r = h / max(1, h + m)
        out[name] = f'F {2 * p * r / max(1e-9, p + r):.2f} (hit {h}, missed {m}, extra {x})'
    # beat clock against the kick grid, after it locked (skip first 8 s)
    late = [e for e in beats if e.t > 8.0]
    if late:
        grid0 = truth.kicks[0]
        per = 60.0 / truth.bpm
        errs = [((e.t - grid0 + per / 2) % per) - per / 2 for e in late]
        out['beat'] = f'{len(late)} beats, timing error median {1000 * np.median(np.abs(errs)):.1f} ms, 95% {1000 * np.percentile(np.abs(errs), 95):.1f} ms'
        bpms = [e.value for e in late]
        out['bpm'] = f'true {truth.bpm}, found median {np.median(bpms):.2f} (min {min(bpms):.1f}, max {max(bpms):.1f})'
        # bar 1 should land on the drop's beat: check beats at true downbeats after the first drop
        if truth.drops:
            d0 = truth.drops[0]
            down = [e for e in late if e.t > d0 - 0.05 and abs(((e.t - d0 + per / 2) % (4 * per)) - per / 2) < 0.06]
            ok = sum(1 for e in down if e.extra == '1')
            out['bar 1'] = f'{ok} of {len(down)} downbeats after the drop called beat 1'
    tol = 0.25
    h, m, x = match(drops, truth.drops, tol)
    out['drop'] = f'found {[round(t, 2) for t in drops]} vs true {[round(t, 2) for t in truth.drops]} (hit {h}, missed {m}, false {x})'
    h, m, x = match(rets, truth.returns, tol)
    out['return'] = f'found {[round(t, 2) for t in rets]} vs true {[round(t, 2) for t in truth.returns]}'
    out['gap'] = f'found {[round(t, 2) for t in gaps]} vs true {[(round(a, 2), round(b, 2)) for a, b in truth.gaps]}'
    st = [(e.t, e.extra) for e in ev if e.kind == 'state']
    out['sections'] = ', '.join(f'{t:.1f}s {s}' for t, s in st)
    out['true sections'] = f'breaks {[(round(a, 1), round(b, 1)) for a, b in truth.breaks]}, builds {[(round(a, 1), round(b, 1)) for a, b in truth.builds]}'
    return out


def picture(d: det.Detector, path: str, title: str, t_off: float = 0.0):
    import matplotlib

    matplotlib.use('Agg')
    import matplotlib.pyplot as plt

    L = d.log
    t = np.array([r[0] for r in L]) + t_off
    low = np.array([r[1] for r in L])
    mid = np.array([r[2] for r in L])
    high = np.array([r[3] for r in L])
    build = np.array([r[5] for r in L])
    bpm = np.array([r[6] for r in L])
    ref = np.array([r[7] for r in L])
    states = [r[4] for r in L]
    col = {det.GROOVE: '#2b2f3a', det.BREAK: '#3d6fb5', det.BUILD: '#e0a020', det.DROP: '#d9334a'}

    fig, ax = plt.subplots(4, 1, figsize=(16, 9), sharex=True, gridspec_kw={'height_ratios': [3, 1.2, 1.4, 1]})
    fig.patch.set_facecolor('#0e1014')
    for a in ax:
        a.set_facecolor('#12151b')
        a.tick_params(colors='#aeb6c4')
        for s in a.spines.values():
            s.set_color('#262b36')
    # section bands
    i0 = 0
    for i in range(1, len(states) + 1):
        if i == len(states) or states[i] != states[i0]:
            for a in ax[:3]:
                a.axvspan(t[i0], t[i - 1], color=col[states[i0]], alpha=0.35 if states[i0] != det.GROOVE else 0.0, lw=0)
            i0 = i
    sm = lambda v: np.convolve(v, np.ones(15) / 15, 'same')  # noqa: E731
    ax[0].plot(t, sm(low), color='#ff9d00', lw=0.8, label='low (kick, bass)')
    ax[0].plot(t, sm(mid), color='#3ddc84', lw=0.8, label='mid (snare, clap)')
    ax[0].plot(t, sm(high), color='#5aa9ff', lw=0.8, label='high (hats, risers)')
    ax[0].plot(t, ref, color='#ffffff', lw=0.6, ls='--', label='groove level')
    ax[0].set_ylim(max(-90, np.percentile(low, 1) - 5), max(low.max(), mid.max()) + 5)
    ax[0].set_ylabel('dB', color='#aeb6c4')
    ax[0].legend(loc='lower left', fontsize=8, facecolor='#12151b', labelcolor='#c7cdd8', ncol=4)
    ev = d.events
    for kind, y, c in (('kick', 1.0, '#ff9d00'), ('snare', 0.0, '#3ddc84')):
        xs = [e.t + t_off for e in ev if e.kind == kind]
        ax[1].vlines(xs, y - 0.4, y + 0.4, color=c, lw=0.5)
    ax[1].set_yticks([0, 1])
    ax[1].set_yticklabels(['snare', 'kick'], color='#aeb6c4')
    ax[2].plot(t, build, color='#ffb020', lw=1.2)
    ax[2].set_ylim(0, 1.05)
    ax[2].set_ylabel('build', color='#aeb6c4')
    for e in ev:
        if e.kind in ('drop', 'return', 'gap'):
            c = {'drop': '#ff5c5c', 'return': '#8b93a3', 'gap': '#ffffff'}[e.kind]
            for a in ax:
                a.axvline(e.t + t_off, color=c, lw=1.2, ls='-' if e.kind == 'drop' else ':')
            ax[0].text(e.t + t_off, ax[0].get_ylim()[1] - 2, ' ' + e.kind.upper(), color=c, fontsize=9, va='top', fontweight='bold')
    ax[3].plot(t, np.where(bpm > 0, bpm, np.nan), color='#c7cdd8', lw=1)
    ax[3].set_ylabel('BPM', color='#aeb6c4')
    ax[3].set_xlabel('seconds', color='#aeb6c4')
    ax[0].set_title(title + '   (blue = break, amber = build, red = drop)', color='#e9ecf1', fontsize=11, loc='left')
    fig.tight_layout()
    fig.savefig(path, dpi=110, facecolor=fig.get_facecolor())
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('path', nargs='?')
    ap.add_argument('--synth', choices=sorted(synth_edm.KINDS))
    ap.add_argument('--from', dest='t0', type=float)
    ap.add_argument('--to', dest='t1', type=float)
    ap.add_argument('--out', default='.')
    a = ap.parse_args()
    truth = None
    if a.synth:
        y, truth = synth_edm.KINDS[a.synth](FS)
        name = 'synth_' + a.synth
    else:
        y = load(a.path, a.t0, a.t1)
        name = os.path.splitext(os.path.basename(a.path))[0]
    d = det.run(y, FS)
    base = os.path.join(a.out, name)
    with open(base + '_events.csv', 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['seconds', 'event', 'value', 'extra'])
        for e in d.events:
            if e.kind != 'build':
                w.writerow([f'{e.t + (a.t0 or 0):.3f}', e.kind, e.value, e.extra])
    picture(d, base + '_timeline.png', name, a.t0 or 0.0)
    ev = d.events
    n = lambda k: sum(1 for e in ev if e.kind == k)  # noqa: E731
    print(f'{name}: {len(y) / FS:.1f} s | kicks {n("kick")} | snares {n("snare")} | beats {n("beat")} | drops {n("drop")} | returns {n("return")} | gaps {n("gap")}')
    if truth:
        for k, v in score(d, truth).items():
            print(f'  {k:14} {v}')
    else:
        for e in ev:
            if e.kind in ('state', 'drop', 'return', 'gap'):
                print(f'  {e.t + (a.t0 or 0):8.2f}s  {e.kind:6} {e.extra} {e.value if e.kind != "state" else ""}')
    print('wrote', base + '_timeline.png', 'and', base + '_events.csv')


if __name__ == '__main__':
    main()
