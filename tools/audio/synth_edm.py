"""Synthetic EDM-style test tracks with known answers, for checking the
build / drop detector without a real recording.

Each track is made from simple parts: a sine-sweep kick, a noise clap, noise
hi-hats, a sidechained saw bass, a pad, a snare roll and a noise riser. The
recipe returns the audio and the ground truth (kick times, snare times, where
the breakdown, build and drop are).

    python3 synth_edm.py out.wav            # the main test track
    python3 synth_edm.py out.wav --kind halftime
"""

from __future__ import annotations

import argparse
import wave
from dataclasses import dataclass, field

import numpy as np


@dataclass
class Truth:
    bpm: float
    kicks: list[float] = field(default_factory=list)
    snares: list[float] = field(default_factory=list)
    breaks: list[tuple[float, float]] = field(default_factory=list)  # (start, end) without kick and bass
    builds: list[tuple[float, float]] = field(default_factory=list)
    drops: list[float] = field(default_factory=list)  # big drops (after a build)
    returns: list[float] = field(default_factory=list)  # kick back without a build
    gaps: list[tuple[float, float]] = field(default_factory=list)


class Track:
    def __init__(self, bpm: float, bars: int, fs: int = 44100, seed: int = 1):
        self.bpm, self.fs = bpm, fs
        self.beat = 60.0 / bpm
        self.n = int((bars * 4 + 2) * self.beat * fs)
        self.y = np.zeros(self.n)
        self.rng = np.random.default_rng(seed)
        self.truth = Truth(bpm)

    def t(self, bar: float, beat: float = 0.0) -> float:
        return (bar * 4 + beat) * self.beat

    def _add(self, at: float, sig: np.ndarray, gain: float = 1.0):
        i = int(round(at * self.fs))
        if i >= self.n:
            return
        j = min(self.n, i + len(sig))
        self.y[i:j] += gain * sig[: j - i]

    # ---- parts
    def kick(self, at: float, gain: float = 0.9):
        n = int(0.35 * self.fs)
        tt = np.arange(n) / self.fs
        f = 45 + 110 * np.exp(-tt * 30)
        ph = 2 * np.pi * np.cumsum(f) / self.fs
        env = np.exp(-tt * 9)
        click = self.rng.standard_normal(n) * np.exp(-tt * 400) * 0.25
        self._add(at, (np.sin(ph) * env + click), gain)
        self.truth.kicks.append(at)

    def clap(self, at: float, gain: float = 0.5, truth: bool = True):
        n = int(0.18 * self.fs)
        tt = np.arange(n) / self.fs
        noise = self.rng.standard_normal(n)
        # crude band shaping: difference of two smoothings -> ~1-5 kHz
        k1 = np.ones(4) / 4
        k2 = np.ones(30) / 30
        band = np.convolve(noise, k1, 'same') - np.convolve(noise, k2, 'same')
        env = np.exp(-tt * 28)
        body = np.sin(2 * np.pi * 190 * tt) * np.exp(-tt * 40) * 0.4
        self._add(at, band * env * 1.6 + body, gain)
        if truth:
            self.truth.snares.append(at)

    def hat(self, at: float, gain: float = 0.12):
        n = int(0.05 * self.fs)
        tt = np.arange(n) / self.fs
        noise = self.rng.standard_normal(n)
        from scipy.signal import butter, lfilter

        b, a = butter(4, 7000 / (self.fs / 2), 'high')
        self._add(at, lfilter(b, a, noise) * np.exp(-tt * 90), gain * 2)

    def bass(self, t0: float, t1: float, freq: float = 55.0, gain: float = 0.35, side: bool = True):
        i0, i1 = int(t0 * self.fs), min(self.n, int(t1 * self.fs))
        tt = np.arange(i1 - i0) / self.fs
        saw = 2 * ((tt * freq) % 1.0) - 1
        sub = np.sin(2 * np.pi * freq * tt)
        sig = 0.5 * saw + 0.8 * sub
        # smooth it a little (low-pass)
        sig = np.convolve(sig, np.ones(20) / 20, 'same')
        if side:
            ph = ((tt) / self.beat) % 1.0
            sig *= np.clip(ph * 4, 0.15, 1.0)  # duck at each beat
        self.y[i0:i1] += gain * sig

    def pad(self, t0: float, t1: float, gain: float = 0.12):
        i0, i1 = int(t0 * self.fs), min(self.n, int(t1 * self.fs))
        tt = np.arange(i1 - i0) / self.fs
        sig = sum(np.sin(2 * np.pi * f * tt + k) for k, f in enumerate([220, 277.2, 329.6, 440]))
        fade = np.clip(tt / 1.0, 0, 1) * np.clip((tt[-1] - tt) / 0.5, 0, 1)
        self.y[i0:i1] += gain * sig * fade / 4

    def riser(self, t0: float, t1: float, gain: float = 0.35):
        i0, i1 = int(t0 * self.fs), min(self.n, int(t1 * self.fs))
        m = i1 - i0
        noise = self.rng.standard_normal(m)
        prog = np.linspace(0, 1, m)
        # high-pass that opens upward: subtract a shrinking smoothing
        out = np.empty(m)
        seg = 4096
        for s in range(0, m, seg):
            w = max(2, int(40 * (1 - prog[s]) + 2))
            blk = noise[s : s + seg]
            out[s : s + seg] = blk - np.convolve(blk, np.ones(w) / w, 'same') * 0.9
        self.y[i0:i1] += gain * out * prog**1.5

    def groove(self, b0: int, b1: int, bass: bool = True, halftime: bool = False, loud: float = 1.0):
        for bar in range(b0, b1):
            for beat in range(4):
                at = self.t(bar, beat)
                if halftime:
                    if beat == 0:
                        self.kick(at, 0.9 * loud)
                    if beat == 2:
                        self.clap(at, 0.6 * loud)
                    if beat in (1, 3):
                        self.kick(at + self.beat * 0.5, 0.6 * loud) if beat == 3 else None
                else:
                    self.kick(at, 0.9 * loud)
                    if beat in (1, 3):
                        self.clap(at, 0.5 * loud)
                self.hat(at + self.beat / 2)
        if bass:
            self.bass(self.t(b0), self.t(b1), gain=0.35 * loud, side=not halftime)

    def build(self, b0: int, b1: int, gap_beats: float = 1.0):
        """Snare roll that speeds up (1/4, 1/8, 1/16, 1/32), a riser, then a gap."""
        bars = b1 - b0
        end = self.t(b1) - gap_beats * self.beat
        for bar in range(b0, b1):
            k = (bar - b0) / bars
            div = 1 if k < 0.5 else 2 if k < 0.75 else 4 if k < 0.875 else 8
            step = self.beat / div
            at = self.t(bar)
            stop = min(self.t(bar + 1), end)
            gain = 0.25 + 0.35 * k
            while at < stop - 1e-6:
                self.clap(at, gain)
                at += step
        self.riser(self.t(b0), end)
        self.pad(self.t(b0), end, 0.08)
        self.truth.builds.append((self.t(b0), end))
        if gap_beats > 0:
            self.truth.gaps.append((end, self.t(b1)))

    def noise_floor(self, db: float = -62):
        self.y += self.rng.standard_normal(self.n) * 10 ** (db / 20)

    def done(self) -> tuple[np.ndarray, Truth]:
        peak = np.max(np.abs(self.y))
        self.y *= 0.9 / peak
        self.truth.kicks.sort()
        self.truth.snares.sort()
        return self.y.astype(np.float32), self.truth


