# SX Studio (Flutter)

The Flutter port of SX Studio. `CLAUDE.md` explains how it is put together and how to work on it.

```
cd packages/sx_engine && dart test        # engine tests, including old-versus-new checks
cd ui && flutter run -d windows           # the app
```

Publishing a release: `RELEASE_SETUP.md` (first time) and `ui/windows/installer/README.md`.
