// Cycle 8b — the severity → color band map (const, config-of-record). Asserting
// it here means a new severity value added later fails loudly instead of
// silently rendering the wrong (or a fallback) color.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/ui/severity_colors.dart';

void main() {
  test('maps each M1 severity band to its color', () {
    expect(severityColors[null], Colors.grey); // "log it" → logged
    expect(severityColors[1], Colors.green);
    expect(severityColors[2], Colors.lightGreen);
    expect(severityColors[3], Colors.yellow);
    expect(severityColors[4], Colors.orange);
    expect(severityColors[5], Colors.red);
  });

  test('covers exactly null and 1..5 (a new value fails loudly)', () {
    expect(severityColors.keys.toSet(), {null, 1, 2, 3, 4, 5});
  });

  test('severityLabel: null → logged, N → level N', () {
    expect(severityLabel(null), 'logged');
    expect(severityLabel(3), 'level 3');
  });
}
