// lib/capture/capture_controller.dart
//
// Cycle 8a — the single object that owns a trip's running state and wires the
// (already-built) pipeline together. Pure logic: no widgets, no BuildContext.
// Extends ChangeNotifier so the screen rebuilds on every state change.
//
// This cycle adds NO capture logic — it orchestrates TripController, the trigger
// pipeline, the outbox, and the uploader that Cycles 1–7 already built and proved.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../metrics/capture_reliability_collector.dart';
import '../metrics/feasibility_metrics.dart';
import '../metrics/thermal_collector.dart';
import '../store/app_database.dart';
import '../upload/uploader.dart';
import 'breadcrumb_logger.dart';
import 'event.dart';
import 'location_tracker.dart';
import 'ports.dart';
import 'trip_controller.dart';

/// The screen's high-level state.
enum CaptureState { idle, recording, uploading, done }

/// A snapshot of the most recent triggered event, for the "last event" readout.
class LastEvent {
  const LastEvent({required this.keyword, required this.severity, required this.at});

  final String? keyword;
  final int? severity;
  final DateTime at;
}

/// The trip metadata stamped at start (from config / the app build).
class TripStartConfig {
  const TripStartConfig({
    required this.userId,
    required this.provider,
    required this.supervision,
    required this.appVersion,
    required this.configVersion,
  });

  final String userId;
  final String provider;
  final bool supervision;
  final String appVersion;
  final String configVersion;
}

/// The voice-trigger pipeline as the controller sees it: start/stop capture and a
/// stream of assembled events. The real implementation (MicSource → RingBuffer →
/// VoiceTrigger) is wired in 8d; tests use a fake.
abstract class TriggerPipeline {
  /// Immediate keyword-recognized signals (for chime/flash/last-event).
  Stream<KeywordDetection> get detections;

  /// Finalized events with the full captured window (for persistence).
  Stream<Event> get events;
  Future<void> start();
  Future<void> stop();

  /// Finalize any in-flight capture immediately (partial post-roll), returning
  /// it so the caller can persist it before teardown. Null if nothing pending.
  /// Called on trip end so a capture mid-post-roll isn't dropped.
  Future<Event?> flush();
}

/// The read + action surface the UI binds to. CaptureController implements it;
/// CaptureScreen depends on this (not the concrete controller) so widget tests
/// use a lightweight FakeCaptureController.
abstract class CaptureViewModel implements Listenable {
  CaptureState get state;
  LastEvent? get lastEvent;
  Duration? get sinceLastEvent;
  int get pendingEvents;
  int get pendingSegments;
  Duration get elapsed;
  bool get flashActive;
  bool get permissionDenied;
  Future<void> startTrip();
  Future<void> endTrip();
  void reset();
}

class CaptureController extends ChangeNotifier implements CaptureViewModel {
  CaptureController({
    required this.trip,
    required this.trigger,
    required this.uploader,
    required this.db,
    required this.clock,
    required this.chime,
    required this.blobStore,
    required this.permissions,
    required this.locationTracker,
    required this.thermalSource,
    required this.tripConfig,
    this.flashDuration = const Duration(milliseconds: 800),
    String Function()? generateId,
  }) : _generateId = generateId ?? _uuidStub {
    // Listen from construction so signals arriving outside a recording session
    // are seen and ignored (guarded). Detections drive immediate UI feedback;
    // finalized events drive persistence.
    _detectionSub = trigger.detections.listen(_onDetection);
    _sub = trigger.events.listen(_onEvent);
  }

  final TripController trip;
  final TriggerPipeline trigger;
  final OutboxUploader uploader;
  final AppDatabase db;
  final Clock clock;
  final ChimePlayer chime;
  final BlobStore blobStore;
  final PermissionRequester permissions;
  final LocationTracker locationTracker;
  final ThermalSource thermalSource;
  final TripStartConfig tripConfig;
  final Duration flashDuration;
  final String Function() _generateId;

