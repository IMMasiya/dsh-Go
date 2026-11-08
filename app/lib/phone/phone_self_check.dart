import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../diagnostics/diagnostics_markdown.dart' show diagnosticsMarkdownBytes;
import '../state/artifacts.dart' show FilesChannel;

const phoneSelfCheckStages = <String>[
  'device', 'channel', 'display', 'input_probe', 'launch', 'tree', 'tap', 'scroll',
  'back', 'text_ascii', 'text_zh', 'capture', 'continuity', 'main', 'ocr', 'cleanup',
];
const _covered = {'device', 'channel', 'display', 'input_probe', 'cleanup'};
const _runStates = {'idle', 'running', 'cleaning', 'done', 'cancelled', 'cleanup_pending'};
const _stepStates = {'not_run', 'running', 'pass', 'fail', 'skipped', 'unknown', 'cancelled'};
const _reasons = {
  'busy', 'unavailable', 'unsupported', 'cancelled', 'retired', 'phoneDisabled', 'locked',
  'channelUnavailable', 'unsupportedPeer', 'invalidResponse', 'cleanupFailed', 'invalidArguments',
  'identityChanged', 'selfCheckAlreadyStarted', 'displayUnsupported', 'displayMissing',
  'releasePending', 'releaseUnconfirmed', 'releaseFailed', 'releaseQueryFailed', 'releaseReceiptRequired',
  'inputWindowNotReady', 'inputUnconfirmed', 'inputRejected', 'inputApiUnavailable',
  'inputProbeCleanupFailed', 'systemOperationDenied', 'deviceUnavailable', 'timeout',
};
String? _reason(Object? value) => value == null ? null : value is String && _reasons.contains(value) ? value : 'other';

/// A fixed UI label category; raw native text never reaches widgets or exports.
String phoneSelfCheckReasonGroup(String? reason) => switch (reason) {
  null => 'none',
  'busy' || 'selfCheckAlreadyStarted' => 'busy',
  'unsupported' || 'unsupportedPeer' || 'inputApiUnavailable' => 'unsupported',
  'cancelled' || 'retired' => 'cancelled',
  'phoneDisabled' => 'disabled',
  'locked' => 'locked',
  'identityChanged' => 'identity',
  'invalidResponse' || 'invalidArguments' => 'invalid',
  'displayUnsupported' || 'displayMissing' => 'display',
  'inputWindowNotReady' || 'inputUnconfirmed' || 'inputRejected' => 'input',
  'cleanupFailed' || 'releasePending' || 'releaseUnconfirmed' || 'releaseFailed' ||
  'releaseQueryFailed' || 'releaseReceiptRequired' || 'inputProbeCleanupFailed' => 'cleanup',
  'systemOperationDenied' => 'denied',
  'timeout' => 'timeout',
  'unavailable' || 'channelUnavailable' || 'deviceUnavailable' => 'unavailable',
  _ => 'other',
};

class PhoneSelfCheckStep {
  const PhoneSelfCheckStep._(this.stage, this.state, this.observed, this.reason, this.durationMs);
  final String stage;
  final String state;
  final bool observed;
  final String? reason;
  final int? durationMs;

  static PhoneSelfCheckStep parse(String stage, Map? value) {
    if (!_covered.contains(stage)) return PhoneSelfCheckStep._(stage, 'not_run', false, null, null);
    if (value == null) return PhoneSelfCheckStep._(stage, 'unknown', false, 'invalidResponse', null);
    final state = value['state'];
    final observed = value['observed'];
    final duration = value['durationMs'];
    if (state is! String || !_stepStates.contains(state) || observed is! bool ||
        duration != null && (duration is! int || duration < 0)) {
      return PhoneSelfCheckStep._(stage, 'unknown', false, 'invalidResponse', null);
    }
    // A claimed pass without an observation cannot be green; not_run never carries evidence.
    if (state == 'pass' && (!observed || value['reason'] != null) || state == 'not_run' && observed) {
      return PhoneSelfCheckStep._(stage, 'unknown', false, 'invalidResponse', null);
    }
    return PhoneSelfCheckStep._(stage, state, observed, _reason(value['reason']), duration as int?);
  }
}

