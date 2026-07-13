// lib/capture/trip_controller.dart
//
// Cycle 3 — trip lifecycle. A Trip wraps a drive: it opens on start (stamping
// the app/config versions and the start time from the injected clock) and closes
// on stop (stamping the end time). `toPayload` maps it to Contract-2 `TripIn`.

import 'ports.dart';

/// An in-progress or completed drive.
class Trip {
  const Trip({
    required this.id,
    required this.userId,
    required this.provider,
    required this.supervision,
    required this.appVersion,
    required this.configVersion,
    required this.startedAt,
    this.fsdVersion,
    this.vehicle,
    this.deviceInfo = const <String, dynamic>{},
    this.endedAt,
  });

  final String id;
  final String userId;
  final String provider;
  final bool supervision;

  /// The app build version (e.g. "1.0.0+1"). TripIn has no dedicated field, so
  /// it is carried in `device_info` on the wire.
  final String appVersion;

  /// The config file version (e.g. "1.0.0"), mapped to `app_config_version`.
  final String configVersion;

  final DateTime startedAt;
  final String? fsdVersion;
  final String? vehicle;
  final Map<String, dynamic> deviceInfo;
  final DateTime? endedAt;

  bool get isOpen => endedAt == null;

  Trip closedAt(DateTime when) => Trip(
        id: id,
        userId: userId,
        provider: provider,
        supervision: supervision,
        appVersion: appVersion,
        configVersion: configVersion,
        startedAt: startedAt,
        fsdVersion: fsdVersion,
        vehicle: vehicle,
        deviceInfo: deviceInfo,
        endedAt: when,
      );

  TripPayload toPayload({Map<String, dynamic> metrics = const <String, dynamic>{}}) {
    return TripPayload(
      id: id,
      userId: userId,
      provider: provider,
      supervision: supervision,
      appConfigVersion: configVersion,
      startedAt: startedAt,
      fsdVersion: fsdVersion,
      vehicle: vehicle,
      // The app build version has no dedicated TripIn field; carry it here.
      deviceInfo: <String, dynamic>{...deviceInfo, 'app_version': appVersion},
      endedAt: endedAt,
      metrics: metrics,
    );
  }
}

/// Opens and closes the current [Trip], stamping times from the injected clock.
class TripController {
  TripController({required this.clock});

  final Clock clock;

  Trip? _current;

  /// The current trip (open or just-closed), or null before the first start.
  Trip? get current => _current;

  /// Open a new trip. Start time is stamped from the clock; versions are stamped
  /// from the caller (they come from ConfigService / the app build).
  Trip start({
    required String id,
    required String userId,
    required String provider,
    required bool supervision,
    required String appVersion,
    required String configVersion,
    String? fsdVersion,
    String? vehicle,
    Map<String, dynamic> deviceInfo = const <String, dynamic>{},
  }) {
    final trip = Trip(
      id: id,
      userId: userId,
      provider: provider,
      supervision: supervision,
      appVersion: appVersion,
      configVersion: configVersion,
      startedAt: clock.now(),
      fsdVersion: fsdVersion,
      vehicle: vehicle,
      deviceInfo: deviceInfo,
    );
    _current = trip;
    return trip;
  }

  /// Close the current trip, stamping the end time. Throws if none is open.
  Trip stop() {
    final trip = _current;
    if (trip == null || !trip.isOpen) {
      throw StateError('no open trip to stop');
    }
    final closed = trip.closedAt(clock.now());
    _current = closed;
    return closed;
  }
}
