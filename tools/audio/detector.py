"""Reference version of SX Studio's music detector.

Listens to a stereo or mono feed (the DJ channels from the mixer) and reports,
as the music plays:

* kick and snare hits,
* the tempo and a beat clock that runs ahead of the music (beats are
  predicted, so the lights don't lag), with bar position,
* the section: GROOVE, BREAK (kick and bass gone), BUILD (snare roll speeding
  up and/or a riser) with a build level 0..1, the GAP (silence just before a
  drop), and DROP (kick and bass back after a build) or RETURN (back after a
  break without a build).

It runs block by block on a stream, exactly as the app does live. The Dart
port in `flutter/packages/sx_engine/lib/src/audio/music_detector.dart` follows
this file step for step: change one, change the other.

Everything is causal: a decision at time t only uses audio up to t (plus one
10 ms hop for picking onset peaks).
"""

from __future__ import annotations

import math
from collections import deque
from dataclasses import dataclass

import numpy as np

# ---------------------------------------------------------------- settings
HOP_S = 0.010  # analysis step
LOW_HZ = 150.0  # kick and bass: below this
MID_LO_HZ, MID_HI_HZ = 1000.0, 5000.0  # snare / clap crack
HIGH_HZ = 7000.0  # hats, risers

KICK_MIN_DB = 6.0  # an onset is a rise of at least this many dB over 20 ms...
SNARE_MIN_DB = 6.0
KICK_REL = 0.55  # ...and at least this share of the recent loudest onset
SNARE_REL = 0.60
KICK_HALF_LIFE_S, SNARE_HALF_LIFE_S = 1.5, 3.0  # how fast the loudest recent hit is forgotten
KICK_CAP_DB, SNARE_CAP_DB = 14.0, 24.0  # one huge hit (the first kick of a drop) can't raise the bar past this
KICK_WIN, KICK_BACK, KICK_SPAN = 1, 2, 10  # hops: level window, how far back to compare, over how many
SNARE_WIN, SNARE_BACK, SNARE_SPAN = 2, 2, 1
ENV_HZ = 25.0  # low band: squared, then this low-pass
KICK_LAG_S, SNARE_LAG_S = 0.020, 0.012  # the peak comes this long after the hit starts (measured on test tracks)
FLUX_MAX_DB = 30.0
KICK_GAP_S = 0.120  # two kicks can't be closer than this
SNARE_GAP_S = 0.045  # a 1/32 roll at 150 BPM is 50 ms
SILENCE_DB = -60.0  # below this nothing counts

BPM_MIN, BPM_MAX = 75.0, 180.0
BPM_CENTER = 122.0  # tempo prior: favours the usual dance range
TEMPO_WIN_S = 6.0
TEMPO_EVERY_S = 0.5
LOCK_S, LOCK_KICKS = 6.0, 3  # this many kicks on the beat clock within this long = locked
SWITCH_MARGIN = 1.5  # a different tempo must repeat this much more clearly to take over
PLL_PHASE = 0.30  # how much of a kick's timing error moves the beat
PLL_PERIOD = 0.04  # ...and the tempo
PLL_WINDOW = 0.22  # a kick within this share of a beat of the clock counts

BREAK_DB = 10.0  # low end this far under the groove level = break
BREAK_HOLD_BEATS = 1.5
DROP_DB = 6.0  # low end back within this of the groove level = drop / return
MIN_BREAK_BEATS = 4.0
BUILD_ON, BUILD_OFF = 0.35, 0.20
BIG_DROP_BUILD = 0.50  # a break whose build reached this ends in a DROP
DROP_BEATS = 32  # how long DROP lasts before GROOVE
GAP_DB = 15.0
RISER_BEATS, RISER_DB, RISER_WEIGHT = 8, 10.0, 0.4  # highs up 10 dB over 8 beats = a full riser

GROOVE, BREAK, BUILD, DROP = 'GROOVE', 'BREAK', 'BUILD', 'DROP'


