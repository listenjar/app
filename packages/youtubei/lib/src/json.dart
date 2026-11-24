// Reading YouTube.js values as bindings.js's __serialize writes them.
import 'package:meta/meta.dart';

@internal
typedef Json = Map<String, Object?>;

@internal
Json map(Object? v) => (v as Map?)?.cast<String, Object?>() ?? const {};

@internal
Json? mapOrNull(Object? v) => (v as Map?)?.cast<String, Object?>();

@internal
List<Object?> list(Object? v) => (v as List?) ?? const [];

@internal
String? string(Object? v) => v is String ? v : null;

@internal
bool? boolean(Object? v) => v is bool ? v : null;

@internal
num? number(Object? v) => v is num ? v : null;

@internal
int? integer(Object? v) => v is num ? v.toInt() : null;

@internal
DateTime? date(Object? v) => v is String ? DateTime.tryParse(v) : null;
