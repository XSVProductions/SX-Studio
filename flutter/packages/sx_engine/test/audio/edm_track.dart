import 'dart:math' as math;
import 'dart:typed_data';

/// Made-up EDM-style tracks with known answers, for testing the music
/// detector. Port of the main and steady recipes in `tools/audio/synth_edm.py`
/// (the noise differs, so the numbers differ a little, the answers don't).
class EdmTrack {
  EdmTrack(this.bpm, int bars, {this.fs = 44100, int seed = 1}) : _rng = math.Random(seed), beat = 60.0 / bpm {
    y = Float64List(((bars * 4 + 2) * beat * fs).toInt());
  }

  final double bpm, beat;
  final int fs;
  final math.Random _rng;
  late final Float64List y;

  final kicks = <double>[], snares = <double>[], drops = <double>[], returns = <double>[];
  final builds = <(double, double)>[], gaps = <(double, double)>[];

  double t(num bar, [num b = 0]) => (bar * 4 + b) * beat;

  double _gauss() {
    final u = math.max(1e-12, _rng.nextDouble()), v = _rng.nextDouble();
    return math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * v);
  }

  void _add(double at, List<double> sig, double gain) {
    final i = (at * fs).round();
    for (var k = 0; k < sig.length && i + k < y.length; k++) {
      y[i + k] += gain * sig[k];
    }
  }

  List<double> _smooth(List<double> x, int w) {
    // centred moving average, like numpy's convolve(..., 'same')
    final out = List<double>.filled(x.length, 0);
    final h = w ~/ 2;
    for (var i = 0; i < x.length; i++) {
      var s = 0.0;
      for (var k = i - h; k < i - h + w; k++) {
        if (k >= 0 && k < x.length) s += x[k];
      }
      out[i] = s / w;
    }
    return out;
  }

  void kick(double at, [double gain = 0.9]) {
    final n = (0.35 * fs).toInt();
    final sig = List<double>.filled(n, 0);
    var ph = 0.0;
    for (var i = 0; i < n; i++) {
      final tt = i / fs;
      ph += 2 * math.pi * (45 + 110 * math.exp(-tt * 30)) / fs;
      sig[i] = math.sin(ph) * math.exp(-tt * 9) + _gauss() * math.exp(-tt * 400) * 0.25;
    }
    _add(at, sig, gain);
    kicks.add(at);
  }

  void clap(double at, [double gain = 0.5]) {
    final n = (0.18 * fs).toInt();
    final noise = [for (var i = 0; i < n; i++) _gauss()];
    final a = _smooth(noise, 4), b = _smooth(noise, 30);
    final sig = [
      for (var i = 0; i < n; i++) (a[i] - b[i]) * math.exp(-i / fs * 28) * 1.6 + math.sin(2 * math.pi * 190 * i / fs) * math.exp(-i / fs * 40) * 0.4,
    ];
    _add(at, sig, gain);
    snares.add(at);
  }

  void hat(double at, [double gain = 0.12]) {
    final n = (0.05 * fs).toInt();
    // four one-pole high-passes at 7 kHz
    final rc = 1 / (2 * math.pi * 7000), dt = 1 / fs, a = rc / (rc + dt);
    var x = [for (var i = 0; i < n; i++) _gauss()];
    for (var pass = 0; pass < 4; pass++) {
      final o = List<double>.filled(n, 0);
      for (var i = 1; i < n; i++) {
        o[i] = a * (o[i - 1] + x[i] - x[i - 1]);
      }
      x = o;
    }
    _add(at, [for (var i = 0; i < n; i++) x[i] * math.exp(-i / fs * 90) * 2], gain);
  }

  void bass(double t0, double t1, {double gain = 0.35}) {
    final i0 = (t0 * fs).toInt(), i1 = math.min(y.length, (t1 * fs).toInt());
    final raw = [for (var i = 0; i < i1 - i0; i++) 0.5 * (2 * ((i / fs * 55.0) % 1.0) - 1) + 0.8 * math.sin(2 * math.pi * 55.0 * i / fs)];
    final sig = _smooth(raw, 20);
    for (var i = 0; i < sig.length; i++) {
      final ph = (i / fs / beat) % 1.0;
      y[i0 + i] += gain * sig[i] * (ph * 4).clamp(0.15, 1.0).toDouble();
    }
  }

  void pad(double t0, double t1, [double gain = 0.12]) {
    final i0 = (t0 * fs).toInt(), i1 = math.min(y.length, (t1 * fs).toInt());
    final len = (i1 - i0) / fs;
    for (var i = 0; i < i1 - i0; i++) {
      final tt = i / fs;
      var s = 0.0;
      var k = 0;
      for (final f in const [220.0, 277.2, 329.6, 440.0]) {
        s += math.sin(2 * math.pi * f * tt + k++);
      }
      y[i0 + i] += gain * s * tt.clamp(0.0, 1.0).toDouble() * ((len - tt) / 0.5).clamp(0.0, 1.0).toDouble() / 4;
    }
  }

  void riser(double t0, double t1, [double gain = 0.35]) {
    final i0 = (t0 * fs).toInt(), i1 = math.min(y.length, (t1 * fs).toInt());
    final m = i1 - i0;
    const seg = 4096;
    for (var s = 0; s < m; s += seg) {
      final e = math.min(m, s + seg);
      final blk = [for (var i = s; i < e; i++) _gauss()];
      final w = math.max(2, (40 * (1 - s / m) + 2).toInt());
      final sm = _smooth(blk, w);
      for (var i = s; i < e; i++) {
        final prog = i / m;
        y[i0 + i] += gain * (blk[i - s] - sm[i - s] * 0.9) * math.pow(prog, 1.5).toDouble();
      }
    }
  }

  void groove(int b0, int b1) {
    for (var bar = b0; bar < b1; bar++) {
      for (var b = 0; b < 4; b++) {
        final at = t(bar, b);
        kick(at);
        if (b == 1 || b == 3) clap(at);
        hat(at + beat / 2);
      }
    }
    bass(t(b0), t(b1));
  }

  /// Snare roll that speeds up (1/4, 1/8, 1/16, 1/32), a riser, then a one-beat gap.
  void build(int b0, int b1) {
    final bars = b1 - b0, end = t(b1) - beat;
    for (var bar = b0; bar < b1; bar++) {
      final k = (bar - b0) / bars;
      final div = k < 0.5 ? 1 : (k < 0.75 ? 2 : (k < 0.875 ? 4 : 8));
      var at = t(bar);
      final stop = math.min(t(bar + 1), end);
      while (at < stop - 1e-6) {
        clap(at, 0.25 + 0.35 * k);
        at += beat / div;
      }
    }
    riser(t(b0), end);
    pad(t(b0), end, 0.08);
    builds.add((t(b0), end));
    gaps.add((end, t(b1)));
  }

  Float64List done() {
    for (var i = 0; i < y.length; i++) {
      y[i] += _gauss() * 0.0008; // -62 dB noise floor
    }
    var peak = 0.0;
    for (final v in y) {
      peak = math.max(peak, v.abs());
    }
    for (var i = 0; i < y.length; i++) {
      y[i] *= 0.9 / peak;
    }
    kicks.sort();
    snares.sort();
    return y;
  }

  /// Intro groove, breakdown, build, gap, drop, a breakdown with no build, groove back.
  static EdmTrack main({int fs = 44100}) {
    final tr = EdmTrack(128, 72, fs: fs);
    tr.groove(0, 16);
    tr.pad(tr.t(16), tr.t(24));
    tr.build(24, 32);
    tr.groove(32, 48);
    tr.drops.add(tr.t(32));
    tr.pad(tr.t(48), tr.t(56));
    for (var bar = 48; bar < 56; bar++) {
      for (var b = 0; b < 4; b++) {
        tr.hat(tr.t(bar, b) + tr.beat / 2, 0.06);
      }
    }
    tr.groove(56, 72);
    tr.returns.add(tr.t(56));
    tr.done();
    return tr;
  }

  /// House groove with no breakdown at all: there should be no drop.
  static EdmTrack steady({int fs = 44100}) {
    final tr = EdmTrack(124, 48, fs: fs, seed: 3);
    tr.groove(0, 48);
    tr.done();
    return tr;
  }
}
