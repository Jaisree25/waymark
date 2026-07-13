// lib/capture/location_tracker.dart
//
// Cycle 10a — subscribes to a LocationSource and caches the latest fix so the
// trigger pipeline can stamp events with the trigger-time location (and the
// breadcrumb logger can read the stream). Started/stopped with the trip.

import 'dart:async';

import 'ports.dart';

class LocationTracker {
  LocationTracker(this._source);

  final LocationSource _source;
  GpsFix? _current;
  StreamSubscription<GpsFix>? _sub;

  /// Optional observer fed every fix from the SINGLE subscription (e.g. the
  /// breadcrumb logger) — so GPS is subscribed once and serves both consumers.
  void Function(GpsFix fix)? onFix;

  /// The most recent fix, or null before the first one arrives.
  GpsFix? get current => _current;

  void start() => _sub ??= _source.positions().listen(_handle);

  void _handle(GpsFix fix) {
    _current = fix;
    onFix?.call(fix);
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }
}
