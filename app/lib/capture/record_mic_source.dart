// lib/capture/record_mic_source.dart
//
// Cycle 8d — the real MicSource, wrapping the `record` package's PCM16 stream.
// Device only; unit tests use FakeMicSource-style fakes.

import 'package:record/record.dart';

import 'ports.dart';

class RecordMicSource implements MicSource {
  RecordMicSource({this.sampleRateHz = 16000, AudioRecorder? recorder})
      : _recorder = recorder ?? AudioRecorder();

  final int sampleRateHz;
  final AudioRecorder _recorder;

  @override
  Stream<AudioFrame> frames() async* {
    final stream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRateHz,
        numChannels: 1,
      ),
    );
    yield* stream.map((chunk) => AudioFrame(chunk, sampleRateHz: sampleRateHz));
  }
}
