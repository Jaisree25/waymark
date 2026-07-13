// lib/config/app_config.dart
//
// Cycle 8d — the config-of-record. Every tunable capture/upload/UI value is read
// from config.v1.json (02-flutter-app.md §2), never hardcoded. `AppConfig.parse`
// is pure Dart (unit-tested); `AppConfig.load` reads the bundled asset in the app.

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

class UiConfig {
  const UiConfig({
    required this.flashDurationMs,
    required this.chimeAsset,
    required this.timerUpdateIntervalMs,
  });

  factory UiConfig.parse(Map<String, dynamic> json) => UiConfig(
        flashDurationMs: (json['flash_duration_ms'] as num).toInt(),
        chimeAsset: json['chime_asset'] as String,
        timerUpdateIntervalMs: (json['timer_update_interval_ms'] as num).toInt(),
      );

  final int flashDurationMs;
  final String chimeAsset;
  final int timerUpdateIntervalMs;

  Duration get flashDuration => Duration(milliseconds: flashDurationMs);
}

class AppConfig {
  const AppConfig({
    required this.keywords,
    required this.tPreSeconds,
    required this.tPostSeconds,
    required this.ringCapacitySeconds,
    required this.wifiPreferred,
    required this.ingestBaseUrl,
    required this.ui,
  });

  /// Parse from a JSON string (pure — unit-tested).
  factory AppConfig.parse(String jsonStr) {
    final json = jsonDecode(jsonStr) as Map<String, dynamic>;
    return AppConfig(
      keywords: (json['keywords'] as List).cast<String>(),
      tPreSeconds: (json['t_pre_seconds'] as num).toDouble(),
      tPostSeconds: (json['t_post_seconds'] as num).toDouble(),
      ringCapacitySeconds: (json['ring_capacity_seconds'] as num).toInt(),
      wifiPreferred: json['wifi_preferred'] as bool,
      ingestBaseUrl: json['ingest_base_url'] as String,
      ui: UiConfig.parse(json['ui'] as Map<String, dynamic>),
    );
  }

  /// Load and parse the bundled config asset.
  static Future<AppConfig> load(String assetPath) async =>
      AppConfig.parse(await rootBundle.loadString(assetPath));

  final List<String> keywords;
  final double tPreSeconds;
  final double tPostSeconds;
  final int ringCapacitySeconds;
  final bool wifiPreferred;
  final String ingestBaseUrl;
  final UiConfig ui;

  Duration get tPre => Duration(milliseconds: (tPreSeconds * 1000).round());
  Duration get tPost => Duration(milliseconds: (tPostSeconds * 1000).round());
  Duration get ringCapacity => Duration(seconds: ringCapacitySeconds);
}
