// lib/upload/upload_ports.dart
//
// Cycle 5 — the seams the uploader depends on beyond the IngestClient (Contract
// 2, in capture/ports.dart): the blob PUT, the local blob bytes, and network
// state. All faked in tests so the uploader logic runs offline and deterministic.

/// PUTs blob bytes to a signed URL. Production uses background_downloader / an
/// HTTP PUT; tests record the calls.
abstract class BlobUploader {
  Future<void> put(String url, List<int> bytes);
}

/// The audio + sensor blobs for an event (read from local files on device).
class EventBlobs {
  const EventBlobs({required this.audio, required this.sensor});

  final List<int> audio;
  final List<int> sensor;
}

/// Resolves an event's local blob bytes by id.
abstract class BlobSource {
  Future<EventBlobs> blobsFor(String eventId);
}

/// A snapshot of connectivity.
class NetworkState {
  const NetworkState({required this.isConnected, required this.isWifi});

  final bool isConnected;
  final bool isWifi;
}

/// Reads the current connectivity (production wraps connectivity_plus).
abstract class ConnectivityPort {
  NetworkState current();
}
