// lib/ui/severity_colors.dart
//
// Cycle 8b — the M1 severity → risk-band color map. Const of record: a new
// severity value added later must be added here too, and severity_colors_test.dart
// fails loudly if the key set drifts (so we never silently render a wrong color).

import 'package:flutter/material.dart';

const Map<int?, Color> severityColors = <int?, Color>{
  null: Colors.grey, // "log it" → logged, no 1–5 level
  1: Colors.green,
  2: Colors.lightGreen,
  3: Colors.yellow,
  4: Colors.orange,
  5: Colors.red, // level 5 / scary
};

/// The chip color for a severity (grey fallback for anything unmapped).
Color severityColor(int? severity) => severityColors[severity] ?? Colors.grey;

/// The chip label: null → "logged", N → "level N".
String severityLabel(int? severity) =>
    severity == null ? 'logged' : 'level $severity';
