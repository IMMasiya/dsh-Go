// Turn progress for the Android live-update island.
//
// `LiveUpdates` (live_update.dart) is only a bridge: start on the turn's rising
// edge, stop on the falling one. What it never had is the middle — an `update`
// while the turn actually moves — so the island stayed a blank spinner and the
// user could not read progress from it.
//
// This watches one running session's log and folds it into what a lock-screen
// glance needs: which step, what the step is doing, and — when the turn keeps a
// todo list — how much of it is done.
//
// Cheap by design: one passive follow per running session (no activation, no
// assistant deltas; see the WatchOptions at the call site) and at most one
// notification refresh per [_minGap].

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

import 'live_update.dart';

/// At most one island refresh per window: one step emits several log events.
const Duration _minGap = Duration(milliseconds: 900);

/// `edit_file` stays `edit_file`; `filesystem.edit_file` becomes `edit_file`.
String _toolLabel(String name) {
  final trimmed = name.trim();
  final dot = trimmed.lastIndexOf('.');
  return dot >= 0 && dot < trimmed.length - 1 ? trimmed.substring(dot + 1) : trimmed;
}

/// One running turn's progress on the live-update island.
class LiveTurnProgress {
  LiveTurnProgress({
    required this.sessionId,
    required String title,
    required Stream<DshEvent> events,
  }) {
    unawaited(LiveUpdates.start(sessionId: sessionId, title: title));
    _sub = events.listen(_onEvent, onError: (_) {});
  }

  final String sessionId;

  StreamSubscription<DshEvent>? _sub;
  Timer? _pending;
  bool _done = false;

  int _step = 0;
  String _detail = '';
  int? _percent;

  String? _sentText;
  int? _sentPercent;
  DateTime _sentAt = DateTime.fromMillisecondsSinceEpoch(0);

  void _onEvent(DshEvent event) {
    if (_done || event is! SessionLogEvent) return;
    switch (event) {
      case StepStartedEvent(:final step):
        _step = step;
        _detail = '';
      case ToolCallEvent(:final step, :final name):
        if (step > 0) _step = step;
        _detail = _toolLabel(name);
      case TodoWriteEvent(:final todos):
        if (todos.isNotEmpty) {
          final done = todos.where((todo) => todo.status == 'completed').length;
          _percent = ((done * 100) / todos.length).round().clamp(0, 100).toInt();
        }
      case TurnEndedEvent():
        finish();
        return;
      default:
        return;
    }
    _flush();
  }

  String get _text {
    final step = _step > 0 ? '第 $_step 步' : '';
    if (_detail.isEmpty) return step;
    return step.isEmpty ? _detail : '$step · $_detail';
  }

  void _flush() {
    final text = _text;
    if (text == _sentText && _percent == _sentPercent) return;
    final now = DateTime.now();
    final wait = _sentAt.add(_minGap).difference(now);
    if (wait > Duration.zero) {
      _pending ??= Timer(wait, () {
        _pending = null;
        _flush();
      });
      return;
    }
    _sentText = text;
    _sentPercent = _percent;
    _sentAt = now;
    unawaited(LiveUpdates.update(sessionId: sessionId, percent: _percent, text: text));
  }

  /// The turn is over: stop watching and pull the island entry.
  void finish() {
    if (_done) return;
    _done = true;
    _pending?.cancel();
    _pending = null;
    unawaited(_sub?.cancel());
    _sub = null;
    unawaited(LiveUpdates.stop(sessionId: sessionId));
  }
}
