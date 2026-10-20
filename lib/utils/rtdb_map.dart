/// Firebase Realtime Database returns a node whose keys are mostly consecutive integers (e.g. `users/1..24`) as a
/// JSON ARRAY instead of a map. Every reader that expects a map must go through this, or one new user can make the
/// whole node unreadable (all drivers then look offline).
Map<dynamic, dynamic>? rtdbMap(Object? value) {
  if (value is Map) return value;
  if (value is List) {
    final Map<dynamic, dynamic> out = <dynamic, dynamic>{};
    for (int i = 0; i < value.length; i++) {
      if (value[i] != null) out[i.toString()] = value[i];
    }
    return out;
  }
  return null;
}
