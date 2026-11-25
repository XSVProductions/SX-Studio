# SX Studio (Flutter)

The Flutter port of SX Studio. Nothing here is released yet. The PowerShell app in `../src` is still the one people run.

- `HANDOVER.md`: what state the port is in, what was checked, and how the switch works. Start here.
- `CLAUDE.md`: how the code is put together and the rules for working on it.
- `RELEASE_SETUP.md`: publishing a release, first time and every time.

```
cd packages/sx_engine && dart test        # engine tests, including old-versus-new checks
cd ui && flutter run -d windows           # the app
```
