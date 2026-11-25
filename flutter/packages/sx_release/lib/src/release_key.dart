/// The public half of the SX Studio release key, base64 (32 bytes, Ed25519).
/// Every `release.json` must carry a signature by the private half
/// (`%USERPROFILE%\.sx-release\release_key`, never in git) or the app and
/// the setup program refuse it.
///
/// A new key: `dart run sx_release:release_tool keygen`, then paste what it
/// prints here. Apps built with the old key then refuse every update signed
/// with the new one, so keep the key.
const releasePublicKey = 'uDVSzTFy/iy6voIBqgSYSSgk137cqt83kmWzl53x5+M=';
