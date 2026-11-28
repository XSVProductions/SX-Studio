# Music detector

SX Studio listens to the DJ feed from the mixer and presses ShowXpress buttons for the parts of EDM-style music:

| Moment | What it hears | Default button |
|---|---|---|
| Break | kick and bass gone for 1.5 beats | (none) |
| Build | snare roll speeding up and/or a riser. Level 0 to 100% | AUTO BUILD 1 (35%), 2 (60%), 3 (85%) |
| Snare hit | each snare or clap during a build | AUTO SNARE (flash) |
| Gap | the silence just before a drop | AUTO GAP |
| Drop | kick and bass back after a build | AUTO DROP, for 8 bars |

It also sends ShowXpress every beat, so BPM scenes follow the music. A break that ends without a build is a "return": the break buttons go off, and the drop button stays off.

## How it reaches ShowXpress

Through OS2L, the link VirtualDJ uses for lights. ShowXpress listens for it when **Preferences > Network > Virtual DJ** is enabled (port 7350 unless changed). SX Studio connects to it the way VirtualDJ would. When the SX Player plays instead of ShowXpress, it listens on the same port, so the same thing works there.

Checked on ShowXpress 2026-11-27: an OS2L `btn` message presses and releases the live button with that title within about 10 ms, and ShowXpress answers with a `feedback` message. Not checked yet: that it accepts this link while VirtualDJ itself is also connected.

## Setting it up

1. In ShowXpress, make the buttons (your strobe scenes) and title them as in the table, or use your own titles and type them in the **Strobe** tab's Music detector card. A title left empty is not used.
2. On the DM3, route the DJ channels to USB outputs 1-2, before the faders if you can, so mics and speeches don't trigger strobes.
3. Connect the DM3's USB to Host port to the lighting laptop. On Windows install the Yamaha Steinberg USB Driver.
4. In the Strobe tab press **Start listening**.

Listening to the mixer works on Windows only so far (winmm). On any computer, typing `file:` and the path of a WAV recording as the input plays that recording into the detector at real speed, to try it without the mixer.

## Files

- `detector.py`: the reference version. Try ideas here first.
- `analyze.py`: runs it over a recording and draws a timeline. `python3 analyze.py set.wav` (anything ffmpeg reads), or `--synth main` for a made-up track with known answers.
- `synth_edm.py`: the made-up tracks.
- `test_detector.py`: checks on those tracks. `python3 test_detector.py`
- `flutter/packages/sx_engine/lib/src/audio/`: the app's version. `music_detector.dart` is a step-for-step port of `detector.py`; change one, change the other.

The Dart detector gives the same events as `detector.py` on all four made-up tracks (checked by feeding both the same samples; only the last printed digit differs). The Windows input was checked on a laptop microphone, not yet on the DM3.