def _db(e: float) -> float:
    return 10.0 * math.log10(e + 1e-12)


def _ema_coef(tau_s: float) -> float:
    return 1.0 - math.exp(-HOP_S / tau_s)


class Biquad:
    """RBJ cookbook low/high-pass, direct form I. One per band stage."""

    def __init__(self, kind: str, f0: float, fs: float, q: float = 0.7071):
        w0 = 2 * math.pi * f0 / fs
        c, a = math.cos(w0), math.sin(w0) / (2 * q)
        if kind == 'lp':
            b0, b1, b2 = (1 - c) / 2, 1 - c, (1 - c) / 2
        else:
            b0, b1, b2 = (1 + c) / 2, -(1 + c), (1 + c) / 2
        a0, a1, a2 = 1 + a, -2 * c, 1 - a
        self.b = np.array([b0, b1, b2]) / a0
        self.a = np.array([1.0, a1 / a0, a2 / a0])
        self.zi = np.zeros(2)

    def run(self, x: np.ndarray) -> np.ndarray:
        # scipy's lfilter gives the same numbers as the sample loop in Dart
        from scipy.signal import lfilter

        y, self.zi = lfilter(self.b, self.a, x, zi=self.zi)
        return y


class Band:
    def __init__(self, stages: list[Biquad]):
        self.stages = stages

    def run(self, x: np.ndarray) -> np.ndarray:
        for s in self.stages:
            x = s.run(x)
        return x


@dataclass
class Event:
    t: float  # seconds of audio
    kind: str  # kick, snare, beat, state, build, gap, drop, return
    value: float = 0.0
    extra: str = ''


class Onsets:
    """Peak picking on the rise of a band's level.

    The level is the band's energy over the last [win] hops. The rise is that
    level against the loudest level between [back] and [back] + [span] - 1
    hops ago. The kick uses a long span (it must top everything in the last
    ~120 ms), so the dip and swell where a kick's tail meets the bass doesn't
    read as another kick. The low band's energy comes already smoothed
    (squared, then a 25 Hz low-pass).

    The threshold follows the loudest recent onsets (a peak that fades with
    [half_life], and one huge hit counts for no more than [cap] dB), so
    quieter hits in the same band (hats in the snare band, a bass note in
    the kick band) stay under it, and it adapts to the level of
    the feed by itself. [lag_s] is how late the picked peak is, on average,
    after the hit starts: it is taken off the reported time.
    """

    def __init__(self, min_db: float, gap_s: float, rel: float, cap: float, half_life: float, win: int, back: int, span: int, lag_s: float):
        self.min_db, self.gap_s, self.rel, self.cap, self.lag_s = min_db, gap_s, rel, cap, lag_s
        self.back = back
        self.en = deque([0.0] * win, maxlen=win)
        self.lv = deque([SILENCE_DB] * (back + span), maxlen=back + span)
        self.flux = deque([0.0, 0.0], maxlen=2)  # flux[-1] is the candidate
        self.peak = 0.0
        self.decay = 0.5 ** (HOP_S / half_life)
        self.last = -1e9

    def level(self) -> float:
        """The band's level now (dB, over the window)."""
        return self.lv[-1]

    def step(self, e: float, t: float) -> float | None:
        """Feeds one hop's energy. Returns the strength of an onset found one hop ago, or None.
        Its time is [when] (t)."""
        self.en.append(e)
        now = max(_db(sum(self.en) / len(self.en)), SILENCE_DB)
        lv = list(self.lv)
        before = max(lv[: len(lv) - self.back + 1])
        self.lv.append(now)
        f = min(FLUX_MAX_DB, max(0.0, now - before))
        prev2, cand = self.flux
        self.flux.append(f)
        self.peak *= self.decay
        thr = max(self.min_db, self.rel * self.peak)
        tc = self.when(t)
        if cand >= thr and cand >= prev2 and cand > f and tc - self.last >= self.gap_s:
            self.last = tc
            self.peak = max(self.peak, min(cand, self.cap))
            return cand
        return None

    def when(self, t: float) -> float:
        return t - HOP_S - self.lag_s


