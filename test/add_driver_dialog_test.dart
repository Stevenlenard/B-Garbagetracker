import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/api/api_service.dart';
import 'package:garbage_tracking_app/widgets/add_driver_dialog.dart';

class _Fake implements HttpClientAdapter {
  _Fake(this.reply);
  final Map<String, Object?> reply;
  Map<String, dynamic>? sent;
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? s, Future<void>? c) async {
    sent = (o.data is Map) ? Map<String, dynamic>.from(o.data as Map) : null;
    return ResponseBody.fromString(jsonEncode(reply), 200, headers: <String, List<String>>{Headers.contentTypeHeader: <String>[Headers.jsonContentType]});
  }
  @override
  void close({bool force = false}) {}
}

void main() {
  Future<_Fake> open(WidgetTester t, Map<String, Object?> reply, List<bool?> result) async {
    t.view.physicalSize = const Size(1200, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final _Fake fake = _Fake(reply);
    final ApiService api = ApiService(dio: Dio(BaseOptions(baseUrl: 'https://x/'))..httpClientAdapter = fake);
    await t.pumpWidget(MaterialApp(
      home: Builder(builder: (BuildContext context) => Scaffold(
        body: Center(child: ElevatedButton(onPressed: () async => result.add(await showAddDriverDialog(context, api: api)), child: const Text('open'))),
      )),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    return fake;
  }

  Future<void> fill(WidgetTester t) async {
    await t.enterText(find.widgetWithText(TextFormField, 'Full name'), 'Juan Dela Cruz');
    await t.enterText(find.widgetWithText(TextFormField, 'Username'), 'juan driver');
    await t.enterText(find.widgetWithText(TextFormField, 'Email'), 'juan@example.com');
    await t.enterText(find.widgetWithText(TextFormField, 'Contact number'), '09171234567');
    await t.enterText(find.widgetWithText(TextFormField, 'License number'), 'N01-23-456789');
  }

  testWidgets('an empty form is not sent and says what is missing', (WidgetTester t) async {
    final _Fake fake = await open(t, <String, Object?>{'success': true}, <bool?>[]);
    await t.tap(find.text('Create account'));
    await t.pumpAndSettle();
    expect(fake.sent, isNull);
    expect(find.text("Enter the driver's full name."), findsOneWidget);
    expect(find.text('Enter the license number.'), findsOneWidget);
  });

  testWidgets('creates an active driver account and shows the login details to hand over', (WidgetTester t) async {
    final List<bool?> result = <bool?>[];
    final _Fake fake = await open(t, <String, Object?>{'success': true, 'user_id': 12}, result);
    await fill(t);
    await t.tap(find.text('Create account'));
    await t.pumpAndSettle();
    expect(fake.sent?['role'], 'driver');
    expect(fake.sent?['username'], 'juandriver', reason: 'spaces cannot be typed');
    expect((fake.sent?['password'] as String).length, greaterThanOrEqualTo(6));
    expect(find.text('Driver account created'), findsOneWidget);
    expect(find.text('juandriver'), findsOneWidget);
    await t.tap(find.text('Done'));
    await t.pumpAndSettle();
    expect(result.single, isTrue);
  });

  testWidgets('a server refusal is shown in the form', (WidgetTester t) async {
    await open(t, <String, Object?>{'success': false, 'message': 'That username is already taken.'}, <bool?>[]);
    await fill(t);
    await t.tap(find.text('Create account'));
    await t.pumpAndSettle();
    expect(find.text('That username is already taken.'), findsOneWidget);
    expect(find.text('Driver account created'), findsNothing);
  });
}
