import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/diagnostics/diagnostics_markdown.dart' show diagnosticsMarkdownBytes;
import 'package:dsh_app/phone/phone_self_check.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/phone/phone_self_check_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

const _phone = MethodChannel('dsh/phone');
const _files = MethodChannel('dsh/files');
Map<String, Object?> _reply(String state, {String? handle, String? reason, List<Object?>? steps}) => {
  'v': 1, 'accepted': true, 'coverage': 'partial', 'state': state,
  if (handle != null) 'runHandle': handle,
  if (reason != null) 'reason': reason,
  'steps': steps ?? [for (final stage in phoneSelfCheckStages)
    {'stage': stage, 'state': 'not_run', 'observed': false}],
};
Map<String, Object?> _step(String stage, String state, Object observed, {Object? reason, Object? duration}) => {
  'stage': stage, 'state': state, 'observed': observed,
  if (reason != null) 'reason': reason,
  if (duration != null) 'durationMs': duration,
};

class _RecordingReport extends PhoneSelfCheckReport {
  final done = Completer<void>();
  final saved = <PhoneSelfCheckSnapshot>[];
  @override Future<void> save(PhoneSelfCheckSnapshot snapshot) {
    saved.add(snapshot); return done.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_phone, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_files, null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_phone, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_files, null);
  });

  test('strict response types and unknown versions never become available', () {
    for (final field in ['v', 'accepted', 'coverage', 'state', 'steps']) {
      expect(PhoneSelfCheckSnapshot.parse(_reply('done')..remove(field)).available, isFalse);
    }
    for (final version in <Object?>[null, true, '1', 1.0, 2]) {
      expect(PhoneSelfCheckSnapshot.parse(_reply('done')..['v'] = version).available, isFalse);
    }
    expect(PhoneSelfCheckSnapshot.parse(_reply('done')..['accepted'] = 'true').available, isFalse);
    expect(PhoneSelfCheckSnapshot.parse(_reply('future-state')).available, isFalse);
    expect(PhoneSelfCheckSnapshot.parse(_reply('running')).available, isFalse);
    expect(PhoneSelfCheckSnapshot.parse(_reply('running', handle: 'x' * 257)).available, isFalse);
  });

  test('pass requires actual observation and no contradictory fault', () {
    for (final step in [
      _step('input_probe', 'pass', false), _step('input_probe', 'pass', 'true'),
      _step('input_probe', 'pass', true, reason: 'unrecognized private error'),
      _step('input_probe', 'pass', true, reason: 'inputRejected'),
      _step('input_probe', 'pass', true, duration: -1),
      _step('input_probe', 'pass', true, duration: 2.0),
      _step('input_probe', 'future-state', true),
    ]) {
      final snapshot = PhoneSelfCheckSnapshot.parse(_reply('done', steps: [step]));
      expect(snapshot.steps.firstWhere((s) => s.stage == 'input_probe').state, 'unknown');
    }
    final good = PhoneSelfCheckSnapshot.parse(_reply('done', steps: [_step('input_probe', 'pass', true, duration: 8)]));
    expect(good.steps.firstWhere((s) => s.stage == 'input_probe').state, 'pass');
  });

  test('unsupported and future stages cannot claim coverage', () {
    final snapshot = PhoneSelfCheckSnapshot.parse(_reply('done', steps: [
      _step('ocr', 'pass', true), _step('text_zh', 'pass', true), _step('future-stage', 'pass', true),
    ]));
    expect(snapshot.steps.where((s) => s.state == 'pass'), isEmpty);
    expect(snapshot.steps.firstWhere((s) => s.stage == 'ocr').state, 'not_run');
    expect(snapshot.steps.firstWhere((s) => s.stage == 'text_zh').observed, isFalse);
    expect(snapshot.steps.map((s) => s.stage), phoneSelfCheckStages);
    expect(PhoneSelfCheckSnapshot.parse(_reply('done', steps: [
      _step('device', 'pass', true), _step('device', 'fail', true),
    ])).available, isFalse);
  });

  test('report is a bounded whitelist with no handles or raw content', () {
    const private = 'private-token-account-ocr-screen-data';
    final snapshot = PhoneSelfCheckSnapshot.parse(_reply('cleanup_pending', handle: private, reason: private, steps: [
      _step('input_probe', 'pass', true, duration: 9),
      _step('cleanup', 'fail', true, reason: private),
    ])..['screen'] = private..['engineLog'] = private..['settings'] = private);
    final report = phoneSelfCheckMarkdown(snapshot);
    expect(report, contains('Coverage: partial'));
    expect(report, contains('| input_probe | pass | true |'));
    expect(report, contains('| cleanup | fail | true | other |'));
    expect(report, isNot(contains(private)));
    expect(report, isNot(contains('runHandle')));
    expect(utf8.encode(report).length, lessThanOrEqualTo(diagnosticsMarkdownBytes));
  });

  test('very large unknown strings and times never escape the report budget', () {
    final raw = _reply('done', reason: 'secret' * 10000, steps: [for (final stage in phoneSelfCheckStages)
      _step(stage, 'fail', true, reason: 'secret' * 10000, duration: 9223372036854775807)]);
    final text = phoneSelfCheckMarkdown(PhoneSelfCheckSnapshot.parse(raw));
    expect(text, isNot(contains('secret')));
    expect(utf8.encode(text).length, lessThanOrEqualTo(diagnosticsMarkdownBytes));
  });

  test('real channel sends only fixed methods and exact original handle', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_phone, (call) async {
      calls.add(call); return _reply('idle');
    });
    const channel = PhoneSelfCheckChannel();
    await channel.status(); await channel.start(); await channel.cancel('original'); await channel.retry('original');
    expect(calls.map((c) => c.method), ['phoneSelfCheckStatus', 'startPhoneSelfCheck', 'cancelPhoneSelfCheck', 'retryPhoneSelfCheckCleanup']);
    expect(calls[0].arguments, isNull);
    expect(calls[1].arguments, {'v': 1});
    expect(calls[2].arguments, {'v': 1, 'runHandle': 'original'});
    expect(calls[3].arguments, calls[2].arguments);
  });

  test('missing or failing native uses fixed unavailable result', () async {
    expect((await const PhoneSelfCheckChannel().status()).available, isFalse);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_phone, (_) async {
      throw PlatformException(code: 'private', message: 'private body');
    });
    final snapshot = await const PhoneSelfCheckChannel().start();
    expect(snapshot.available, isFalse);
    expect(phoneSelfCheckMarkdown(snapshot), isNot(contains('private')));
  });

  testWidgets('late pre-action status cannot overwrite a newly started run', (tester) async {
    final old = Completer<Object?>();
    var reads = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_phone, (call) async {
      if (call.method == 'startPhoneSelfCheck') return _reply('running', handle: 'new');
      if (++reads == 1) return _reply('idle');
      if (reads == 2) return old.future;
      return _reply('done', handle: 'new');
    });
    final controller = PhoneSelfCheckController();
    await controller.refresh();
    unawaited(controller.refresh()); await tester.pump();
    await controller.start();
    expect(controller.snapshot.runHandle, 'new');
    old.complete(_reply('done', handle: 'old')); await tester.pump();
    expect(controller.snapshot.runHandle, 'new');
    expect(controller.snapshot.state, 'running');
    await tester.pump(const Duration(milliseconds: 800)); await tester.pump();
    expect(controller.snapshot.state, 'done');
    controller.dispose();
  });

  testWidgets('retry keeps original handle and rejects older cleanup status', (tester) async {
    final stale = Completer<Object?>();
    var reads = 0;
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_phone, (call) async {
      calls.add(call);
      if (call.method == 'retryPhoneSelfCheckCleanup') return _reply('cleaning', handle: 'one');
      return ++reads == 1 ? _reply('cleanup_pending', handle: 'one') : stale.future;
    });
    final controller = PhoneSelfCheckController();
    await controller.refresh();
    unawaited(controller.refresh()); await tester.pump();
    await controller.retry();
    stale.complete(_reply('cleanup_pending', handle: 'stale')); await tester.pump();
    expect(controller.snapshot.state, 'cleaning');
    expect(controller.snapshot.runHandle, 'one');
    expect(calls.singleWhere((c) => c.method == 'retryPhoneSelfCheckCleanup').arguments, {'v': 1, 'runHandle': 'one'});
    expect(calls.where((c) => c.method == 'startPhoneSelfCheck'), isEmpty);
    controller.dispose();
  });

  testWidgets('unknown start reply prevents a second start until fresh status', (tester) async {
    var starts = 0, reads = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_phone, (call) async {
      if (call.method == 'startPhoneSelfCheck') { starts++; return null; }
      return ++reads == 1 ? _reply('idle') : _reply('running', handle: 'accepted-late');
    });
    final controller = PhoneSelfCheckController();
    await controller.refresh(); await controller.start(); await controller.start();
    expect(starts, 1); expect(controller.canStart, isFalse);
    await tester.pump(const Duration(milliseconds: 800)); await tester.pump();
    expect(controller.snapshot.runHandle, 'accepted-late');
    controller.dispose();
  });

  testWidgets('dispose stops polls and ignores a pending native result', (tester) async {
    final late = Completer<Object?>(); var calls = 0, notifications = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_phone, (_) async {
      calls++; return calls == 1 ? _reply('running', handle: 'one') : late.future;
    });
    final controller = PhoneSelfCheckController()..addListener(() => notifications++);
    await controller.refresh();
    await tester.pump(const Duration(milliseconds: 800));
    final before = notifications;
    controller.dispose(); late.complete(_reply('done', handle: 'late'));
    await tester.pump(); await tester.pump(const Duration(seconds: 3));
    expect(calls, 2); expect(notifications, before); expect(tester.takeException(), isNull);
  });

  testWidgets('hidden app pauses polling without cancelling native work', (tester) async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_phone, (call) async {
      expect(call.method, 'phoneSelfCheckStatus'); calls++; return _reply('running', handle: 'one');
    });
    final controller = PhoneSelfCheckController(); await controller.refresh();
    controller.setVisible(false); await tester.pump(const Duration(seconds: 3));
    expect(calls, 1);
    controller.setVisible(true); await tester.pump(); expect(calls, 2);
    controller.dispose();
  });

  test('explicit report uses real FilesChannel and deletes temp after native copy reply', () async {
    final root = await Directory.systemTemp.createTemp('self-check-test-');
    final copied = Completer<void>(), reply = Completer<String>();
    String? path; String? content;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_files, (call) async {
      expect(call.method, 'saveToDownloads');
      final args = call.arguments as Map;
      expect(args['name'], 'dsh-phone-self-check.md'); expect(args['mime'], 'text/markdown');
      path = args['path'] as String; content = await File(path!).readAsString();
      copied.complete(); return reply.future;
    });
    final exporter = PhoneSelfCheckReport(cacheRoot: () async => root);
    final done = exporter.save(PhoneSelfCheckSnapshot.parse(_reply('done', handle: 'never-export')));
    await copied.future;
    expect(await File(path!).exists(), isTrue); expect(content, isNot(contains('never-export')));
    reply.complete('Download/DSH-Go/dsh-phone-self-check.md'); await done;
    expect(await File(path!).exists(), isFalse); expect(await root.list().toList(), isEmpty);
    await root.delete();
  });

  test('failed native copy still deletes only its own temp operation', () async {
    final root = await Directory.systemTemp.createTemp('self-check-test-');
    final sibling = await File('${root.path}/keep.txt').writeAsString('unrelated');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_files, (_) async {
      throw PlatformException(code: 'copyFailed', message: 'private');
    });
    final exporter = PhoneSelfCheckReport(cacheRoot: () async => root);
    await expectLater(exporter.save(PhoneSelfCheckSnapshot.parse(_reply('done'))), throwsA(isA<PlatformException>()));
    expect(await root.list().map((f) => f.path).toList(), [sibling.path]);
    await root.delete(recursive: true);
  });

  testWidgets('actual failed step shows a fixed next-step explanation without a top reason', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_phone, (_) async =>
      _reply('done', steps: [_step('input_probe', 'unknown', true, reason: 'inputUnconfirmed')]));
    await tester.pumpWidget(goldenApp(home: const Scaffold(body: SingleChildScrollView(child: PhoneSelfCheckPanel()))));
    await tester.pump(); await tester.pump();
    final context = tester.element(find.byType(PhoneSelfCheckPanel));
    final reason = tester.widget<Text>(find.byKey(const ValueKey('self-check-reason-input_probe')));
    expect(reason.data, context.l10n.phoneSelfCheckReason('input'));
    expect(find.text('inputUnconfirmed'), findsNothing);
    expect(tester.widget<Text>(find.byKey(const ValueKey('self-check-state'))).data,
      context.l10n.phoneSelfCheckRunState('done'));
    expect(tester.widget<Text>(find.byKey(const ValueKey('self-check-step-ocr'))).data,
      context.l10n.phoneSelfCheckStepState('not_run'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Save button is explicit and a late export cannot revive a disposed panel', (tester) async {
    final report = _RecordingReport();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_phone, (_) async => _reply('done'));
    await tester.pumpWidget(goldenApp(home: Scaffold(body: SingleChildScrollView(child: PhoneSelfCheckPanel(report: report)))));
    await tester.pump(); await tester.pump();
    expect(report.saved, isEmpty);
    await tester.ensureVisible(find.byKey(const ValueKey('self-check-save'))); await tester.pump();
    await tester.tap(find.byKey(const ValueKey('self-check-save'))); await tester.pump();
    expect(report.saved.length, 1); expect(report.saved.single.state, 'done');
    await tester.pumpWidget(const SizedBox()); report.done.complete(); await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('panel only queries until a person starts or explicitly saves', (tester) async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_phone, (call) async {
      calls.add(call.method);
      return call.method == 'startPhoneSelfCheck' ? _reply('running', handle: 'hidden-id') : _reply('idle');
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_files, (_) async {
      fail('No explicit Save was requested');
    });
    await tester.pumpWidget(goldenApp(home: const Scaffold(body: SingleChildScrollView(child: PhoneSelfCheckPanel()))));
    await tester.pump(); await tester.pump();
    expect(calls, ['phoneSelfCheckStatus']);
    expect(find.textContaining('hidden-id'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('self-check-start'))); await tester.pump(); await tester.pump();
    expect(calls.where((c) => c == 'startPhoneSelfCheck').length, 1);
    expect(find.byKey(const ValueKey('self-check-cancel')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    final count = calls.length; await tester.pump(const Duration(seconds: 2));
    expect(calls.length, count); expect(tester.takeException(), isNull);
  });
}