class Detector:
    """[lead_s] gives each beat out that long before it happens (the beat
    clock is a prediction), to make up for the delay of the audio input and
    of whatever plays the lights. Offline it stays 0."""

    def __init__(self, fs: int, lead_s: float = 0.0):
        self.fs, self.lead_s = fs, lead_s
        self.hop = max(1, int(round(fs * HOP_S)))
        self.low = Band([Biquad('lp', LOW_HZ, fs), Biquad('lp', LOW_HZ, fs)])
        self.mid = Band([Biquad('hp', MID_LO_HZ, fs), Biquad('hp', MID_LO_HZ, fs), Biquad('lp', MID_HI_HZ, fs), Biquad('lp', MID_HI_HZ, fs)])
        self.high = Band([Biquad('hp', HIGH_HZ, fs), Biquad('hp', HIGH_HZ, fs)])
        self.low_env = Biquad('lp', ENV_HZ, fs)
        self.n = 0  # hops done
        self.kick_on = Onsets(KICK_MIN_DB, KICK_GAP_S, KICK_REL, KICK_CAP_DB, KICK_HALF_LIFE_S, KICK_WIN, KICK_BACK, KICK_SPAN, KICK_LAG_S)
        self.snare_on = Onsets(SNARE_MIN_DB, SNARE_GAP_S, SNARE_REL, SNARE_CAP_DB, SNARE_HALF_LIFE_S, SNARE_WIN, SNARE_BACK, SNARE_SPAN, SNARE_LAG_S)
        # tempo
        self.env = deque([0.0] * int(TEMPO_WIN_S / HOP_S), maxlen=int(TEMPO_WIN_S / HOP_S))
        self.estimates = deque(maxlen=5)
        self.on_grid = deque(maxlen=16)  # times of kicks that landed on the beat clock
        self.off_count = 0
        self.period = 0.0  # s, 0 = no tempo yet
        self.next_beat = 0.0
        self.beat_n = 0  # beats given out
        self.bar_off = 0
        self.kicks_t = deque(maxlen=64)
        self.snares_t = deque(maxlen=128)
        self.slot = [0.0, 0.0, 0.0, 0.0]  # snare weight per bar position
        # levels
        self.low_avg = SILENCE_DB
        self.high_avg = SILENCE_DB
        self.full_fast = SILENCE_DB
        self.full_slow = SILENCE_DB
        self.high_hist = deque(maxlen=int(12.0 / HOP_S))
        self.ref: float | None = None
        # sections
        self.state = GROOVE
        self.state_t = 0.0
        self.break_t = 0.0
        self.below_since: float | None = None
        self.build = 0.0
        self.build_peak = 0.0
        self.gap_sent = False
        self.drop_left = 0
        self.events: list[Event] = []
        self.log: list[tuple] = []  # per hop, for the timeline picture

    # ------------------------------------------------------------ input
    def feed(self, x: np.ndarray) -> list[Event]:
        """Feeds mono float samples (-1..1). Returns the events they caused."""
        lo, mi, hi = self.low_env.run(self.low.run(x) ** 2), self.mid.run(x), self.high.run(x)
        self._lo = np.concatenate([getattr(self, '_lo', np.zeros(0)), lo])
        self._mi = np.concatenate([getattr(self, '_mi', np.zeros(0)), mi])
        self._hi = np.concatenate([getattr(self, '_hi', np.zeros(0)), hi])
        self._fu = np.concatenate([getattr(self, '_fu', np.zeros(0)), x])
        out_from = len(self.events)
        h = self.hop
        while len(self._lo) >= h:
            el = max(0.0, float(np.mean(self._lo[:h])))  # already an energy
            em = float(np.mean(self._mi[:h] ** 2))
            eh = float(np.mean(self._hi[:h] ** 2))
            ef = float(np.mean(self._fu[:h] ** 2))
            self._lo, self._mi, self._hi, self._fu = self._lo[h:], self._mi[h:], self._hi[h:], self._fu[h:]
            self.n += 1
            self._hop(self.n * h / self.fs, el, em, eh, ef)
        return self.events[out_from:]

    # ------------------------------------------------------------ one hop
    def _hop(self, t: float, el: float, em: float, eh: float, ef: float):
        kick = self.kick_on.step(el, t)
        snare = self.snare_on.step(em, t)
        low, mid, high, full = _db(el), _db(em), _db(eh), _db(ef)
        tk, ts = self.kick_on.when(t), self.snare_on.when(t)
        if kick is not None:
            self._emit(tk, 'kick', kick)
            self.kicks_t.append(tk)
        if snare is not None:
            self._emit(ts, 'snare', snare)
            self.snares_t.append(ts)
        self.env.append(min(30.0, (kick or 0.0)) + 0.6 * min(30.0, (snare or 0.0)))

        # levels
        self.low_avg += (low - self.low_avg) * _ema_coef(0.30)
        self.high_avg += (high - self.high_avg) * _ema_coef(0.50)
        self.full_fast += (full - self.full_fast) * _ema_coef(0.03)
        self.full_slow += (full - self.full_slow) * _ema_coef(0.50)
        self.high_hist.append(self.high_avg)

        self._tempo(t, tk if kick is not None else None)
        self._beats(t)
        if snare is not None:
            self._snare_slot(ts)
        self._sections(t, tk if kick is not None else None)
        self.log.append((t, low, mid, high, self.state, self.build, 60.0 / self.period if self.period else 0.0, self.ref or SILENCE_DB))

    def _emit(self, t, kind, value=0.0, extra=''):
        self.events.append(Event(round(t, 4), kind, round(float(value), 3), extra))

    # ------------------------------------------------------------ tempo
    def _tempo(self, t: float, tk: float | None):
        if self.n % int(round(TEMPO_EVERY_S / HOP_S)) == 0:
            est = self._acf_bpm()
            if est and self.period and not self._worth_switching(est):
                est = 60.0 / self.period  # the beat we have still fits as well: keep it
            if est:
                self.estimates.append(est)
                med = float(np.median(self.estimates))
                if self.period == 0.0:
                    if len(self.estimates) >= 3:
                        self.period = 60.0 / med
                        last_k = self.kicks_t[-1] if self.kicks_t else t
                        k = math.ceil((t - last_k) / self.period)
                        self.next_beat = last_k + k * self.period
                elif abs(60.0 / self.period - med) / med > 0.03:
                    self.off_count += 1
                    if self.off_count >= 4:  # a new tempo for 2 s: take it
                        self.period = 60.0 / med
                        self.off_count = 0
                else:
                    self.off_count = 0
        if tk is not None and self.period:
            prev = self.next_beat - self.period
            near = prev if abs(tk - prev) < abs(tk - self.next_beat) else self.next_beat
            err = tk - near
            if abs(err) < PLL_WINDOW * self.period:
                self.on_grid.append(tk)
                self.next_beat += PLL_PHASE * err
                self.period += PLL_PERIOD * err
                self.period = min(60.0 / BPM_MIN, max(60.0 / BPM_MAX, self.period))

    def _acf_bpm(self) -> float | None:
        o = np.array(self.env)
        if o.sum() < 50:
            return None
        o = o - o.mean()
        best, best_lag, scores = -1e18, 0, {}
        lo = int(math.floor(60.0 / BPM_MAX / HOP_S))
        hi = int(math.ceil(60.0 / BPM_MIN / HOP_S))
        for lag in range(lo, 2 * hi + 3):  # up to two slow beats, for _support
            scores[lag] = float(np.dot(o[lag:], o[:-lag])) / (len(o) - lag)
        for lag in range(lo + 1, hi + 1):
            bpm = 60.0 / (lag * HOP_S)
            w = math.exp(-0.5 * (math.log2(bpm / BPM_CENTER) / 0.7) ** 2)
            s = scores[lag] * w
            if s > best and scores[lag] >= scores[lag - 1] and scores[lag] >= scores[lag + 1]:
                best, best_lag = s, lag
        self._scores = scores
        if best_lag == 0 or scores[best_lag] <= 0:
            return None
        a, b, c = scores[best_lag - 1], scores[best_lag], scores[best_lag + 1]
        den = a - 2 * b + c
        frac = 0.5 * (a - c) / den if den != 0 else 0.0
        bpm = 60.0 / ((best_lag + frac) * HOP_S)
        # half-time feel (kick on 1, snare on 3) reads as half the tempo
        if bpm < 95.0 and 2 * bpm <= BPM_MAX:
            bpm *= 2
        return bpm

    def _support(self, bpm: float) -> float:
        """How well the last few seconds repeat at [bpm]'s beat, or every two or four beats."""
        sc = self._scores
        best = 0.0
        for mult in (1, 2, 4):
            lag = 60.0 / bpm / HOP_S * mult
            i = int(round(lag))
            if i - 1 in sc and i + 1 in sc:
                best = max(best, sc[i - 1], sc[i], sc[i + 1])
        return best

    def _worth_switching(self, est: float) -> bool:
        """A new tempo only wins when it repeats clearly better than the one we follow."""
        cur = 60.0 / self.period
        if abs(cur - est) / est <= 0.03:
            return True
        # kicks keep landing on our beat: the tempo is right, whatever else repeats
        if self.on_grid and sum(1 for k in self.on_grid if self.on_grid[-1] - k < LOCK_S) >= LOCK_KICKS and self.n * HOP_S - self.on_grid[-1] < 3.0:
            return False
        # 2:3, 3:4 and 1:2 are what syncopation (dotted kicks, half-time) fakes
        r = est / cur
        tricky = any(abs(r - q) / q < 0.03 for q in (0.5, 2 / 3, 0.75, 4 / 3, 1.5, 2.0))
        margin = SWITCH_MARGIN * (2.0 if tricky else 1.0)
        return self._support(est) > margin * max(1e-9, self._support(cur))

    def _beats(self, t: float):
        if not self.period:
            return
        while t + self.lead_s >= self.next_beat:
            pos = (self.beat_n - self.bar_off) % 4
            self._emit(self.next_beat, 'beat', 60.0 / self.period, str(pos + 1))
            self.beat_n += 1
            self.next_beat += self.period
            for i in range(4):
                self.slot[i] *= 0.98

    def _snare_slot(self, ts: float):
        if not self.period:
            return
        prev = self.next_beat - self.period
        n = self.beat_n - 1 if abs(ts - prev) <= abs(ts - self.next_beat) else self.beat_n
        near = prev if n == self.beat_n - 1 else self.next_beat
        if abs(ts - near) > 0.15 * self.period:
            return
        self.slot[(n - self.bar_off) % 4] += 1.0
        # four-on-the-floor: snares belong on 2 and 4
        if self.state in (GROOVE, DROP) and self._kicks_per_beat() > 0.8:
            even, odd = self.slot[0] + self.slot[2], self.slot[1] + self.slot[3]
            if even > 6 and even > 2 * odd:
                self.bar_off += 1
                self.slot = self.slot[1:] + self.slot[:1]

    def _kicks_per_beat(self) -> float:
        if not self.period or not self.kicks_t:
            return 0.0
        now = self.kicks_t[-1]
        n = sum(1 for k in self.kicks_t if now - k < 4 * self.period)
        return n / 4.0

    # ------------------------------------------------------------ sections
    def _beat_s(self) -> float:
        return self.period or 0.5

    def _set_state(self, t: float, s: str, extra: str = ''):
        if s == self.state:
            return
        self.state, self.state_t = s, t
        self._emit(t, 'state', 0.0, s + (':' + extra if extra else ''))

    def _sections(self, t: float, tk: float | None):
        b = self._beat_s()
        groovy = self.state in (GROOVE, DROP)
        if self.ref is None:
            if len(self.kicks_t) >= 6 and self.low_avg > SILENCE_DB + 10:
                self.ref = self.low_avg
            return
        if groovy:
            k = 0.2 if self.low_avg > self.ref else 0.002
            self.ref += (self.low_avg - self.ref) * k
            if self.state == DROP and self.drop_left <= 0:
                self._set_state(t, GROOVE)
            if self.low_avg < self.ref - BREAK_DB:
                if self.below_since is None:
                    self.below_since = t
                if t - self.below_since >= BREAK_HOLD_BEATS * b:
                    self.build = 0.0
                    self.build_peak = 0.0
                    self.gap_sent = False
                    self.break_t = self.below_since
                    self._set_state(self.below_since, BREAK)
            else:
                self.below_since = None
            if self.state == DROP:
                self.drop_left -= HOP_S / b
            return

        # in a break or a build
        self.below_since = None
        rate = sum(1 for s in self.snares_t if t - s < 2 * b) / 2.0
        density = 0.0 if rate < 0.25 else min(1.0, max(0.0, 0.3 + 0.25 * math.log2(rate)))
        back = int(RISER_BEATS * b / HOP_S)
        riser = 0.0
        if len(self.high_hist) > back:
            riser = min(1.0, max(0.0, (self.high_hist[-1] - self.high_hist[-1 - back]) / RISER_DB))
        score = 1.0 - (1.0 - density) * (1.0 - RISER_WEIGHT * riser)
        if score > self.build:
            self.build += (score - self.build) * _ema_coef(0.25)
        else:
            self.build -= min(self.build - score, HOP_S / (4 * b) * 0.5)
        self.build_peak = max(self.build_peak, self.build)
        if self.state == BREAK and self.build >= BUILD_ON:
            self._set_state(t, BUILD)
        elif self.state == BUILD and self.build < BUILD_OFF:
            self._set_state(t, BREAK)
        if self.n % int(round(0.1 / HOP_S)) == 0:
            self._emit(t, 'build', self.build)

        # the silence right before a drop
        if self.state == BUILD and not self.gap_sent and self.full_fast < self.full_slow - GAP_DB:
            self.gap_sent = True
            self._emit(t, 'gap', self.build)

        # kick and bass are back
        long_enough = t - self.break_t >= MIN_BREAK_BEATS * b
        if tk is not None and long_enough and self._low_peak() >= self.ref - DROP_DB:
            big = self.build_peak >= BIG_DROP_BUILD
            self._emit(tk, 'drop' if big else 'return', self.build_peak)
            # the drop is bar 1
            if self.period:
                prev = self.next_beat - self.period
                n = self.beat_n - 1 if abs(tk - prev) <= abs(tk - self.next_beat) else self.beat_n
                self.bar_off = n % 4
                self.slot = [0.0, 0.0, 0.0, 0.0]
            self.build = 0.0
            if big:
                self.drop_left = DROP_BEATS
                self._set_state(tk, DROP)
            else:
                self._set_state(tk, GROOVE)

    def _low_peak(self) -> float:
        """The low band's level just now: a kick that is back at full weight."""
        return self.kick_on.level()


def run(y: np.ndarray, fs: int, block_s: float = 0.05) -> Detector:
    """Runs a whole recording through the detector in blocks, like a live feed."""
    d = Detector(fs)
    step = int(fs * block_s)
    for i in range(0, len(y), step):
        d.feed(y[i : i + step].astype(np.float64))
    return d
