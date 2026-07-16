// Cycle 9b — the KWS asset extractor. sherpa opens the model as real files, so
// the bundled ONNX assets must be copied out of Flutter's asset bundle into a
// filesystem directory once (idempotent across restarts). Pure Dart with a fake
// AssetBundle — no device.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show CachingAssetBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/capture/kws_asset_extractor.dart';
import 'package:path/path.dart' as p;

/// A fake AssetBundle backed by an in-memory map; counts load() calls so the
/// idempotent test can prove the second extraction re-reads nothing.
class FakeAssetBundle extends CachingAssetBundle {
  FakeAssetBundle(this._assets);

  final Map<String, List<int>> _assets;
  int loadCalls = 0;

  @override
  Future<ByteData> load(String key) async {
    loadCalls++;
    final bytes = _assets[key];
    if (bytes == null) throw StateError('missing asset: $key');
    return ByteData.sublistView(Uint8List.fromList(bytes));
  }
}

FakeAssetBundle _bundleWithModel() => FakeAssetBundle({
      for (final name in KwsAssetExtractor.assetFiles)
        '${KwsAssetExtractor.assetDir}/$name': const [1, 2, 3],
    });

void main() {
  test('test_extractor_copies_files', () async {
    final dir = await Directory.systemTemp.createTemp('kws_extract');
    final bundle = _bundleWithModel();

    final path = await KwsAssetExtractor.ensureExtracted(bundle, dir);

    expect(path, dir.path);
    for (final name in KwsAssetExtractor.assetFiles) {
      expect(File(p.join(dir.path, name)).existsSync(), isTrue, reason: name);
    }

    await dir.delete(recursive: true);
  });

  test('test_extractor_is_idempotent', () async {
    final dir = await Directory.systemTemp.createTemp('kws_extract');
    final bundle = _bundleWithModel();

    await KwsAssetExtractor.ensureExtracted(bundle, dir);
    final loadsAfterFirst = bundle.loadCalls;
    expect(loadsAfterFirst, KwsAssetExtractor.assetFiles.length);

    // Second call must not re-read or overwrite existing files.
    await KwsAssetExtractor.ensureExtracted(bundle, dir);
    expect(bundle.loadCalls, loadsAfterFirst);

    await dir.delete(recursive: true);
  });
}
