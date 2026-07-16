// lib/ui/capture_screen.dart
//
// Cycle 8b — the single M1 capture screen. Binds to a CaptureViewModel via
// ListenableBuilder (CaptureController implements it; widget tests use a fake).
// Stateless: it renders the controller's current snapshot. The live per-second
// tick of the trip timer is driven by the controller (deferred — see check-in);
// no timers or Future.delayed live in this widget.

import 'package:flutter/material.dart';

import '../capture/capture_controller.dart';
import 'severity_colors.dart';

class CaptureScreen extends StatelessWidget {
  const CaptureScreen({required this.controller, super.key});

  final CaptureViewModel controller;

  /// The recording status indicator flashes this color when a keyword fires.
  static const Color flashColor = Color(0xFFFFF176); // bright yellow
  static const Color statusColor = Color(0xFF2E7D32); // normal recording green

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ListenableBuilder(
              listenable: controller,
              builder: (context, _) => _body(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    switch (controller.state) {
      case CaptureState.idle:
        return _idle();
      case CaptureState.recording:
        return _recording(context);
      case CaptureState.uploading:
        return _centered('UPLOADING…');
      case CaptureState.done:
        return _done();
    }
  }

  Widget _done() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        const Text('Upload complete'),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: controller.reset,
          child: const Text('NEW TRIP'),
        ),
      ],
    );
  }

  Widget _idle() {
    return FilledButton(
      onPressed: controller.startTrip,
      child: const Text('START TRIP'),
    );
  }

  Widget _recording(BuildContext context) {
    final event = controller.lastEvent;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Container(
          key: const Key('status-indicator'),
          color: controller.flashActive ? flashColor : statusColor,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: const Text('RECORDING'),
        ),
        Text(_formatElapsed(controller.elapsed)),
        const SizedBox(height: 24),
        if (event != null) _lastEvent(event),
        const SizedBox(height: 24),
        Text(_queued()),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: controller.endTrip,
          child: const Text('END TRIP'),
        ),
      ],
    );
  }

  Widget _lastEvent(LastEvent event) {
    final since = controller.sinceLastEvent;
    return Column(
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text('Last event: ${event.keyword ?? 'tap'}'),
            const SizedBox(width: 8),
            Chip(
              label: Text(severityLabel(event.severity)),
              backgroundColor: severityColor(event.severity),
            ),
          ],
        ),
        if (since != null) Text('${since.inSeconds} seconds ago'),
      ],
    );
  }

  String _queued() {
    final e = controller.pendingEvents;
    final s = controller.pendingSegments;
    return 'Queued: $e ${_plural(e, 'event')} · $s ${_plural(s, 'segment')}';
  }

  Widget _centered(String text) => Text(text);

  static String _plural(int n, String noun) => n == 1 ? noun : '${noun}s';

  static String _formatElapsed(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}
