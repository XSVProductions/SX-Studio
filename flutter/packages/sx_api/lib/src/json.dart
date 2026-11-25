/// A decoded JSON object.
typedef Json = Map<String, Object?>;

/// Typed readers for decoded JSON, used by every `fromJson` in this package.
///
/// A missing or null value reads as the empty default ('' / 0 / false / []),
/// because the old tools leave keys out freely. A value of the wrong type
/// throws a [FormatException] that names the key.
extension JsonRead on Json {
  Never _bad(String key, String want) => throw FormatException('"$key" should be $want, got ${this[key]}');

  String str(String key) {
    final v = this[key];
    if (v == null) return '';
    if (v is String) return v;
    if (v is num || v is bool) return '$v';
    _bad(key, 'a string');
  }

  String? strOrNull(String key) => this[key] == null ? null : str(key);

  int integer(String key) {
    final v = this[key];
    if (v == null) return 0;
    if (v is num) return v.round();
    if (v is String) return int.tryParse(v) ?? _bad(key, 'a whole number');
    _bad(key, 'a whole number');
  }

  int? integerOrNull(String key) => this[key] == null ? null : integer(key);

  double number(String key) {
    final v = this[key];
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? _bad(key, 'a number');
    _bad(key, 'a number');
  }

  double? numberOrNull(String key) => this[key] == null ? null : number(key);

  bool boolean(String key) {
    final v = this[key];
    if (v == null) return false;
    if (v is bool) return v;
    _bad(key, 'true or false');
  }

  Json obj(String key) => objOrNull(key) ?? const {};

  Json? objOrNull(String key) {
    final v = this[key];
    if (v == null) return null;
    if (v is Map) return v.cast<String, Object?>();
    _bad(key, 'an object');
  }

  /// A list of objects, each parsed with [parse].
  List<T> list<T>(String key, T Function(Json) parse) => [
    for (final e in _rawList(key))
      if (e is Map) parse(e.cast<String, Object?>()) else _bad(key, 'a list of objects'),
  ];

  List<String> strList(String key) => [for (final e in _rawList(key)) '$e'];

  List<int> intList(String key) => [
    for (final e in _rawList(key))
      if (e is num) e.round() else _bad(key, 'a list of whole numbers'),
  ];

  /// PowerShell's ConvertTo-Json turns a one-item pipeline result into a bare
  /// value, so a "list" from an old tool can arrive as a single item.
  List<Object?> _rawList(String key) {
    final v = this[key];
    if (v == null) return const [];
    if (v is List) return v;
    return [v];
  }
}
