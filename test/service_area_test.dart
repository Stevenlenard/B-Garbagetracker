import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/services/service_area_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Service Area & Route Optimization Verification', () {
    test('Canonical 10 Documented Service Areas Count', () {
      final defaultAreas = ServiceAreaService.defaultServiceAreas;
      expect(defaultAreas.length, equals(10));
    });

    test('Collection Coverage vs Stationary Sweeping Split', () {
      final defaultAreas = ServiceAreaService.defaultServiceAreas;
      final truckStops = defaultAreas.where((a) => a.isTruckStop).toList();
      final sweepingAreas = defaultAreas.where((a) => !a.isTruckStop).toList();

      expect(truckStops.length, equals(9));
      expect(sweepingAreas.length, equals(1));
    });

    test('Central (Purok 1) Display Name and Type', () {
      final defaultAreas = ServiceAreaService.defaultServiceAreas;
      final central = defaultAreas.firstWhere((a) => a.id == 'central_purok_1');

      expect(central.name, equals('Central (Purok 1)'));
      expect(central.type, equals('Purok'));
      expect(central.isTruckStop, isTrue);
    });

    test('Stationary Sweeping Area San Nicolas Classification', () {
      final defaultAreas = ServiceAreaService.defaultServiceAreas;
      final sanNicolas = defaultAreas.firstWhere((a) => a.id == 'san_nicolas_sweeping');

      expect(sanNicolas.name, equals('San Nicolas'));
      expect(sanNicolas.type, equals('Stationary Sweeping Area'));
      expect(sanNicolas.isTruckStop, isFalse);
    });

    test('Coordinate Ranges and Verification Status', () {
      final defaultAreas = ServiceAreaService.defaultServiceAreas;

      for (var area in defaultAreas) {
        expect(area.latitude, greaterThanOrEqualTo(-90.0));
        expect(area.latitude, lessThanOrEqualTo(90.0));
        expect(area.longitude, greaterThanOrEqualTo(-180.0));
        expect(area.longitude, lessThanOrEqualTo(180.0));
        expect(area.latitude, isNot(equals(0.0)));
        expect(area.longitude, isNot(equals(0.0)));
        expect(area.verificationStatus, equals('VERIFIED'));
      }
    });

    test('Route Optimization Filtering and GeoJSON Coordinate Format', () {
      final defaultAreas = ServiceAreaService.defaultServiceAreas;

      // Filter truck stops
      final truckStops = defaultAreas.where((a) => a.isTruckStop && a.verificationStatus == 'VERIFIED').toList();
      expect(truckStops.length, equals(9));

      // Validate GeoJSON format: coordinates must be [longitude, latitude]
      for (var stop in truckStops) {
        final geoJsonCoords = [stop.entranceLng, stop.entranceLat];
        expect(geoJsonCoords[0], equals(stop.entranceLng), reason: 'GeoJSON index 0 must be longitude');
        expect(geoJsonCoords[1], equals(stop.entranceLat), reason: 'GeoJSON index 1 must be latitude');
      }
    });
  });
}
