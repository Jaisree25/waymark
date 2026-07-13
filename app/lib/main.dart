// lib/main.dart
//
// Cycle 8d — the composition root: wire every REAL implementation into the
// CaptureController and run the app. This is the only place real hardware/network
// implementations are constructed; it has no unit tests (the pieces it wires are
// all tested behind their ports). See docs/cycle-8-capture-screen.md §8d.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'capture/audioplayers_chime_player.dart';
import 'capture/capture_controller.dart';
import 'capture/file_blob_store.dart';
import 'capture/geolocator_location_source.dart';
import 'capture/kws_asset_extractor.dart';
import 'capture/location_tracker.dart';
import 'capture/mic_trigger_pipeline.dart';
import 'capture/permission_handler_requester.dart';
import 'capture/ports.dart';
import 'capture/record_mic_source.dart';
import 'capture/sherpa_keyword_recognizer.dart';
import 'capture/trip_controller.dart';
import 'config/app_config.dart';
import 'metrics/platform_thermal_source.dart';
import 'store/app_database.dart';
import 'ui/capture_screen.dart';
import 'upload/firebase_token_source.dart';
import 'upload/http_ingest_client.dart';
import 'upload/upload_impls.dart';
import 'upload/uploader.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final config = await AppConfig.load('assets/config/config.v1.json');
  const clock = SystemClock();

  final docs = await getApplicationDocumentsDirectory();
  final db = AppDatabase(
    NativeDatabase(File(p.join(docs.path, 'waymark_outbox.sqlite'))),
  );

  // TODO(Person C): drop in google-services.json / GoogleService-Info.plist and
  // call Firebase.initializeApp() here. Until then FirebaseTokenSource returns ''
  // and uploads get 401 — capture still works fully offline.
  final uploader = Uploader(
    client: HttpIngestClient(
      baseUrl: config.ingestBaseUrl,
      tokenSource: const FirebaseTokenSource(),
    ),
    blobs: HttpBlobUploader(),
    blobSource: FileBlobSource(docs),
    net: ConnectivityPlusPort(),
    db: db,
    requireWifi: config.wifiPreferred,
  );

  // Extract the bundled KWS model to the filesystem so sherpa can open it. If the
  // model isn't bundled yet, the app still launches (UI + timer + chime) with
  // voice triggering disabled (see docs/cycle-7-device-checklist.md).
  final recognizer = await _buildRecognizer(Directory(p.join(docs.path, 'kws')));

  // GPS: the tracker caches the last fix; the trigger stamps it onto events at
  // trigger time (controller starts/stops the tracker with the trip).
  final locationTracker = LocationTracker(const GeolocatorLocationSource());

  final trigger = MicTriggerPipeline(
    mic: RecordMicSource(sampleRateHz: 16000),
    recognizer: recognizer,
    clock: clock,
    tPre: config.tPre,
    tPost: config.tPost,
    ringCapacity: config.ringCapacity,
    currentFix: () => locationTracker.current,
  );

  final chime = AudioplayersChimePlayer(
    config.ui.chimeAsset.replaceFirst('assets/', ''),
  );

  final controller = CaptureController(
    trip: TripController(clock: clock),
    trigger: trigger,
    uploader: uploader,
    db: db,
    clock: clock,
    chime: chime,
    blobStore: FileBlobStore(docs),
    permissions: const PermissionHandlerRequester(),
    locationTracker: locationTracker,
    thermalSource: const PlatformThermalSource(),
    flashDuration: config.ui.flashDuration,
    tripConfig: const TripStartConfig(
      userId: 'device-user',
      provider: 'tesla',
      supervision: true,
      appVersion: '1.0.0+1',
      configVersion: '1.0.0',
    ),
  );

  runApp(WaymarkApp(controller: controller));
}

Future<KeywordRecognizer> _buildRecognizer(Directory kwsDir) async {
  try {
    await KwsAssetExtractor.ensureExtracted(rootBundle, kwsDir);
    return await SherpaKeywordRecognizer.create(modelDir: kwsDir.path);
  } catch (_) {
    return _SilentRecognizer(); // no model bundled yet → voice triggering off
  }
}

/// Fallback recognizer used only when the KWS model is missing; never fires.
class _SilentRecognizer implements KeywordRecognizer {
  @override
  String? decode(AudioFrame frame) => null;
}

class WaymarkApp extends StatelessWidget {
  const WaymarkApp({required this.controller, super.key});

  final CaptureController controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Waymark',
        home: CaptureScreen(controller: controller),
      );
}
