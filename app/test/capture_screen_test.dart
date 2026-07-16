// Cycle 8b — CaptureScreen: the single-screen M1 UI, driven by a CaptureViewModel
// (CaptureController implements it). Widget tests use FakeCaptureController with
// fixed snapshot values — no real pipeline, no timers, no Future.delayed.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/capture/capture_controller.dart';
import 'package:fsd_app/ui/capture_screen.dart';

import 'support/capture_fakes.dart';

void main() {
  Widget wrap(CaptureViewModel controller) =>
      MaterialApp(home: CaptureScreen(controller: controller));

  testWidgets('test_shows_start_button_when_idle', (tester) async {
    await tester.pumpWidget(wrap(FakeCaptureController()));

    expect(find.text('START TRIP'), findsOneWidget);
    expect(find.text('END TRIP'), findsNothing);
  });

  testWidgets('test_shows_recording_state', (tester) async {
    await tester.pumpWidget(wrap(FakeCaptureController(
      state: CaptureState.recording,
      elapsed: const Duration(minutes: 14, seconds: 32),
    )));

    expect(find.text('RECORDING'), findsOneWidget);
    expect(find.text('00:14:32'), findsOneWidget); // HH:MM:SS trip timer
    expect(find.text('END TRIP'), findsOneWidget);
    expect(find.text('START TRIP'), findsNothing);
  });

  testWidgets('test_shows_flash_state', (tester) async {
    // flashActive → the recording status indicator paints the flash color.
    await tester.pumpWidget(wrap(FakeCaptureController(
      state: CaptureState.recording,
      flashActive: true,
    )));
    var indicator = tester.widget<Container>(
      find.byKey(const Key('status-indicator')),
    );
    expect(indicator.color, CaptureScreen.flashColor);

    // not flashing → back to the normal status color.
    await tester.pumpWidget(wrap(FakeCaptureController(
      state: CaptureState.recording,
      flashActive: false,
    )));
    indicator = tester.widget<Container>(
      find.byKey(const Key('status-indicator')),
    );
    expect(indicator.color, CaptureScreen.statusColor);
  });

  testWidgets('test_shows_last_event', (tester) async {
    await tester.pumpWidget(wrap(FakeCaptureController(
      state: CaptureState.recording,
      lastEvent: LastEvent(
        keyword: 'mark level three',
        severity: 3,
        at: DateTime.utc(2026, 7, 10, 12),
      ),
      sinceLastEvent: const Duration(seconds: 12),
      elapsed: const Duration(seconds: 30),
    )));

    expect(find.textContaining('mark level three'), findsOneWidget);
    expect(find.text('level 3'), findsOneWidget); // severity chip label
    expect(find.textContaining('12 seconds ago'), findsOneWidget);
  });

  testWidgets('test_shows_pending_counts', (tester) async {
    await tester.pumpWidget(wrap(FakeCaptureController(
      state: CaptureState.recording,
      pendingEvents: 2,
      pendingSegments: 1,
      elapsed: const Duration(seconds: 5),
    )));

    expect(find.textContaining('2 events'), findsOneWidget);
    expect(find.textContaining('1 segment'), findsOneWidget);
  });

  testWidgets('test_start_button_calls_controller', (tester) async {
    final controller = FakeCaptureController();
    await tester.pumpWidget(wrap(controller));

    await tester.tap(find.text('START TRIP'));
    await tester.pump();

    expect(controller.startTripCalls, 1);
  });

  testWidgets('test_end_button_calls_controller', (tester) async {
    final controller = FakeCaptureController(state: CaptureState.recording);
    await tester.pumpWidget(wrap(controller));

    await tester.tap(find.text('END TRIP'));
    await tester.pump();

    expect(controller.endTripCalls, 1);
  });

  testWidgets('test_shows_uploading_state', (tester) async {
    await tester
        .pumpWidget(wrap(FakeCaptureController(state: CaptureState.uploading)));

    expect(find.text('UPLOADING…'), findsOneWidget);
    expect(find.text('START TRIP'), findsNothing);
    expect(find.text('END TRIP'), findsNothing);
  });

  testWidgets('test_shows_done_state', (tester) async {
    await tester
        .pumpWidget(wrap(FakeCaptureController(state: CaptureState.done)));

    expect(find.text('Upload complete'), findsOneWidget);
  });

  testWidgets('test_done_state_shows_new_trip_button', (tester) async {
    await tester
        .pumpWidget(wrap(FakeCaptureController(state: CaptureState.done)));

    expect(find.text('NEW TRIP'), findsOneWidget);
  });

  testWidgets('test_new_trip_button_resets_to_start', (tester) async {
    final controller = FakeCaptureController(state: CaptureState.done);
    await tester.pumpWidget(wrap(controller));

    await tester.tap(find.text('NEW TRIP'));
    await tester.pump();

    expect(controller.resetCalls, 1);
  });
}
