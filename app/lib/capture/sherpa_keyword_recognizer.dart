// lib/capture/sherpa_keyword_recognizer.dart
//
// Cycle 7, Step 2 — the ONLY file that touches the real sherpa_onnx model. It
// implements the KeywordRecognizer port using the on-device keyword spotter.
// Every unit test uses FakeKeywordRecognizer instead; this class is exercised
// only on a physical phone (Cycle 7 device run).
//
// The keyword list comes from keyword_config.dart — it is never hardcoded here,
// so the recognizer and the trigger pipeline share exactly one grammar.
//
// The KWS model (sherpa-onnx-kws-zipformer-gigaspeech) is bundled under
// assets/models/kws/. On device, copy those assets to a filesystem directory and
// pass its path as [modelDir] (sherpa reads real file paths, not rootBundle).

import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'kws_asset_extractor.dart';
import 'ports.dart';

class SherpaKeywordRecognizer implements KeywordRecognizer {
  SherpaKeywordRecognizer._(this._spotter, this._stream);

  final sherpa.KeywordSpotter _spotter;
  final sherpa.OnlineStream _stream;

  /// Build a recognizer from the bundled KWS model directory. Keyword list and
  /// thresholds are config-driven.
  static Future<SherpaKeywordRecognizer> create({
    required String modelDir,
    double keywordsThreshold = 0.25,
    double keywordsScore = 1.0,
  }) async {
    sherpa.initBindings();

    final config = sherpa.KeywordSpotterConfig(
      model: sherpa.OnlineModelConfig(
        transducer: sherpa.OnlineTransducerModelConfig(
          encoder: p.join(modelDir, KwsAssetExtractor.encoder),
          decoder: p.join(modelDir, KwsAssetExtractor.decoder),
          joiner: p.join(modelDir, KwsAssetExtractor.joiner),
        ),
        tokens: p.join(modelDir, KwsAssetExtractor.tokens),
        numThreads: 1,
        modelType: 'zipformer2',
      ),
      // sherpa reads keywords from a BPE-tokenized file (keywords.txt), NOT the
      // plain strings in keyword_config.dart. keyword_config.dart remains the
      // source of truth for severity/features; the two are intentionally
      // separate. See assets/models/kws/README.md for the token format.
      keywordsFile: p.join(modelDir, KwsAssetExtractor.keywords),
      keywordsScore: keywordsScore,
      keywordsThreshold: keywordsThreshold,
    );

    final spotter = sherpa.KeywordSpotter(config);
    return SherpaKeywordRecognizer._(spotter, spotter.createStream());
  }

  @override
  String? decode(AudioFrame frame) {
    _stream.acceptWaveform(
      samples: _pcm16ToFloat32(frame.pcm),
      sampleRate: frame.sampleRateHz,
    );
    while (_spotter.isReady(_stream)) {
      _spotter.decode(_stream);
    }
    final keyword = _spotter.getResult(_stream).keyword;
    if (keyword.isEmpty) return null;
    _spotter.reset(_stream); // don't re-fire on the same detection
    // sherpa returns the detokenized phrase (e.g. "MARK LEVEL THREE"); normalize
    // to match keyword_config.dart's lowercase keys for severity/features lookup.
    return keyword.trim().toLowerCase();
  }

  /// Release native resources.
  void dispose() {
    _stream.free();
    _spotter.free();
  }

  /// Convert little-endian PCM16 bytes to normalized [-1, 1] float samples.
  static Float32List _pcm16ToFloat32(Uint8List pcm) {
    final data = ByteData.sublistView(pcm);
    final count = pcm.lengthInBytes ~/ 2;
    final out = Float32List(count);
    for (var i = 0; i < count; i++) {
      out[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }
}
