// Cycle 7, Step 3 — device integration suite (STUBS). These prove the parts a
// simulator cannot: real mic + cabin noise (risk #1), a real multi-hour drive's
// thermal/capture behavior (risk #4), and events/breadcrumbs reaching the real
// ingest API (Checkpoint 2).
//
// They are deliberately failing stubs: run them ONLY on a physical phone (see
// docs/cycle-7-device-checklist.md). On a simulator/emulator or in CI without a
// device they fail immediately, by design — do not "fix" them by removing fail().
//
// Run (on a plugged-in device):
//   flutter test integration_test/ --device-id <id>

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _needsDevice = 'TODO: run on physical device — not a simulator test';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Risk #1 — the mic actually triggers on a configured keyword in cabin-like
  // noise (HVAC + road noise + conversation).
  testWidgets('test_keyword_fires_in_cabin_noise', (tester) async {
    fail(_needsDevice);
  });

  // Risk #4 — a real 20-minute drive in sun while charging never reaches the
  // `critical` thermal state and drops < 5% of captures.
  testWidgets('test_20_min_drive_no_thermal_critical', (tester) async {
    fail(_needsDevice);
  });

  // Checkpoint 2 — a captured event reaches the real ingest API and lands in
  // Person A's tables.
  testWidgets('test_event_reaches_ingest_api', (tester) async {
    fail(_needsDevice);
  });

  // Checkpoint 2 — a breadcrumb segment reaches the real ingest API.
  testWidgets('test_breadcrumb_reaches_ingest_api', (tester) async {
    fail(_needsDevice);
  });
}
