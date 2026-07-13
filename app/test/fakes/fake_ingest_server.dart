// Test-only stub of Contract 2 (the ingest API). Returns the EXACT shapes from
// contracts/openapi.yaml so the uploader is tested against the real wire format.
// At Checkpoint 2 this is swapped for Person C's real Cloud Run URL — the
// uploader code doesn't change, only the injected baseUrl.
//
// This is an in-process localhost server (allowed in tests); no external network.

import 'dart:convert';
import 'dart:io' show HttpServer;

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';

class FakeIngestServer {
  late HttpServer _server;

  /// Decoded request bodies, in arrival order.
  final List<Map<String, dynamic>> eventsReceived = [];
  final List<Map<String, dynamic>> breadcrumbsReceived = [];
  final List<Map<String, dynamic>> tripsReceived = [];

  /// The Idempotency-Key header seen on each accepted event POST.
  final List<String> eventIdempotencyKeys = [];

  /// The Authorization header seen on each accepted event POST.
  final List<String?> eventAuthHeaders = [];

  /// When > 0, the next N `POST /v1/events` calls return 500 (then decrement) —
  /// used to exercise the uploader's retry-on-server-failure path.
  int failEventsTimes = 0;

  Future<String> start() async {
    final router = Router()
      ..get('/healthz', (Request r) => _json({'status': 'ok'}))
      ..post('/v1/trips', (Request r) async {
        tripsReceived.add(
          json.decode(await r.readAsString()) as Map<String, dynamic>,
        );
        return _json({'ok': true});
      })
      ..post('/v1/events', (Request r) async {
        if (r.headers['idempotency-key'] == null) {
          return Response(400, body: 'Missing Idempotency-Key');
        }
        if (failEventsTimes > 0) {
          failEventsTimes--;
          return Response(500, body: 'simulated server failure');
        }
        eventIdempotencyKeys.add(r.headers['idempotency-key']!);
        eventAuthHeaders.add(r.headers['authorization']);
        eventsReceived.add(
          json.decode(await r.readAsString()) as Map<String, dynamic>,
        );
        return _json({
          'audio_upload':
              'https://storage.googleapis.com/fake-bucket/audio.wav?sig=fake',
          'sensor_upload':
              'https://storage.googleapis.com/fake-bucket/sensors.json?sig=fake',
        });
      })
      ..post('/v1/breadcrumbs', (Request r) async {
        if (r.headers['idempotency-key'] == null) {
          return Response(400, body: 'Missing Idempotency-Key');
        }
        breadcrumbsReceived.add(
          json.decode(await r.readAsString()) as Map<String, dynamic>,
        );
        return _json({'ok': true});
      });

    _server = await io.serve(router.call, 'localhost', 0); // port 0 = OS picks
    return 'http://localhost:${_server.port}';
  }

  Future<void> stop() => _server.close(force: true);

  Response _json(Object body) => Response.ok(
        json.encode(body),
        headers: {'content-type': 'application/json'},
      );
}
