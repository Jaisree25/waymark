// lib/capture/kws_asset_extractor.dart
//
// Cycle 9b — copy the bundled KWS model out of Flutter's asset bundle onto the
// filesystem so sherpa can open the files. Idempotent: existing files are left
// alone (cheap restart path). Called from main.dart before
// SherpaKeywordRecognizer.create.
//
// These are the SINGLE SOURCE OF TRUTH for the KWS filenames — both the
// recognizer (which opens them) and the extractor test reference these constants,
// never hardcoded strings.

import 'dart:io';

import 'package:flutter/services.dart' show AssetBundle;
import 'package:path/path.dart' as p;

class KwsAssetExtractor {
  KwsAssetExtractor._();

  static const String assetDir = 'assets/models/kws';

  // sherpa-onnx-kws-zipformer-gigaspeech, real release filenames.
  static const String encoder =
      'encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx';
  static const String decoder =
      'decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx';
  static const String joiner =
      'joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx';
  static const String tokens = 'tokens.txt';

  /// BPE-tokenized keyword list sherpa's KeywordSpotter reads (NOT the plain
  /// strings in keyword_config.dart — that stays the source for severity/features).
  static const String keywords = 'keywords.txt';

  /// Every file bundled under [assetDir] and extracted to the model directory.
  static const List<String> assetFiles = <String>[
    encoder,
    decoder,
    joiner,
    tokens,
    keywords,
  ];

  /// Copy any missing KWS asset into [targetDir]; returns its path. Files that
  /// already exist are not re-read or overwritten.
  static Future<String> ensureExtracted(
    AssetBundle bundle,
    Directory targetDir,
  ) async {
    await targetDir.create(recursive: true);
    for (final name in assetFiles) {
      final dest = File(p.join(targetDir.path, name));
      if (dest.existsSync()) continue; // idempotent
      final data = await bundle.load('$assetDir/$name');
      await dest.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    }
    return targetDir.path;
  }
}
