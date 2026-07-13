// lib/upload/http_ingest_client.dart
//
// Cycle 5 — the real IngestClient (Contract 2). POSTs metadata to the ingest API
// with the Firebase bearer token and the Idempotency-Key header, and parses the
// signed-URL response. Tested against the shelf stub; at Checkpoint 2 only the
// injected baseUrl changes to Person C's Cloud Run URL.

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../capture/ports.dart';

/// A non-2xx response from the ingest API.
class IngestException implements Exception {
  IngestException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() => 'IngestException($statusCode): $body';
}

class HttpIngestClient implements IngestClient {
  HttpIngestClient({
    required this.baseUrl,
    required this.tokenSource,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String baseUrl;
  final TokenSource tokenSource;
  final http.Client _http;

  /// Fail fast if the ingest URL is still the Checkpoint-2 placeholder, rather
  /// than silently attempting (and swallowing) a broken upload.
  void _requireConfigured() {
    if (baseUrl.isEmpty || baseUrl.contains('TODO')) {
      throw StateError(
        'Ingest base URL is not configured (still "$baseUrl"). Set the real '
        'Cloud Run URL from Person C (Checkpoint 2) in config.v1.json.',
      );
    }
  }

  /// Build headers, fetching a fresh ID token per request (tokens expire).
  Future<Map<String, String>> _headers({String? idempotencyKey}) async => {
        'authorization': 'Bearer ${await tokenSource.idToken()}',
        'content-type': 'application/json',
        'idempotency-key': ?idempotencyKey,
      };

  @override
  Future<UploadUrls> postEvent(
    EventPayload e, {
    required String idempotencyKey,
  }) async {
    _requireConfigured();
    final resp = await _http.post(
      Uri.parse('$baseUrl/v1/events'),
      headers: await _headers(idempotencyKey: idempotencyKey),
      body: jsonEncode(e.toJson()),
    );
    if (resp.statusCode != 200) {
      throw IngestException(resp.statusCode, resp.body);
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return UploadUrls(
      audioUpload: json['audio_upload'] as String,
      sensorUpload: json['sensor_upload'] as String,
    );
  }

  @override
  Future<void> postBreadcrumb(
    BreadcrumbPayload b, {
    required String idempotencyKey,
  }) async {
    _requireConfigured();
    final resp = await _http.post(
      Uri.parse('$baseUrl/v1/breadcrumbs'),
      headers: await _headers(idempotencyKey: idempotencyKey),
      body: jsonEncode(b.toJson()),
    );
    if (resp.statusCode != 200) {
      throw IngestException(resp.statusCode, resp.body);
    }
  }

  @override
  Future<void> postTrip(TripPayload t) async {
    _requireConfigured();
    final resp = await _http.post(
      Uri.parse('$baseUrl/v1/trips'),
      headers: await _headers(),
      body: jsonEncode(t.toJson()),
    );
    if (resp.statusCode != 200) {
      throw IngestException(resp.statusCode, resp.body);
    }
  }

  void close() => _http.close();
}
