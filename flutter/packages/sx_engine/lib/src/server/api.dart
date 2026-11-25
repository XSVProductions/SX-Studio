import 'dart:async';

import 'package:sx_api/sx_api.dart';

/// One API call, already authenticated and decoded.
class ApiRequest {
  ApiRequest({required this.body, required this.query, required this.fromPhone});

  /// The JSON body of a POST, or {} for a GET.
  final Json body;
  final Map<String, String> query;

  /// True when a paired phone or tablet sent this, false for the laptop's own UI.
  final bool fromPhone;
}

/// Answers a call. Return a wire type from `sx_api` (anything with `toJson`),
/// a Map, or a String. A String is a tool's text report and goes out as
/// `{"ok":true,"out":...}`. Throw `ToolError` to refuse with a message.
typedef ApiHandler = FutureOr<Object?> Function(ApiRequest req);

/// Marks a POST route as a save that waits while ShowXpress is open.
///
/// ShowXpress rewrites the show's files when it closes, so a save made while
/// it is open would be lost. Those saves are queued and run once ShowXpress
/// has closed. A later save with the same [key] replaces the earlier one.
class Queueable {
  const Queueable(this.label, {this.key, this.detail});

  /// What the queue list calls this save, for example "Speed faders".
  final String label;

  /// Queue key for a body. Defaults to the route's path (one queued save per route).
  final String Function(Json body)? key;

  /// Extra words added to [label] for a body, for example the scene's name.
  final String Function(Json body)? detail;
}

class ApiRoute {
  ApiRoute(this.method, this.path, this.handler, {required this.phone, this.queue});

  final String method;
  final String path;
  final ApiHandler handler;

  /// False for routes a phone may never call (restart the laptop, pair a phone...).
  final bool phone;
  final Queueable? queue;
}

/// The engine's route table. Each area registers its routes from its own file
/// in `lib/src/server/routes/`.
class Api {
  final _routes = <String, ApiRoute>{};

  /// A read. Must not change anything.
  void get(String path, ApiHandler handler, {bool phone = true}) => _add(ApiRoute('GET', path, handler, phone: phone));

  /// A change. Everything that writes or acts is a POST.
  void post(String path, ApiHandler handler, {bool phone = true, Queueable? queue}) => _add(ApiRoute('POST', path, handler, phone: phone, queue: queue));

  void _add(ApiRoute r) {
    if (_routes.containsKey(r.path)) throw StateError('Route ${r.path} is registered twice');
    _routes[r.path] = r;
  }

  ApiRoute? find(String path) => _routes[path];
}
