import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/rtdb_map.dart';

void main() {
  test('a users node returned as an array (dense numeric ids) is read as a map by id', () {
    final m = rtdbMap(<Object?>[null, {'name': 'A'}, null, {'name': 'Darna', 'role': 'driver'}])!;
    expect(m.keys, <String>['1', '3']);
    expect((m['3'] as Map)['name'], 'Darna');
  });

  test('a map stays a map; anything else is null', () {
    expect(rtdbMap({'7': {'name': 'Steve'}})!['7'], isNotNull);
    expect(rtdbMap('x'), isNull);
    expect(rtdbMap(null), isNull);
  });
}
