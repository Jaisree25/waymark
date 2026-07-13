// lib/upload/uploader.dart
//
// Cycle 5 — the resumable upload client. Drains the outbox: for each pending
// event it POSTs the metadata (getting signed URLs), PUTs the audio/sensor blobs
// to those URLs, and only THEN marks the row done. It is:
//   * offline-durable — reads pending rows from the drift outbox (Cycle 4);
//   * idempotent — a done row is never re-posted; the Idempotency-Key = event UUID;
//   * Wi-Fi-preferred — gated on connectivity + config;
//   * fail-safe — any failure sends the row back to pending (attempts++), so an
//     event that POSTed but whose blob PUT failed is retried, not lost.

import 'dart:convert';

import '../capture/ports.dart';
import '../store/app_database.dart';
import '../store/queue_state_machine.dart';
import 'upload_ports.dart';

/// What the CaptureController needs from the uploader: drain the outbox. The
/// controller depends on this narrow seam so widget/controller tests can fake it.
abstract class OutboxUploader {
  Future<void> flushEvents();
}

class Uploader implements OutboxUploader {
  Uploader({
    required this.client,
    required this.blobs,
    required this.blobSource,
    required this.net,
    required this.db,
    this.requireWifi = true,
  });

  final IngestClient client;
  final BlobUploader blobs;
  final BlobSource blobSource;
  final ConnectivityPort net;
  final AppDatabase db;
  final bool requireWifi;

  /// Upload all pending events. A row is marked done ONLY after both the POST
  /// and the blob PUTs succeed; any failure returns it to pending.
  @override
  Future<void> flushEvents() async {
    final state = net.current();
    if (!state.isConnected) return;
    // Wi-Fi-preferred: when Wi-Fi is required but we're on cellular, leave the
    // rows queued rather than uploading.
    if (requireWifi && !state.isWifi) return;

    for (final row in await db.pendingEvents()) {
      await db.applyEvent(row.id, QueueEvent.uploadStarted);
      try {
        final payload = EventPayload.fromJson(
          jsonDecode(row.payloadJson) as Map<String, dynamic>,
        );
        // Idempotency-Key = the event UUID (row.id).
        final urls = await client.postEvent(payload, idempotencyKey: row.id);

        // Blobs go to the signed URLs, never inline in the POST body.
        final blob = await blobSource.blobsFor(row.id);
        await blobs.put(urls.audioUpload, blob.audio);
        await blobs.put(urls.sensorUpload, blob.sensor);

        // Only now — POST + both blob PUTs succeeded — is the row done.
        await db.applyEvent(row.id, QueueEvent.uploadSucceeded);
      } catch (e) {
        await db.applyEvent(row.id, QueueEvent.uploadFailed, error: e.toString());
      }
    }
  }
}
