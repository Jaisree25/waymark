// Cycle 3 — trip + breadcrumb logger (person-b-mobile.md §2, Cycle 3).
//
// The breadcrumb is the denominator (the full-trip GPS track). Two GeoJSON
// gotchas are asserted explicitly here:
//   1. Coordinate order is [longitude, latitude] — geolocator hands back
//      lat/lon in human order, so the builder MUST swap. Person A's PostGIS and
//      Valhalla expect [lon, lat]; getting it wrong misplaces breadcrumbs.
//   2. A valid GeoJSON LineString needs >= 2 points; a one-point track is
//      invalid and would 422 in Person C's Pydantic validation.

import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/capture/breadcrumb_logger.dart';

import 'support/fakes.dart';
import 'support/openapi.dart';

void main() {
  group('BreadcrumbLogger', () {
    test('test_breadcrumb_accumulates_positions: ordered points from a faked '
        'LocationSource', () async {
      final source = FakeLocationSource([
        gpsFix(37.77, -122.41),
        gpsFix(37.78, -122.42),
        gpsFix(37.79, -122.43),
      ]);
      final logger = BreadcrumbLogger();

      await source.positions().forEach(logger.add);

      expect(
        logger.fixes.map((f) => (f.lat, f.lon)).toList(),
        <(double, double)>[
          (37.77, -122.41),
          (37.78, -122.42),
          (37.79, -122.43),
        ],
      );
    });

    test('test_breadcrumb_payload_matches_contract: [lon,lat] order, >= 2 '
        'points, valid BreadcrumbIn', () {
      final logger = BreadcrumbLogger();

      // A single fix is NOT a valid LineString — it must not build yet.
      logger.add(gpsFix(37.77, -122.41));
      expect(logger.hasValidSegment, isFalse);
      expect(logger.buildTrack, throwsStateError);

      // A second fix makes the segment valid.
      logger.add(gpsFix(37.78, -122.42));
      expect(logger.hasValidSegment, isTrue);

      final jsonMap = logger
          .buildPayload(
            id: '44444444-4444-4444-8444-444444444444',
            tripId: '22222222-2222-4222-8222-222222222222',
          )
          .toJson();

      // GeoJSON coordinate order is [longitude, latitude] — NOT [lat, lon].
      final track = jsonMap['track'] as Map<String, dynamic>;
      expect(track['type'], 'LineString');
      expect(track['coordinates'], <List<double>>[
        <double>[-122.41, 37.77],
        <double>[-122.42, 37.78],
      ]);
      expect((track['coordinates'] as List).length, greaterThanOrEqualTo(2));

      // Validates against the committed BreadcrumbIn schema.
      final result = contractValidator('BreadcrumbIn').validate(jsonMap);
      expect(result.isValid, isTrue, reason: result.errors.join('\n'));
    });
  });
}
