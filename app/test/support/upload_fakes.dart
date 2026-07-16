// Test-only fakes for the Cycle 5 upload seams (lib/upload/upload_ports.dart).
// The metadata POST is exercised against the real HttpIngestClient + the shelf
// stub; these fakes stand in for the blob PUT, the local blob bytes, and network
// state so the uploader logic is deterministic and offline.

import 'package:fsd_app/capture/ports.dart';
import 'package:fsd_app/upload/upload_ports.dart';

/// Returns a fixed ID token.
class FakeTokenSource implements TokenSource {
  FakeTokenSource(this.token);

  final String token;

  @override
  Future<String> idToken() async => token;
}

/// Records blob PUTs; can be told to fail the next PUT (to prove a row is not
/// marked done when the blob upload fails).
class FakeBlobUploader implements BlobUploader {
  final List<String> putUrls = [];
  final List<List<int>> putBytes = [];
  bool failNext = false;

  @override
  Future<void> put(String url, List<int> bytes) async {
    if (failNext) {
      failNext = false;
      throw StateError('blob PUT failed');
    }
    putUrls.add(url);
    putBytes.add(bytes);
  }
}

/// Returns canned blob bytes for an event id.
class FakeBlobSource implements BlobSource {
  FakeBlobSource([Map<String, EventBlobs>? blobs]) : _blobs = blobs ?? {};

  final Map<String, EventBlobs> _blobs;

  @override
  Future<EventBlobs> blobsFor(String eventId) async =>
      _blobs[eventId] ?? const EventBlobs(audio: [0], sensor: [0]);
}

/// A settable connectivity state.
class FakeConnectivity implements ConnectivityPort {
  FakeConnectivity(this.state);

  NetworkState state;

  @override
  NetworkState current() => state;
}
