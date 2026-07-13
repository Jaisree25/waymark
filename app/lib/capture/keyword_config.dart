// lib/capture/keyword_config.dart
//
// Cycle 7, Step 1 — the voice command grammar: keyword → severity. This is the
// single source of truth for BOTH the keyword list the recognizer listens for
// and the severity each command encodes. Pure Dart, no device.
//
// (In M2 this becomes config-file driven; in M1 it lives here as a const map so
// the trigger pipeline and the sherpa recognizer share exactly one list.)

/// The M1 keyword grammar. `null` severity means "log, but no 1–5 level".
const Map<String, int?> keywordSeverities = <String, int?>{
  'log it': null,
  'log scary': 5,
  'mark level one': 1,
  'mark level two': 2,
  'mark level three': 3,
  'mark level four': 4,
  'mark level five': 5,
};

/// The keywords the recognizer should listen for (order preserved).
List<String> get configuredKeywords => keywordSeverities.keys.toList();

/// The severity a keyword encodes, or null (unknown keywords also return null).
int? severityForKeyword(String keyword) => keywordSeverities[keyword];

/// Whether [keyword] is part of the configured grammar.
bool isConfiguredKeyword(String keyword) =>
    keywordSeverities.containsKey(keyword);
