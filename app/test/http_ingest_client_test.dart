// Cycle 8d — the ingest base URL is a TODO placeholder until Person C provides
// the real Cloud Run URL (Checkpoint 2). An upload attempted against the
// placeholder must FAIL FAST with a clear error, never silently swallow.

import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/upload/http_ingest_client.dart';

import 'support/fakes.dart';
import 'support/upload_fakes.dart';

void main() {
  test('postEvent fails fast on the TODO placeholder ingest URL', () {
    final client = HttpIngestClient(
      baseUrl: 'TODO_CLOUD_RUN_URL',
      tokenSource: FakeTokenSource('test-token'),
    );

    expect(
      () => client.postEvent(
        eventPayloadFixture(id: '11111111-1111-4111-8111-111111111111'),
        idempotencyKey: '11111111-1111-4111-8111-111111111111',
      ),
      throwsStateError,
    );
  });
}
