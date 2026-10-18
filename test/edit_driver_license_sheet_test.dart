import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/widgets/edit_driver_license_sheet.dart';

void main() {
  test('license validation: required, bounded, plain characters only', () {
    expect(validateLicenseNumber(''), isNotNull);
    expect(validateLicenseNumber('   '), isNotNull);
    expect(validateLicenseNumber('A' * 41), isNotNull);
    expect(validateLicenseNumber('N01-23-456789'), isNull);
    expect(validateLicenseNumber('  GT-008 '), isNull);
    expect(validateLicenseNumber('abc\u{1F600}'), isNotNull);
  });

  testWidgets('license row shows the number and says it is not the truck', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DriverLicenseTile(license: 'N01-23', onPressed: () {}))));
    expect(find.text('N01-23'), findsOneWidget);
    expect(find.text("Driver's License No."), findsOneWidget);
    expect(find.text("The person's own license, not the truck"), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DriverLicenseTile(license: null, onPressed: () {}))));
    expect(find.text('Not provided'), findsOneWidget);
  });
}