  CaptureState _state = CaptureState.idle;
  LastEvent? _lastEvent;
  int _pendingEvents = 0;
  int _pendingSegments = 0;
  final BreadcrumbLogger _breadcrumb = BreadcrumbLogger();
  CaptureReliabilityCollector _reliability = CaptureReliabilityCollector();
  ThermalCollector _thermal = ThermalCollector();

  bool _flashActive = false;
  bool _permissionDenied = false;
  DateTime? _startedAt;
  StreamSubscription<Event>? _sub;
  StreamSubscription<KeywordDetection>? _detectionSub;
  StreamSubscription<ThermalLevel>? _thermalSub;
  Timer? _flashTimer;
  Timer? _tickTimer;

  @override
  CaptureState get state => _state;
  @override
  LastEvent? get lastEvent => _lastEvent;
  @override
  int get pendingEvents => _pendingEvents;
  @override
  int get pendingSegments => _pendingSegments;
  @override
  Duration get elapsed => clock.now().difference(_startedAt ?? clock.now());

  @override
  bool get flashActive => _flashActive;

  /// True if the last startTrip was blocked because the mic permission was denied.
  @override
  bool get permissionDenied => _permissionDenied;

  /// Time since the last event fired (for the "N seconds ago" readout), or null.
  @override
  Duration? get sinceLastEvent =>
      _lastEvent == null ? null : clock.now().difference(_lastEvent!.at);

  /// Open a trip and begin listening for voice triggers. Blocked (stays idle,
  /// no crash) if the mic permission is denied.
  @override
  Future<void> startTrip() async {
    if (!await permissions.requestAudio()) {
      _permissionDenied = true;
      notifyListeners();
      return;
    }
    _permissionDenied = false;
    await permissions.requestLocation(); // best-effort; GPS is not a hard block
    // One GPS subscription serves both event-stamping (currentFix) and the
    // breadcrumb; fixes flow to the logger via the tracker's onFix.
    _breadcrumb.clear();
    locationTracker.onFix = _breadcrumb.add;
    locationTracker.start();
    // Fresh feasibility collectors per trip; thermal reads the platform source.
    _reliability = CaptureReliabilityCollector();
    _thermal = ThermalCollector(clock: clock);
    _thermalSub = thermalSource.states().listen(_thermal.recordThermalState);
    final openTrip = trip.start(
      id: _generateId(),
      userId: tripConfig.userId,
      provider: tripConfig.provider,
      supervision: tripConfig.supervision,
      appVersion: tripConfig.appVersion,
      configVersion: tripConfig.configVersion,
    );
    // Persist the trip row (ended_at null); endTrip updates the same row.
    await db.enqueueTrip(openTrip.toPayload());
    _startedAt = clock.now();
    await trigger.start();
    // Live trip-timer tick: rebuild the UI each second (elapsed reads the clock).
    _tickTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
    _setState(CaptureState.recording);
  }

  /// Immediate feedback the instant a keyword is recognized — chime, flash, and
  /// the on-screen last-event readout. Runs BEFORE the post-roll is captured, so
  /// the passenger gets instant confirmation (not ~t_post later).
  void _onDetection(KeywordDetection detection) {
    if (_state != CaptureState.recording) return;
    _lastEvent = LastEvent(
      keyword: detection.keyword,
      severity: detection.severity,
      at: detection.at,
    );
    // Visual flash: on now, off after flashDuration (Timer-driven so fakeAsync
    // controls it in tests, never Future.delayed).
    _flashActive = true;
    _flashTimer?.cancel();
    _flashTimer = Timer(flashDuration, () {
      _flashActive = false;
      notifyListeners();
    });
    unawaited(chime.play());
    notifyListeners();
  }

