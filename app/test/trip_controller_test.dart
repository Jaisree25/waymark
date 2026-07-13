// Cycle 3 — trip lifecycle (person-b-mobile.md §2, Cycle 3).
//
// A Trip wraps a drive: it opens on start (stamping app/config versions and the
// start time) and closes on stop (stamping the end time). Its payload maps to
// Contract 2's TripIn.

import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/capture/trip_controller.dart';

import 'support/fakes.dart';
import 'support/openapi.dart';

void main() {
  TripController newController(FakeClock clock) => TripController(clock: clock);

  group('TripController', () {
    test('test_trip_start_stop: opens on start, closes on stop, stamps '
        'app/config version', () {
      final clock = FakeClock(DateTime.utc(2026, 7, 10, 9, 0, 0));
      final controller = newController(clock);

      final trip = controller.start(
        id: '55555555-5555-4555-8555-555555555555',
        userId: 'firebase-uid-1',
        provider: 'tesla',
        supervision: true,
        appVersion: '1.0.0+1',
        configVersion: '1.0.0',
      );

      expect(trip.isOpen, isTrue);
      expect(trip.startedAt, DateTime.utc(2026, 7, 10, 9, 0, 0));
      expect(trip.endedAt, isNull);
      expect(trip.appVersion, '1.0.0+1'); // app_version stamped
      expect(trip.configVersion, '1.0.0'); // config_version stamped
      expect(controller.current, same(trip));

      clock.advance(const Duration(minutes: 30));
      final closed = controller.stop();

      expect(closed.isOpen, isFalse);
      expect(closed.startedAt, DateTime.utc(2026, 7, 10, 9, 0, 0));
      expect(closed.endedAt, DateTime.utc(2026, 7, 10, 9, 30, 0));

      // No open trip to stop anymore.
      expect(controller.stop, throwsStateError);
    });

    test('trip payload matches Contract 2 TripIn (app_config_version + '
        'app_version carried in device_info)', () {
      final clock = FakeClock(DateTime.utc(2026, 7, 10, 9, 0, 0));
      final controller = newController(clock);
      controller.start(
        id: '55555555-5555-4555-8555-555555555555',
        userId: 'firebase-uid-1',
        provider: 'tesla',
        supervision: true,
        appVersion: '1.0.0+1',
        configVersion: '1.0.0',
      );
      clock.advance(const Duration(minutes: 30));
      final closed = controller.stop();

      final jsonMap = closed.toPayload().toJson();

      // app_config_version is the config version; app_version rides in the
      // free-form device_info object (TripIn has no dedicated app_version field).
      expect(jsonMap['app_config_version'], '1.0.0');
      expect((jsonMap['device_info'] as Map)['app_version'], '1.0.0+1');

      final result = contractValidator('TripIn').validate(jsonMap);
      expect(result.isValid, isTrue, reason: result.errors.join('\n'));
    });
  });
}