class PhoneSelfCheckSnapshot {
  const PhoneSelfCheckSnapshot._({required this.available, required this.accepted, required this.state,
    required this.steps, this.runHandle, this.reason});
  factory PhoneSelfCheckSnapshot.unavailable() => PhoneSelfCheckSnapshot._(
    available: false, accepted: false, state: 'unknown', reason: 'unavailable',
    steps: List.unmodifiable([for (final stage in phoneSelfCheckStages) PhoneSelfCheckStep.parse(stage, null)]),
  );
  final bool available;
  final bool accepted;
  final String state;
  /// Local action identity only. Never rendered, logged, used as a filename, or exported.
  final String? runHandle;
  final String? reason;
  final List<PhoneSelfCheckStep> steps;
  bool get active => state == 'running' || state == 'cleaning';
  bool get holdsResource => active || state == 'cleanup_pending';

  static PhoneSelfCheckSnapshot parse(Object? value) {
    if (value is! Map || value['v'] is! int || value['v'] != 1 || value['accepted'] is! bool ||
        value['coverage'] != 'partial' || value['state'] is! String || !_runStates.contains(value['state'])) {
      return PhoneSelfCheckSnapshot.unavailable();
    }
    final rawSteps = value['steps'];
    if (rawSteps is! List || rawSteps.length > phoneSelfCheckStages.length) return PhoneSelfCheckSnapshot.unavailable();
    final byStage = <String, Map>{};
    for (final raw in rawSteps) {
      if (raw is! Map || raw['stage'] is! String) return PhoneSelfCheckSnapshot.unavailable();
      final stage = raw['stage'] as String;
      // Unknown future stages have no authority to pass any known stage.
      if (!phoneSelfCheckStages.contains(stage)) continue;
      if (byStage.containsKey(stage)) return PhoneSelfCheckSnapshot.unavailable();
      byStage[stage] = raw;
    }
    final rawHandle = value['runHandle'];
    final handle = rawHandle is String && rawHandle.isNotEmpty && rawHandle.length <= 256 &&
        utf8.encode(rawHandle).length <= 256 ? rawHandle : null;
    final state = value['state'] as String;
    if (rawHandle != null && handle == null || const {'running', 'cleaning', 'cleanup_pending'}.contains(state) && handle == null) {
      return PhoneSelfCheckSnapshot.unavailable();
    }
    return PhoneSelfCheckSnapshot._(available: true, accepted: value['accepted'] as bool,
      state: state, runHandle: handle, reason: _reason(value['reason']),
      steps: List.unmodifiable([for (final stage in phoneSelfCheckStages) PhoneSelfCheckStep.parse(stage, byStage[stage])]),
    );
  }
}

class PhoneSelfCheckChannel {
  const PhoneSelfCheckChannel([this.channel = const MethodChannel('dsh/phone')]);
  final MethodChannel channel;
  Future<PhoneSelfCheckSnapshot> status() => _invoke('phoneSelfCheckStatus');
  Future<PhoneSelfCheckSnapshot> start() => _invoke('startPhoneSelfCheck', {'v': 1});
  Future<PhoneSelfCheckSnapshot> cancel(String handle) => _invoke('cancelPhoneSelfCheck', {'v': 1, 'runHandle': handle});
  Future<PhoneSelfCheckSnapshot> retry(String handle) => _invoke('retryPhoneSelfCheckCleanup', {'v': 1, 'runHandle': handle});
  Future<PhoneSelfCheckSnapshot> _invoke(String method, [Map<String, Object?>? args]) async {
    try { return PhoneSelfCheckSnapshot.parse(await channel.invokeMethod<Object?>(method, args)); }
    on MissingPluginException { return PhoneSelfCheckSnapshot.unavailable(); }
    on PlatformException { return PhoneSelfCheckSnapshot.unavailable(); }
  }
}

/// Real panel state: one command at a time; stale reads cannot supersede an action reply.
class PhoneSelfCheckController extends ChangeNotifier {
  PhoneSelfCheckController({this.channel = const PhoneSelfCheckChannel()});
  final PhoneSelfCheckChannel channel;
  PhoneSelfCheckSnapshot snapshot = PhoneSelfCheckSnapshot.unavailable();
  bool commandPending = false;
  bool readFailed = false;
  bool _uncertain = false;
  bool _disposed = false;
  bool _visible = true;
  int _generation = 0;
  Object? _query;
  Timer? _timer;
  bool get canStart => !_disposed && snapshot.available && !commandPending && !_uncertain && !snapshot.holdsResource;
  bool get canCancel => !_disposed && !commandPending && snapshot.active && snapshot.runHandle != null;
  bool get canRetry => !_disposed && !commandPending && snapshot.state == 'cleanup_pending' && snapshot.runHandle != null;

