// lib/upload/upload_impls.dart
//
// Cycle 8d — real implementations of the upload seams (blob PUT, blob bytes,
// connectivity). Device only; unit tests use the fakes in test/support.

import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'upload_ports.dart';

/// PUTs blob bytes to a signed URL over HTTP.
class HttpBlobUploader implements BlobUploader {
  HttpBlobUploader({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  @override
  Future<void> put(String url, List<int> bytes) async {
    final resp = await _client.put(Uri.parse(url), body: bytes);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw StateError('blob PUT failed (${resp.statusCode}) for $url');
    }
  }
}

/// Reads an event's audio/sensor blob files from a directory (written by the
/// capture pipeline; empty until that wiring lands — see check-in).
class FileBlobSource implements BlobSource {
  const FileBlobSource(this.dir);

  final Directory dir;

  @override
  Future<EventBlobs> blobsFor(String eventId) async {
    final audio = File(p.join(dir.path, '$eventId.wav'));
    final sensor = File(p.join(dir.path, '$eventId.sensors.json'));
    return EventBlobs(
      audio: audio.existsSync() ? await audio.readAsBytes() : const <int>[],
      sensor: sensor.existsSync() ? await sensor.readAsBytes() : const <int>[],
    );
  }
}

/// Caches connectivity_plus state so `current()` can be read synchronously.
class ConnectivityPlusPort implements ConnectivityPort {
  ConnectivityPlusPort([Connectivity? connectivity])
      : _connectivity = connectivity ?? Connectivity() {
    _sub = _connectivity.onConnectivityChanged.listen(_update);
    _connectivity.checkConnectivity().then(_update);
  }

  final Connectivity _connectivity;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  NetworkState _state = const NetworkState(isConnected: false, isWifi: false);

  void _update(List<ConnectivityResult> results) {
    final wifi = results.contains(ConnectivityResult.wifi);
    final connected =
        results.any((r) => r != ConnectivityResult.none);
    _state = NetworkState(isConnected: connected, isWifi: wifi);
  }

  @override
  NetworkState current() => _state;

  Future<void> dispose() async => _sub?.cancel();
}
