// Cycle 5 — the resumable upload client, the six behaviors from the stub-server
// skill. The metadata POST runs against the real HttpIngestClient + the shelf
// stub (real wire format); the blob PUT, blob bytes, and network state are faked.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/store/app_database.dart';
import 'package:fsd_app/store/queue_state_machine.dart';
import 'package:fsd_app/upload/http_ingest_client.dart';
import 'package:fsd_app/upload/upload_ports.dart';
import 'package:fsd_app/upload/uploader.dart';

import 'fakes/fake_ingest_server.dart';
import 'support/fakes.dart';
import 'support/upload_fakes.dart';

void main() {
  final t0 = DateTime.utc(2026, 7, 10, 12, 0, 0);

  late FakeIngestServer stub;
  late String baseUrl;
  late AppDatabase db;

  setUp(() async {
    stub = FakeIngestServer();
    baseUrl = await stub.start();
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await stub.stop();
    await db.close();
  });

  Uploader buildUploader({
    bool requireWifi = true,
    NetworkState net = const NetworkState(isConnected: true, isWifi: true),
    BlobUploader? blobs,
    BlobSource? blobSource,
  }) {
    return Uploader(
      client: HttpIngestClient(
        baseUrl: baseUrl,
        tokenSource: FakeTokenSource('test-token'),
      ),
      blobs: blobs ?? FakeBlobUploader(),
      blobSource: blobSource ?? FakeBlobSource(),
      net: FakeConnectivity(net),
      db: db,
      requireWifi: requireWifi,
    );
  }

  // 1. Idempotency on retry: a done event is not re-posted.
  test('event upload is idempotent on retry', () async {
    final payload = eventPayloadFixture(id: '11111111-1111-4111-8111-111111111111');
    await db.enqueueEvent(payload, createdAt: t0);

    final uploader = buildUploader();
    await uploader.flushEvents();
    await uploader.flushEvents(); // retry — the event is already done

    expect(stub.eventsReceived, hasLength(1));
    expect((await db.eventEntry(payload.id))!.status, QueueStatus.done.name);
  });

  // 2. Idempotency-Key header present (= event UUID) — stub 400s without it.
  test('sends the Idempotency-Key header (= event UUID) on the event POST',
      () async {
    final payload = eventPayloadFixture(id: '22222222-2222-4222-8222-222222222222');
    await db.enqueueEvent(payload, createdAt: t0);

    await buildUploader().flushEvents();

    expect(stub.eventIdempotencyKeys, [payload.id]);
    expect((await db.eventEntry(payload.id))!.status, QueueStatus.done.name);
  });

  // 3. Blob PUT to the signed URLs; body carries no blob bytes.
  test('PUTs blobs to the returned signed URLs, not inline in the POST body',
      () async {
    final payload = eventPayloadFixture(id: '33333333-3333-4333-8333-333333333333');
    await db.enqueueEvent(payload, createdAt: t0);

    final blobs = FakeBlobUploader();
    final blobSource = FakeBlobSource({
      payload.id: const EventBlobs(audio: [1, 2, 3], sensor: [4, 5, 6]),
    });
    await buildUploader(blobs: blobs, blobSource: blobSource).flushEvents();

    // Blobs PUT to the exact signed URLs the server returned, in order.
    expect(blobs.putUrls, [
      'https://storage.googleapis.com/fake-bucket/audio.wav?sig=fake',
      'https://storage.googleapis.com/fake-bucket/sensors.json?sig=fake',
    ]);
    expect(blobs.putBytes, [
      [1, 2, 3],
      [4, 5, 6],
    ]);

    // The POST body is metadata only — no blob bytes/keys inline.
    final body = stub.eventsReceived.single;
    for (final key in body.keys) {
      expect(
        key.contains('audio') || key.contains('sensor') || key.contains('blob'),
        isFalse,
        reason: 'unexpected blob key in event body: $key',
      );
    }
  });

  // 4. Wi-Fi gating: with Wi-Fi required but unavailable, don't POST.
  test('does not POST when Wi-Fi is required but unavailable (stays queued)',
      () async {
    final payload = eventPayloadFixture(id: '44444444-4444-4444-8444-444444444444');
    await db.enqueueEvent(payload, createdAt: t0);

    await buildUploader(
      requireWifi: true,
      net: const NetworkState(isConnected: true, isWifi: false),
    ).flushEvents();

    expect(stub.eventsReceived, isEmpty);
    expect((await db.eventEntry(payload.id))!.status, QueueStatus.pending.name);
  });

  // 5. Retry on server failure: 500 leaves the row pending; next flush succeeds.
  test('retries on server failure — pending after 500, done on next flush',
      () async {
    final payload = eventPayloadFixture(id: '55555555-5555-4555-8555-555555555555');
    await db.enqueueEvent(payload, createdAt: t0);

    stub.failEventsTimes = 1; // first POST → 500
    final uploader = buildUploader();

    await uploader.flushEvents();
    final afterFail = (await db.eventEntry(payload.id))!;
    expect(afterFail.status, QueueStatus.pending.name);
    expect(afterFail.attempts, 1);
    expect(stub.eventsReceived, isEmpty);

    await uploader.flushEvents(); // stub now succeeds
    expect((await db.eventEntry(payload.id))!.status, QueueStatus.done.name);
    expect(stub.eventsReceived, hasLength(1));
  });

  // 6. Done only after the blob PUT succeeds (POST alone is not enough).
  test('marks done only after the blob PUT succeeds', () async {
    final payload = eventPayloadFixture(id: '66666666-6666-4666-8666-666666666666');
    await db.enqueueEvent(payload, createdAt: t0);

    final blobs = FakeBlobUploader()..failNext = true; // blob PUT throws
    await buildUploader(blobs: blobs).flushEvents();

    // The POST reached the server, but the blob PUT failed → NOT done.
    expect(stub.eventsReceived, hasLength(1));
    final row = (await db.eventEntry(payload.id))!;
    expect(row.status, QueueStatus.pending.name);
    expect(row.attempts, 1);
  });
}
