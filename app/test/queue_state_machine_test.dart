// Cycle 4 (part 1) — the outbox state machine as a PURE function, no drift, no
// SQLite. Rows move pending → uploading → done, and uploading → pending on a
// failed upload (retry). Every other move is illegal and throws, so a row can
// never skip a state.

import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/store/queue_state_machine.dart';

void main() {
  group('transition (pure outbox state machine)', () {
    test('pending + uploadStarted → uploading', () {
      expect(
        transition(QueueStatus.pending, QueueEvent.uploadStarted),
        QueueStatus.uploading,
      );
    });

    test('uploading + uploadSucceeded → done', () {
      expect(
        transition(QueueStatus.uploading, QueueEvent.uploadSucceeded),
        QueueStatus.done,
      );
    });

    test('uploading + uploadFailed → pending (retry)', () {
      expect(
        transition(QueueStatus.uploading, QueueEvent.uploadFailed),
        QueueStatus.pending,
      );
    });

    group('illegal transitions throw StateError (no skipping / no illegal moves)',
        () {
      const illegal = <(QueueStatus, QueueEvent)>[
        (QueueStatus.pending, QueueEvent.uploadSucceeded), // would skip uploading
        (QueueStatus.pending, QueueEvent.uploadFailed),
        (QueueStatus.uploading, QueueEvent.uploadStarted),
        (QueueStatus.done, QueueEvent.uploadStarted),
        (QueueStatus.done, QueueEvent.uploadSucceeded),
        (QueueStatus.done, QueueEvent.uploadFailed),
      ];

      for (final (status, event) in illegal) {
        test('${status.name} + ${event.name} throws', () {
          expect(() => transition(status, event), throwsStateError);
        });
      }
    });
  });
}
