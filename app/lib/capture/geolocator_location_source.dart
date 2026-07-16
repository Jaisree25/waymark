// lib/capture/geolocator_location_source.dart
//
// Cycle 8d — the real LocationSource, wrapping geolocator. Device only; unit
// tests use FakeLocationSource. Maps geolocator's Position → our GpsFix (storing
// horizontalAccuracy — M1 risk #2).

import 'package:geolocator/geolocator.dart';

import 'ports.dart';

class GeolocatorLocationSource implements LocationSource {
  const GeolocatorLocationSource({this.settings = const LocationSettings()});

  final LocationSettings settings;

  @override
  Stream<GpsFix> positions() =>
      Geolocator.getPositionStream(locationSettings: settings).map(
        (p) => GpsFix(
          lat: p.latitude,
          lon: p.longitude,
          horizontalAccuracyM: p.accuracy,
          speedMps: p.speed,
          timestamp: p.timestamp,
        ),
      );
}
