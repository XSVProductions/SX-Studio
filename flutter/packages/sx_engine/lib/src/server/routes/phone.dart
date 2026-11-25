import 'dart:io';

import 'package:sx_api/sx_api.dart';

import '../engine.dart';
import '../../ps_compat.dart';
import '../phone.dart';
import 'aim.dart' show psTruthy;

/// The Phone & iPad card. Laptop only. Pairing itself
/// (`/api/phone/pair`) is answered by the engine, before any key is checked.
void registerPhoneRoutes(Engine e) {
  e.api.get('/api/phone', phone: false, (req) => phoneInfo(e));

  e.api.post('/api/phone/set', phone: false, (req) async {
    final on = psTruthy(req.body['on']);
    e.phones.setOn(on);
    await e.setPhoneListener(on);
    return phoneInfo(e);
  });

  // A new code changes state, so this is a POST (the old app used a GET).
  // Good for 10 minutes, for any number of phones and iPads.
  e.api.post('/api/phone/pin', phone: false, (req) {
    e.phones.newPin();
    return phoneInfo(e);
  });

  // "Unpair all phones": a new key, so every phone pairs again.
  e.api.post('/api/phone/unpair', phone: false, (req) {
    e.phones.unpair();
    return phoneInfo(e);
  });
}

/// What the Phone & iPad card shows. Port of `Get-PhoneInfo`.
Future<PhoneInfo> phoneInfo(Engine e) async {
  final ph = e.phones;
  final running = e.phonePort != null;
  final seen = running ? ph.lastSeen : null;
  return PhoneInfo(
    on: ph.on,
    port: e.phonePort ?? e.config.phonePort,
    running: running,
    error: e.phoneError,
    addrs: await lanAddresses(),
    local: await localName(),
    mac: Platform.isMacOS,
    pin: ph.pin,
    pinLeft: ph.pinLeft,
    lastSeen: seen == null ? '' : sortableTime(seen),
    lastIp: seen == null ? '' : ph.lastIp,
  );
}
