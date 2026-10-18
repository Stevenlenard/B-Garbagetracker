import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/services/background_tracking.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('gt/app');

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

  test('Back sends the app to the background instead of closing it', () async {
    final List<String> calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (MethodCall c) async {
      calls.add(c.method);
      return true;
    });
    expect(await BackgroundTracking.moveToBack(), isTrue);
    expect(calls, <String>['moveToBack']);
  });

  test('when the platform cannot do it, the caller falls back (false, never throws)', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (MethodCall c) async {
      throw PlatformException(code: 'x');
    });
    expect(await BackgroundTracking.moveToBack(), isFalse);
    expect(await BackgroundTracking.isBatteryExempt(), isTrue); // unknown counts as fine, so no nagging
  });
}