  /// The finalized event (full [t_pre, t_post] window). Counts reliability and
  /// persists the blob + payload. No user-facing feedback here — that already
  /// happened at detection time.
  void _onEvent(Event event) {
    if (_state != CaptureState.recording) return;
    _countReliability(event);
    // Persist: write the audio blob locally, build the Contract-2 payload
    // (keyword + audio_ref in features, trigger-time location), enqueue.
    unawaited(_persist(event));
  }

  /// Risk #1: count one "complete" per assembled event (M1 approximation —
  /// see reliability_note in the metrics output). Shared by the normal
  /// finalize path and the end-trip flush.
  void _countReliability(Event event) {
    final preRoll = Duration(milliseconds: (event.tPreSeconds * 1000).round());
    _reliability.recordTrigger(
      hasWindow: event.audioWindow.isNotEmpty,
      actualPreRoll: preRoll,
      expectedPreRoll: preRoll,
    );
  }

  Future<void> _persist(Event event) async {
    final currentTrip = trip.current;
    if (currentTrip == null) return;
    final id = _generateId();
    final audioRef = await blobStore.writeAudio(id, _audioBytes(event.audioWindow));
    final payload = event.toPayload(
      id: id,
      tripId: currentTrip.id,
      features: <String, dynamic>{'audio_ref': audioRef},
    );
    await db.enqueueEvent(payload);
    await refreshPendingCounts();
  }

  static List<int> _audioBytes(List<AudioFrame> frames) =>
      <int>[for (final frame in frames) ...frame.pcm];

  /// Close the trip and drain the outbox. State goes recording → uploading →
  /// done; done only after the uploader completes.
  @override
  Future<void> endTrip() async {
    // Flush a capture still inside its post-roll BEFORE tearing down, so ending
    // the trip mid-capture doesn't silently drop the event. The flushed event
    // has a truncated post-roll but a full pre-roll; persist it (awaited) so it
    // is durably in the outbox before the trip row closes.
    final flushed = await trigger.flush();
    if (flushed != null) {
      _countReliability(flushed);
      await _persist(flushed);
    }
    final closedTrip = trip.stop();
    _tickTimer?.cancel();
    await trigger.stop();
    await locationTracker.stop();
    locationTracker.onFix = null;
    await _thermalSub?.cancel();
    _thermalSub = null;
    await _enqueueBreadcrumb(closedTrip.id);
    // Update the SAME trip row (one row per trip) with its end time + metrics.
    final metrics = feasibilityMetrics(reliability: _reliability, thermal: _thermal);
    await db.updateTripOnEnd(closedTrip.id, closedTrip.endedAt!, metrics);
    _setState(CaptureState.uploading);
    try {
      await uploader.flushEvents();
    } finally {
      _setState(CaptureState.done);
    }
  }

  /// Return to the initial (idle) screen after a completed trip, clearing the
  /// last-event readout so a new trip starts clean.
  @override
  void reset() {
    _state = CaptureState.idle;
    _lastEvent = null;
    notifyListeners();
  }

  Future<void> _enqueueBreadcrumb(String tripId) async {
    if (!_breadcrumb.hasValidSegment) return; // < 2 fixes → no segment (Cycle 3)
    await db.enqueueBreadcrumb(
      _breadcrumb.buildPayload(id: _generateId(), tripId: tripId),
    );
    await refreshPendingCounts();
  }

  /// Refresh the pending event/segment counts from the outbox.
  Future<void> refreshPendingCounts() async {
    _pendingEvents = (await db.pendingEvents()).length;
    _pendingSegments = (await db.pendingBreadcrumbs()).length;
    notifyListeners();
  }

  void _setState(CaptureState next) {
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _detectionSub?.cancel();
    _thermalSub?.cancel();
    _flashTimer?.cancel();
    _tickTimer?.cancel();
    super.dispose();
  }

  // Placeholder id generator for the default (production injects a real UUID in
  // 8d wiring). Deterministic-enough default; tests inject their own.
  static String _uuidStub() =>
      'trip-${DateTime.now().microsecondsSinceEpoch}';
}
