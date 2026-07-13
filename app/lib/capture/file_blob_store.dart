// lib/capture/file_blob_store.dart
//
// Cycle 9a — the real BlobStore: writes an event's audio window to the app
// documents directory as <eventId>.wav and returns the file path. The uploader's
// FileBlobSource reads the same directory. Device only; tests use FakeBlobStore.

import 'dart:io';

import 'package:path/path.dart' as p;

import 'ports.dart';

class FileBlobStore implements BlobStore {
  const FileBlobStore(this.dir);

  final Directory dir;

  @override
  Future<String> writeAudio(String eventId, List<int> bytes) async {
    final file = File(p.join(dir.path, '$eventId.wav'));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return file.path;
  }
}
