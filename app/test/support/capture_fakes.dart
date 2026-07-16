// Test-only fakes for Cycle 8a — the CaptureController's collaborators. The
// TriggerPipeline's real impl (MicSource → RingBuffer → VoiceTrigger) is wired in
// 8d; here we push events by hand. The uploader's flush is gated by a Completer
// so the uploading→done transition is observable.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fsd_app/capture/capture_controller.dart';
import 'package:fsd_app/capture/event.dart';
import 'package:fsd_app/capture/ports.dart';
import 'package:fsd_app/metrics/thermal_collector.dart';
import 'package:fsd_app/upload/uploader.dart';

/// Replays a fixed list of thermal states.
class FakeThermalSource implements ThermalSource {
  FakeThermalSource(this._states);

  final List<ThermalLevel> _states;

  @override
  Stream<ThermalLevel> states() => Stream<ThermalLevel>.fromIterable(_states);
}

/// Records chime plays; never touches real audio.
class FakeChimePlayer implements ChimePlayer {
  int playCalls = 0;

  @override
  Future<void> play() async => playCalls++;
}

/// Preset permission grants for tests.
class FakePermissionRequester implements PermissionRequester {
  FakePermissionRequester({this.audioGranted = true, this.locationGranted = true});

  bool audioGranted;
  bool locationGranted;

  @override
  Future<bool> requestAudio() async => audioGranted;

  @override
  Future<bool> requestLocation() async => locationGranted;
}

/// Records blob writes; returns a deterministic reference. No filesystem.
class FakeBlobStore implements BlobStore {
  final List<String> audioIds = [];
  final List<List<int>> audioBytes = [];

  @override
  Future<String> writeAudio(String eventId, List<int> bytes) async {
    audioIds.add(eventId);
    audioBytes.add(bytes);
    return 'blob://audio/$eventId.wav';
  }
}

class FakeTriggerPipeline implements TriggerPipeline {
  final StreamController<Event> _controller =
      StreamController<Event>.broadcast();
  final StreamController<KeywordDetection> _detections =
      StreamController<KeywordDetection>.broadcast();
  bool started = false;

  @override
  Stream<KeywordDetection> get detections => _detections.stream;

  @override
  Stream<Event> get events => _controller.stream;

  /// An in-flight capture the next flush() should surface (tests set this to
  /// simulate ending a trip while a capture is still in its post-roll).
  Event? pendingToFlush;

  @override
  Future<void> start() async => started = true;

  @override
  Future<void> stop() async => started = false;

  @override
  Future<Event?> flush() async {
    final e = pendingToFlush;
    pendingToFlush = null;
    return e;
  }

  /// Simulate the pipeline emitting an assembled (finalized) event.
  void fire(Event e) => _controller.add(e);

  /// Simulate the immediate keyword-detected signal.
  void fireDetection(KeywordDetection d) => _detections.add(d);

  Future<void> dispose() async {
    await _controller.close();
    await _detections.close();
  }
}

class FakeUploader implements OutboxUploader {
  FakeUploader({this.gated = false});

  /// When true, flushEvents blocks until [completeFlush] (to observe the
  /// uploading state). When false (default) it completes immediately.
  final bool gated;
  bool flushCalled = false;
  Completer<void>? _gate;

  @override
  Future<void> flushEvents() {
    flushCalled = true;
    if (!gated) return Future<void>.value();
    final gate = _gate = Completer<void>();
    return gate.future;
  }

  /// Let a gated flush complete (drives uploading → done).
  void completeFlush() => _gate?.complete();
}

/// A fake view-model for CaptureScreen widget tests: settable snapshot values,
/// and counters for the start/end actions. No real pipeline.
class FakeCaptureController extends ChangeNotifier implements CaptureViewModel {
  FakeCaptureController({
    this.state = CaptureState.idle,
    this.lastEvent,
    this.sinceLastEvent,
    this.pendingEvents = 0,
    this.pendingSegments = 0,
    this.elapsed = Duration.zero,
    this.flashActive = false,
    this.permissionDenied = false,
  });

  @override
  CaptureState state;
  @override
  bool flashActive;
  @override
  bool permissionDenied;
  @override
  LastEvent? lastEvent;
  @override
  Duration? sinceLastEvent;
  @override
  int pendingEvents;
  @override
  int pendingSegments;
  @override
  Duration elapsed;

  int startTripCalls = 0;
  int endTripCalls = 0;
  int resetCalls = 0;

  @override
  Future<void> startTrip() async => startTripCalls++;

  @override
  Future<void> endTrip() async => endTripCalls++;

  @override
  void reset() => resetCalls++;
}
