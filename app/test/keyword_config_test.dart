// Cycle 7, Step 1 — the keyword → severity grammar (pure Dart). The config is the
// single source of truth for the keyword list AND the severity each maps to; the
// assembled EventPayload must reflect it (severity, features['keyword'], voice).

import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/capture/event.dart';
import 'package:fsd_app/capture/keyword_config.dart';
import 'package:fsd_app/capture/ports.dart';
import 'package:fsd_app/capture/ring_buffer.dart';
import 'package:fsd_app/capture/voice_trigger.dart';

import 'support/fakes.dart';

void main() {
  const expected = <String, int?>{
    'log it': null,
    'log scary': 5,
    'mark level one': 1,
    'mark level two': 2,
    'mark level three': 3,
    'mark level four': 4,
    'mark level five': 5,
  };

  // Assemble an Event by firing [keyword] through the trigger pipeline.
  Event assembleFor(String keyword) {
    final clock = FakeClock(DateTime.utc(2026, 7, 10, 12));
    final recognizer = FakeKeywordRecognizer();
    final ring = RingBuffer<AudioFrame>(
      capacity: const Duration(seconds: 30),
      clock: clock,
    );
    final events = <Event>[];
    final trigger = VoiceTrigger(
      recognizer: recognizer,
      audioBuffer: ring,
      clock: clock,
      tPre: const Duration(seconds: 2),
      tPost: const Duration(seconds: 2),
      debounce: const Duration(seconds: 5),
      onEvent: events.add,
    );

    for (var i = 0; i < 3; i++) {
      clock.advance(const Duration(seconds: 1));
      trigger.onFrame(audioFrame(i));
    }
    clock.advance(const Duration(seconds: 1));
    recognizer.fire(keyword);
    trigger.onFrame(audioFrame(99));
    for (var i = 0; i < 3; i++) {
      clock.advance(const Duration(seconds: 1));
      trigger.onFrame(audioFrame(100 + i));
    }
    return events.single;
  }

  test('test_keyword_severity_mapping', () {
    // 1. The config map is exactly the agreed grammar.
    expect(keywordSeverities, expected);

    // 2. Each of the seven keywords, assembled through the trigger pipeline,
    //    yields a 'voice' EventPayload with the mapped severity and the keyword
    //    recorded in the features attributes bag.
    for (final entry in expected.entries) {
      final payload = assembleFor(entry.key).toPayload(
        id: 'id-${entry.key}',
        tripId: '22222222-2222-4222-8222-222222222222',
      );
      expect(payload.severity, entry.value, reason: 'severity for "${entry.key}"');
      expect(payload.features['keyword'], entry.key,
          reason: 'features.keyword for "${entry.key}"');
      expect(payload.triggerSource, 'voice',
          reason: 'trigger_source for "${entry.key}"');
    }
  });
}
