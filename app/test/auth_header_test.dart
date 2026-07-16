// Cycle 10e — the upload sends the Firebase ID token as the Bearer auth header,
// fetched per request from a TokenSource (tokens expire).

import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/upload/http_ingest_client.dart';

import 'fakes/fake_ingest_server.dart';
import 'support/fakes.dart';
import 'support/upload_fakes.dart';

void main() {
  late FakeIngestServer stub;
  late String baseUrl;

  setUp(() async {
    stub = FakeIngestServer();
    baseUrl = await stub.start();
  });

  tearDown(() => stub.stop());

  test('test_upload_sends_auth_header', () async {
    final client = HttpIngestClient(
      baseUrl: baseUrl,
      tokenSource: FakeTokenSource('test-token'),
    );

    await client.postEvent(
      eventPayloadFixture(id: '11111111-1111-4111-8111-111111111111'),
      idempotencyKey: '11111111-1111-4111-8111-111111111111',
    );

    expect(stub.eventAuthHeaders.single, 'Bearer test-token');
  });
}
