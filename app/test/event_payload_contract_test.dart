// Cycle 2 — test_event_payload_matches_contract (person-b-mobile.md §2, Cycle 2).
//
// The assembled EventPayload must serialize to JSON that satisfies Contract 2's
// EventIn (contracts/openapi.yaml). We validate against the ACTUAL committed file
// (support/openapi.dart loads it), assert the body is metadata-only (no blobs),
// and pin the exact JSON with a golden file.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/capture/event.dart';
import 'package:fsd_app/capture/ports.dart';

import 'support/fakes.dart';
import 'support/openapi.dart';

void main() {
  // A deterministic assembled event mapped to its Contract-2 payload.
  EventPayload buildPayload() {
    final event = Event(
      tTrigger: DateTime.utc(2026, 7, 10, 17, 30, 0),
      triggerSource: 'voice',
      eventType: 'incident',
      severity: 4,
      tPreSeconds: 15,
      tPostSeconds: 8,
      // Blobs are held on the Event but must NOT appear in the payload body.
      audioWindow: <AudioFrame>[audioFrame(1), audioFrame(2)],
    );
    return event.toPayload(
      id: '11111111-1111-4111-8111-111111111111',
      tripId: '22222222-2222-4222-8222-222222222222',
      rawLat: 37.7749,
      rawLon: -122.4194,
      rawAccuracyM: 5.0,
      features: const <String, dynamic>{},
    );
  }

  group('EventPayload → Contract 2 EventIn', () {
    test('validates against the committed openapi.yaml EventIn schema', () {
      final jsonMap = buildPayload().toJson();

      final result = contractValidator('EventIn').validate(jsonMap);
      expect(result.isValid, isTrue, reason: result.errors.join('\n'));

      // All contract-required fields are present.
      expect(
        jsonMap.keys,
        containsAll(<String>[
          'id',
          'trip_id',
          't_trigger',
          't_pre_seconds',
          't_post_seconds',
          'trigger_source',
        ]),
      );

      // A null-severity, no-location event still satisfies the (nullable) schema.
      final minimal = Event(
        tTrigger: DateTime.utc(2026, 7, 10, 17, 30, 0),
        triggerSource: 'voice',
        eventType: 'incident',
        severity: null,
        tPreSeconds: 15,
        tPostSeconds: 8,
        audioWindow: const <AudioFrame>[],
      ).toPayload(
        id: '33333333-3333-4333-8333-333333333333',
        tripId: '22222222-2222-4222-8222-222222222222',
      );
      final minimalResult =
          contractValidator('EventIn').validate(minimal.toJson());
      expect(minimalResult.isValid, isTrue,
          reason: minimalResult.errors.join('\n'));
    });

    test('emits metadata only — no audio/sensor blob in the body', () {
      final jsonMap = buildPayload().toJson();

      // Every emitted key is a declared EventIn property — nothing extra leaks.
      final allowed = contractPropertyNames('EventIn');
      expect(jsonMap.keys.toSet().difference(allowed), isEmpty);

      // Explicitly: no blob-ish keys made it into the request body.
      for (final key in jsonMap.keys) {
        final k = key.toLowerCase();
        expect(
          k.contains('audio') ||
              k.contains('sensor') ||
              k.contains('blob') ||
              k.contains('pcm') ||
              k.contains('wav'),
          isFalse,
          reason: 'unexpected blob key: $key',
        );
      }
    });

    test('golden: exact EventIn JSON is pinned', () {
      final encoded =
          const JsonEncoder.withIndent('  ').convert(buildPayload().toJson());
      final golden = File('test/golden/event_payload.json').readAsStringSync();
      expect(encoded.trim(), golden.trim());
    });
  });
}