def main_track(fs: int = 44100, bpm: float = 128.0, seed: int = 1) -> tuple[np.ndarray, Truth]:
    """Intro groove, breakdown, build, gap, drop, a breakdown with no build, groove back."""
    tr = Track(bpm, 72, fs, seed)
    tr.groove(0, 16)
    tr.pad(tr.t(16), tr.t(24))
    tr.truth.breaks.append((tr.t(16), tr.t(32)))
    tr.build(24, 32)
    tr.groove(32, 48, loud=1.0)
    tr.truth.drops.append(tr.t(32))
    tr.pad(tr.t(48), tr.t(56))
    for bar in range(48, 56):
        for beat in range(4):
            tr.hat(tr.t(bar, beat) + tr.beat / 2, 0.06)
    tr.truth.breaks.append((tr.t(48), tr.t(56)))
    tr.groove(56, 72)
    tr.truth.returns.append(tr.t(56))
    tr.noise_floor()
    return tr.done()


def halftime_track(fs: int = 44100, bpm: float = 140.0, seed: int = 2) -> tuple[np.ndarray, Truth]:
    """Dubstep-style: kick on 1, snare on 3, build into a half-time drop."""
    tr = Track(bpm, 40, fs, seed)
    tr.groove(0, 8)
    tr.pad(tr.t(8), tr.t(16))
    tr.truth.breaks.append((tr.t(8), tr.t(24)))
    tr.build(16, 24)
    tr.groove(24, 40, halftime=True)
    tr.truth.drops.append(tr.t(24))
    tr.noise_floor()
    return tr.done()


def steady_track(fs: int = 44100, bpm: float = 124.0, seed: int = 3) -> tuple[np.ndarray, Truth]:
    """House groove with no breakdown at all: there should be no drop."""
    tr = Track(bpm, 48, fs, seed)
    tr.groove(0, 48)
    tr.noise_floor()
    return tr.done()


KINDS = {'main': main_track, 'halftime': halftime_track, 'steady': steady_track}


def write_wav(path: str, y: np.ndarray, fs: int):
    pcm = (np.clip(y, -1, 1) * 32767).astype('<i2')
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(fs)
        w.writeframes(pcm.tobytes())


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('out')
    ap.add_argument('--kind', choices=sorted(KINDS), default='main')
    ap.add_argument('--fs', type=int, default=44100)
    a = ap.parse_args()
    y, truth = KINDS[a.kind](a.fs)
    write_wav(a.out, y, a.fs)
    print(f'{a.out}: {len(y) / a.fs:.1f} s, {len(truth.kicks)} kicks, {len(truth.snares)} snares, drops at {truth.drops}')


def mix_track(fs: int = 44100, seed: int = 4) -> tuple[np.ndarray, Truth]:
    """Two tracks mixed: 128 BPM, an 8-bar crossfade, then 124 BPM alone. Tests re-locking."""
    a = Track(128.0, 40, fs, seed)
    a.groove(0, 40)
    ya, ta = a.done()
    b = Track(124.0, 48, fs, seed + 1)
    b.groove(0, 48)
    yb, tb = b.done()
    start = a.t(32)  # b comes in at a's bar 32, a fades out over 8 bars
    n = int(start * fs) + len(yb)
    y = np.zeros(n)
    y[: len(ya)] += ya * np.clip(1 - (np.arange(len(ya)) / fs - start) / (a.t(40) - start), 0, 1)
    i = int(start * fs)
    y[i : i + len(yb)] += yb * np.clip((np.arange(len(yb)) / fs) / 4.0, 0, 1)
    t = Truth(124.0)
    t.kicks = [k for k in ta.kicks if k < start] + [k + start for k in tb.kicks if k + start > a.t(40)]
    t.snares = [k for k in ta.snares if k < start] + [k + start for k in tb.snares if k + start > a.t(40)]
    y *= 0.9 / np.max(np.abs(y))
    return y.astype(np.float32), t


KINDS['mix'] = mix_track
