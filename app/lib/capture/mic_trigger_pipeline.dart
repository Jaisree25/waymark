// lib/capture/mic_trigger_pipeline.dart
//
// Cycle 8d — the real TriggerPipeline: wires MicSource → RingBuffer → VoiceTrigger
// and exposes the assembled Events as a stream for the CaptureController. Device
// only; controller unit tests use FakeTriggerPipeline.

import 'dart:async';

import 'capture_controller.dart' show TriggerPipeline;
import 'event.dart';
import 'ports.dart';
import 'ring_buffer.dart';
import 'voice_trigger.dart';

class MicTriggerPipeline implements TriggerPipeline {
  MicTriggerPipeline({
    required this.mic,
    required KeywordRecognizer recognizer,
    required Clock clock,
    required Duration tPre,
    required Duration tPost,
    required Duration ringCapacity,
    Duration debounce = const Duration(seconds: 2),
    GpsFix? Function()? currentFix,
  }) {
    final ring = RingBuffer<AudioFrame>(capacity: ringCapacity, clock: clock);
    _trigger = VoiceTrigger(
      recognizer: recognizer,
      audioBuffer: ring,
      clock: clock,
      tPre: tPre,
      tPost: tPost,
      debounce: debounce,
      onEvent: _events.add,
      onDetected: _detections.add,
      currentFix: currentFix,
    );
  }

  final MicSource mic;
  final StreamController<Event> _events = StreamController<Event>.broadcast();
  final StreamController<KeywordDetection> _detections =
      StreamController<KeywordDetection>.broadcast();
  late final VoiceTrigger _trigger;
  StreamSubscription<AudioFrame>? _sub;

  @override
  Stream<KeywordDetection> get detections => _detections.stream;

  @override
  Stream<Event> get events => _events.stream;

  @override
  Future<void> start() async {
    _sub = mic.frames().listen(_trigger.onFrame);
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  @override
  Future<Event?> flush() async => _trigger.flushPending();

  Future<void> dispose() async {
    await stop();
    await _events.close();
    await _detections.close();
  }
}
