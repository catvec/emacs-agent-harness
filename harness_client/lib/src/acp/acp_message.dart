/// Small, defensive helpers for the untyped JSON that ACP carries.
///
/// The harness documents every shape as a keyword plist; JSON turns those
/// into objects with string keys.  A client should never crash because a
/// server sent a string where a number was expected, or omitted a key.
library;

typedef JsonMap = Map<String, Object?>;

JsonMap asMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return value.map((key, value) => MapEntry('$key', value));
  }
  return const <String, Object?>{};
}

List<Object?> asList(Object? value) {
  if (value is List) return value;
  if (value == null) return const <Object?>[];
  return <Object?>[value];
}

List<JsonMap> asMapList(Object? value) =>
    asList(value).map(asMap).where((map) => map.isNotEmpty).toList();

String? asString(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  return '$value';
}

String asStringOr(Object? value, String fallback) =>
    asString(value) ?? fallback;

int? asInt(Object? value) {
  if (value is int) return value;
  if (value is double) return value.round();
  if (value is String) return int.tryParse(value);
  return null;
}

double? asDouble(Object? value) {
  if (value is double) return value;
  if (value is int) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

bool asBool(Object? value, {bool fallback = false}) {
  if (value == null) return fallback;
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    return switch (value.toLowerCase()) {
      'true' || 'yes' || '1' || 't' => true,
      'false' || 'no' || '0' || 'nil' => false,
      _ => fallback,
    };
  }
  return fallback;
}

/// The first string of [value], which may be a string or a list of them.
String? firstString(Object? value) {
  if (value is String) return value;
  for (final item in asList(value)) {
    if (item is String && item.isNotEmpty) return item;
  }
  return null;
}

/// A text block in ACP's content shape.
JsonMap textBlock(String text) => <String, Object?>{
  'type': 'text',
  'text': text,
};

/// The text of an ACP content block, or of a list of them.
String textOf(Object? content) {
  if (content is String) return content;
  if (content is Map) {
    final map = asMap(content);
    if (map['type'] == 'text') return asString(map['text']) ?? '';
    if (map.containsKey('text')) return asString(map['text']) ?? '';
    if (map.containsKey('content')) return textOf(map['content']);
    return '';
  }
  if (content is List) {
    return content.map(textOf).join();
  }
  return '';
}

/// A stable, human-readable string for an enum that may travel as a symbol,
/// a string, a keyword, or a JSON true/false.
String enumName(Object? value, {String fallback = ''}) {
  if (value == null) return fallback;
  if (value == true) return 'true';
  if (value == false) return 'false';
  return '$value'.replaceFirst(RegExp(r'^:'), '');
}
