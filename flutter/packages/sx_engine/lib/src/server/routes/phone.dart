import 'dart:io';

import 'package:sx_api/sx_api.dart';

import '../engine.dart';
import '../phone.dart';

/// The Phone & iPad card. Laptop only. Pairing itself
/// (`/api/phone/pair`) is answered by the engine, before any key is checked.
void registerPhoneRoutes(Engine e) {
  e.api.get('/api/phone', phone: false, (req) => phoneInfo(e));

  e.api.post('/api/phone/set', phone: false, (req) async {
    final on = req.body.boolean('on');
    e.phones.setOn(on);
    await e.setPhoneListener(on);
    return phoneInfo(e);
  });

  // A new code changes state, so this is a POST (the old app used a GET).
  e.api.post('/api/phone/pin', phone: false, (req) {
    e.phones.newPin();
    return phoneInfo(e);
  });

  e.api.post('/api/phone/unpair', phone: false, (req) {
    final id = req.body.str('id');
    e.phones.unpair(id.isEmpty ? '*' : id);
    return phoneInfo(e);
  });
}

/// What the Phone & iPad card shows. Port of `Get-PhoneInfo`.
Future<PhoneInfo> phoneInfo(Engine e) async {
  final ph = e.phones;
  final seen = ph.lastSeen;
  final running = e.phonePort != null;
  return PhoneInfo(
    on: ph.on,
    port: e.phonePort ?? e.config.phonePort,
    running: running,
    error: e.phoneError,
    addrs: await lanAddresses(),
    local: localName(),
    mac: Platform.isMacOS,
    pin: ph.pin,
    pinLeft: ph.pinLeft,
    lastSeen: seen == null ? '' : sortableTime(seen.$1),
    lastIp: seen?.$2 ?? '',
    phones: ph.phones,
  );
}
