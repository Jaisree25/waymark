// Cycle 5 — EventPayload.fromJson round-trips toJson. The outbox stores the
// serialized payload; the uploader reconstructs it to POST, so the reconstruction
// must be lossless.

import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/capture/ports.dart';

import 'support/fakes.dart';

void main() {
  test('EventPayload.fromJson(toJson) reproduces the payload', () {
    final payload = eventPayloadFixture(
      id: '11111111-1111-4111-8111-111111111111',
      features: const {'k': 'v'},
    );
    expect(EventPayload.fromJson(payload.toJson()).toJson(), payload.toJson());
  });

  test('round-trips a null-severity / no-location event', () {
    final payload = eventPayloadFixture(
      id: '22222222-2222-4222-8222-222222222222',
      severity: null,
      rawLat: null,
      rawLon: null,
      rawAccuracyM: null,
    );
    expect(EventPayload.fromJson(payload.toJson()).toJson(), payload.toJson());
  });
}
