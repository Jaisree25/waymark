// lib/store/queue_state_machine.dart
//
// Cycle 4 — the outbox queue as a PURE state machine (no drift, no SQLite). The
// drift layer merely persists the status this function computes, so the legal
// transitions are unit-tested in isolation.
//
//   pending   + uploadStarted   -> uploading
//   uploading + uploadSucceeded -> done
//   uploading + uploadFailed    -> pending   (retry)
//
// Anything else throws, so a row can never skip a state (bugs are loud).

/// Where an outbox row is in its lifecycle.
enum QueueStatus { pending, uploading, done }

/// What just happened to a row.
enum QueueEvent { uploadStarted, uploadSucceeded, uploadFailed }

/// The pure transition function. Throws [StateError] on any illegal move.
QueueStatus transition(QueueStatus current, QueueEvent event) {
  return switch ((current, event)) {
    (QueueStatus.pending, QueueEvent.uploadStarted) => QueueStatus.uploading,
    (QueueStatus.uploading, QueueEvent.uploadSucceeded) => QueueStatus.done,
    (QueueStatus.uploading, QueueEvent.uploadFailed) => QueueStatus.pending,
    _ => throw StateError(
        'illegal outbox transition: ${current.name} + ${event.name}. '
        'Valid: pending+uploadStarted→uploading, '
        'uploading+uploadSucceeded→done, uploading+uploadFailed→pending',
      ),
  };
}
