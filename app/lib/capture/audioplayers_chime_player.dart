// lib/capture/audioplayers_chime_player.dart
//
// Cycle 8d — the real ChimePlayer, wrapping audioplayers. Injected in main.dart;
// never used in unit tests (those use FakeChimePlayer).

import 'package:audioplayers/audioplayers.dart';

import 'ports.dart';

class AudioplayersChimePlayer implements ChimePlayer {
  AudioplayersChimePlayer(this.assetPath, {AudioPlayer? player})
      : _player = player ?? AudioPlayer();

  /// Path relative to the `assets/` root, e.g. `sounds/chime.mp3`.
  final String assetPath;
  final AudioPlayer _player;

  // Play the chime WITHOUT requesting audio focus, so it never interrupts the
  // mic recorder. audioplayers' default (AndroidAudioFocus.gain) fires an
  // AUDIOFOCUS_LOSS at the `record` recorder, which stalls capture right after
  // the first chime — the root cause of "only one event per trip". `none` on
  // Android, plus playAndRecord + mixWithOthers on iOS, lets the chime and the
  // live mic coexist so back-to-back captures keep working.
  final AudioContext _coexistWithMic = AudioContext(
    android: const AudioContextAndroid(audioFocus: AndroidAudioFocus.none),
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.playAndRecord,
      options: const {AVAudioSessionOptions.mixWithOthers},
    ),
  );

  bool _configured = false;

  @override
  Future<void> play() async {
    if (!_configured) {
      await _player.setAudioContext(_coexistWithMic);
      _configured = true;
    }
    await _player.play(AssetSource(assetPath));
  }
}
