import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'json.dart';

/// What every state-changing API call answers.
///
/// [out] is the tool's plain-text report, shown under "Full details".
/// [error] is the one-line reason when [ok] is false.
class ToolResult {
  const ToolResult({required this.ok, this.out = '', this.error = '', this.extra = const {}});

  const ToolResult.failed(this.error) : ok = false, out = '', extra = const {};

  factory ToolResult.fromJson(Json j) => ToolResult(
    ok: j.boolean('ok'),
    out: j.str('out'),
    error: j.str('error'),
    extra: {
      for (final e in j.entries)
        if (e.key != 'ok' && e.key != 'out' && e.key != 'error') e.key: e.value,
    },
  );

  final bool ok;
  final String out;
  final String error;

  /// Any other keys a route adds (for example `queued`).
  final Json extra;

  Json toJson() => {'ok': ok, 'out': out, 'error': error, ...extra};
}

/// Thrown by [SxClient] when the engine can't be reached or says no.
class ApiException implements Exception {
  ApiException(this.message, {this.status});

  final String message;

  /// HTTP status, or null when the engine didn't answer at all.
  final int? status;

  @override
  String toString() => message;
}

/// HTTP client for the engine's `/api/...` routes.
///
/// The laptop UI and the phone UI both go through this class, so every screen
/// works the same in both places. Each area adds its typed calls as an
/// extension on this class, in its own file (see `speed.dart` for the pattern).
class SxClient {
  SxClient(this.base, {required this.token, http.Client? client}) : _http = client ?? http.Client();

  /// Where the engine listens, for example `http://127.0.0.1:47321`.
  final Uri base;

  /// The laptop's session token, or a paired phone's key.
  String token;

  final http.Client _http;

  Uri _uri(String path, Map<String, String>? query) => base.replace(path: path, queryParameters: (query == null || query.isEmpty) ? null : query);

  Map<String, String> get _headers => {'X-SX-Token': token, 'Content-Type': 'application/json'};

  /// GET [path] and parse the answer. An `{"ok":false}` answer throws.
  Future<T> get<T>(String path, T Function(Json) parse, {Map<String, String>? query}) async =>
      parse(_checked(await _send(() => _http.get(_uri(path, query), headers: _headers))));

  /// POST [body] as JSON and parse the answer. An `{"ok":false}` answer throws.
  Future<T> post<T>(String path, Object? body, T Function(Json) parse) async =>
      parse(_checked(await _send(() => _http.post(_uri(path, null), headers: _headers, body: jsonEncode(body ?? const {})))));

  /// POST a state change. A refusal comes back as a [ToolResult] with
  /// `ok == false`, so screens can show the reason next to the button.
  Future<ToolResult> run(String path, [Object? body]) async =>
      ToolResult.fromJson(await _send(() => _http.post(_uri(path, null), headers: _headers, body: jsonEncode(body ?? const {}))));

  /// GET a file the engine serves next to the API (`/brand.png`). Null when
  /// it isn't there or the engine can't be reached.
  Future<Uint8List?> bytes(String path) async {
    try {
      final r = await _http.get(_uri(path, null), headers: _headers);
      return r.statusCode == 200 ? r.bodyBytes : null;
    } on http.ClientException {
      return null;
    }
  }

  Future<Json> _send(Future<http.Response> Function() call) async {
    final http.Response r;
    try {
      r = await call();
    } on http.ClientException catch (e) {
      throw ApiException("Can't reach SX Studio on the laptop (${e.message}).");
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(r.bodyBytes));
    } on FormatException {
      throw ApiException('The laptop sent an answer that is not JSON (HTTP ${r.statusCode}).', status: r.statusCode);
    }
    if (decoded is! Map) throw ApiException('The laptop sent an unexpected answer.', status: r.statusCode);
    final j = decoded.cast<String, Object?>();
    if (r.statusCode >= 400) throw ApiException(j.str('error').isEmpty ? 'HTTP ${r.statusCode}' : j.str('error'), status: r.statusCode);
    return j;
  }

  Json _checked(Json j) {
    if (j['ok'] == false) throw ApiException(j.str('error').isEmpty ? 'Something went wrong.' : j.str('error'));
    return j;
  }

  void close() => _http.close();
}
