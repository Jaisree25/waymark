// lib/capture/breadcrumb_logger.dart
//
// Cycle 3 — the breadcrumb logger (the trip denominator). Accumulates GPS fixes
// in order and builds a GeoJSON LineString for Contract-2 `BreadcrumbIn`.
//
// Two GeoJSON invariants live here:
//   * coordinates are [longitude, latitude] (NOT [lat, lon]) — the swap from
//     geolocator's human order happens in [buildTrack];
//   * a LineString needs >= 2 points, so [buildTrack] refuses a single fix
//     rather than emit invalid GeoJSON that Person C would reject with a 422.

import 'ports.dart';

class BreadcrumbLogger {
  BreadcrumbLogger();

  final List<GpsFix> _fixes = <GpsFix>[];

  /// The accumulated fixes, in arrival order.
  List<GpsFix> get fixes => List<GpsFix>.unmodifiable(_fixes);

  /// True once there are enough points (>= 2) for a valid LineString.
  bool get hasValidSegment => _fixes.length >= 2;

  /// Append one GPS fix (drives off a faked/real [LocationSource] stream).
  void add(GpsFix fix) => _fixes.add(fix);

  /// Drop all fixes (start a fresh segment for a new trip).
  void clear() => _fixes.clear();

  /// Build the GeoJSON LineString. Coordinates are `[lon, lat]`. Throws if there
  /// are fewer than 2 points (a one-point LineString is invalid GeoJSON).
  Map<String, dynamic> buildTrack() {
    if (!hasValidSegment) {
      throw StateError(
        'a GeoJSON LineString needs >= 2 points (have ${_fixes.length})',
      );
    }
    return <String, dynamic>{
      'type': 'LineString',
      'coordinates': <List<double>>[
        for (final fix in _fixes) <double>[fix.lon, fix.lat], // [lon, lat]
      ],
    };
  }

  /// Build the Contract-2 breadcrumb payload for the current segment.
  BreadcrumbPayload buildPayload({
    required String id,
    required String tripId,
    Map<String, dynamic> motionSummary = const <String, dynamic>{},
  }) {
    return BreadcrumbPayload(
      id: id,
      tripId: tripId,
      track: buildTrack(),
      motionSummary: motionSummary,
    );
  }
}