  void setVisible(bool value) {
    _visible = value;
    if (!value) { _timer?.cancel(); _timer = null; }
    else { unawaited(refresh()); }
  }

  Future<void> refresh() async {
    if (_disposed || !_visible || commandPending || _query != null) return;
    _timer?.cancel(); _timer = null;
    final query = Object();
    _query = query;
    final generation = _generation;
    try {
      final next = await channel.status();
      if (_disposed || generation != _generation) return;
      _accept(next);
    } finally {
      if (identical(_query, query)) _query = null;
      _schedule();
    }
  }

  Future<void> start() async { if (canStart) await _command(channel.start); }
  Future<void> cancel() async {
    final handle = snapshot.runHandle;
    if (canCancel && handle != null) await _command(() => channel.cancel(handle));
  }
  Future<void> retry() async {
    final handle = snapshot.runHandle;
    if (canRetry && handle != null) await _command(() => channel.retry(handle));
  }

  Future<void> _command(Future<PhoneSelfCheckSnapshot> Function() send) async {
    _timer?.cancel(); _timer = null;
    final generation = ++_generation;
    _query = null; // An older read may still return; it no longer blocks this action's polls.
    commandPending = true;
    notifyListeners();
    try {
      final next = await send();
      if (_disposed || generation != _generation) return;
      _uncertain = !next.available;
      _accept(next);
    } finally {
      if (!_disposed && generation == _generation) { commandPending = false; notifyListeners(); }
      _schedule();
    }
  }

  void _accept(PhoneSelfCheckSnapshot next) {
    if (next.available) { snapshot = next; _uncertain = false; readFailed = false; }
    else { readFailed = true; }
    notifyListeners();
  }

  void _schedule() {
    if (_disposed || !_visible || commandPending || _timer != null || (!snapshot.active && !_uncertain)) return;
    _timer = Timer(const Duration(milliseconds: 800), () { _timer = null; unawaited(refresh()); });
  }

  @override void dispose() {
    _disposed = true; _generation++; _timer?.cancel(); _timer = null;
    super.dispose();
  }
}

/// Only this fixed whitelist is serialized. No raw map, handle, log, settings, or content path.
String phoneSelfCheckMarkdown(PhoneSelfCheckSnapshot snapshot) {
  final out = StringBuffer('# DSH local phone self-check\n\nCoverage: partial.\n'
      'Only device, selected channel, presentation display, input receiver and cleanup are covered.\n'
      'Activity launch, text, images, continuity, MAIN disturbance and OCR are not tested.\n'
      'Cleanup can mean only return of an unused local reservation, not that a display was created.\n'
      'This is the latest accepted status snapshot, not proof of the current device state.\n\n');
  out.writeln('State: ${snapshot.state}');
  out.writeln('Reason: ${phoneSelfCheckReasonGroup(snapshot.reason)}\n');
  out.writeln('| Stage | State | Observed | Reason | Duration (ms) |');
  out.writeln('| --- | --- | --- | --- | --- |');
  for (final step in snapshot.steps) {
    out.writeln('| ${step.stage} | ${step.state} | ${step.observed} | ${phoneSelfCheckReasonGroup(step.reason)} | ${step.durationMs ?? "unknown"} |');
  }
  final text = out.toString();
  if (utf8.encode(text).length > diagnosticsMarkdownBytes) throw StateError('selfCheckReportBudget');
  return text;
}

class PhoneSelfCheckReport {
  PhoneSelfCheckReport({this.files = const FilesChannel(), Future<Directory> Function()? cacheRoot})
      : _cacheRoot = cacheRoot ?? getTemporaryDirectory;
  final FilesChannel files;
  final Future<Directory> Function() _cacheRoot;

  /// Invoked only by the person's Save action. Android replies after the file copy finishes.
  Future<void> save(PhoneSelfCheckSnapshot snapshot) async {
    final bytes = utf8.encode(phoneSelfCheckMarkdown(snapshot));
    final directory = await (await _cacheRoot()).createTemp('phone-self-check-');
    try {
      final file = File('${directory.path}/dsh-phone-self-check.md');
      await file.writeAsBytes(bytes, flush: true);
      await files.saveToDownloads(file.path, name: 'dsh-phone-self-check.md', mime: 'text/markdown');
    } finally {
      try { await directory.delete(recursive: true); } catch (_) { /* Copy outcome is not changed by cache cleanup. */ }
    }
  }
}
