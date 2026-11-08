import 'dart:async';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/phone_skill_use.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/features/phone_skill_use.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../packages/dsh_client/test/support/fake_dsh.dart';

class _RealHttp extends HttpOverrides {}
class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
}
class _Session extends CurrentSessionController {
  @override
  String? build() => 'S';
}
class _Local extends LocalConnectionController {
  _Local(this.connection);
  final HostConnection connection;
  @override
  Future<HostConnection?> build() async => connection;
}

const _method = MethodChannel('dsh/phone');
const _skill = 'phone-task-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _revision = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _invocation = 'cccccccccccccccccccccccccccccccc';
const _available = {'kind': 'available', 'revision': _revision, 'summary': 'Public route',
  'apps': [{'packageName': 'test.app', 'uid': 10002, 'label': 'Test app'}]};
const _ready = {'kind': 'ready', 'revision': _revision, 'invocation': _invocation, 'parameterNames': []};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late FakeDsh host;
  late DshClient client;
  late ProviderContainer container;
  late HttpOverrides? previousHttp;
  PreparedPhoneSkill? prepared;

  Future<void> open(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    previousHttp = HttpOverrides.current;
    HttpOverrides.global = _RealHttp();
    try {
      await tester.runAsync(() async {
        host = await FakeDsh.start();
        try {
          client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token);
          await client.mux.ready();
        } catch (_) {
          await host.close();
          rethrow;
        }
      });
    } catch (_) {
      HttpOverrides.global = previousHttp;
      rethrow;
    }
    final connection = HostConnection(client: client, isLocal: true);
    container = ProviderContainer(overrides: [
      activeHostProvider.overrideWith(_Host.new),
      currentSessionProvider.overrideWith(_Session.new),
      activeConnectionProvider.overrideWithValue(AsyncData(connection)),
      localConnectionProvider.overrideWith(() => _Local(connection)),
    ]);
    await container.read(localConnectionProvider.future);
    prepared = null;
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: MaterialApp(
      home: Builder(builder: (context) => Scaffold(body: TextButton(onPressed: () async {
        prepared = await preparePhoneSkillUse(context, skillId: _skill, sessionId: 'S');
      }, child: const Text('review')))),
    )));
    await tester.tap(find.text('review'));
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    container.dispose();
    await tester.runAsync(() async { await client.close(); await host.close(); });
    HttpOverrides.global = previousHttp;
    messenger.setMockMethodCallHandler(_method, null);
  }

  testWidgets('unsupported native descriptor offers no executable app or prepare', (tester) async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(_method, (call) async {
      calls.add(call);
      return {'kind': 'rejected', 'reason': 'unsupported'};
    });
    await open(tester);
    try {
      expect(find.text(appL10n.phoneSkillReplayUnavailable), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.text(appL10n.phoneSkillReplayToComposer), findsNothing);
      expect(calls.map((c) => c.method).toList(), ['inspectSkillReplay']);
      expect(prepared, isNull);
    } finally { await close(tester); }
  });

  testWidgets('real local client and selected native PM pair prepare without sending', (tester) async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(_method, (call) async {
      calls.add(call);
      return call.method == 'inspectSkillReplay' ? _available : _ready;
    });
    await open(tester);
    try {
      await tester.tap(find.text('Test app'));
      await tester.pump();
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(find.text(appL10n.phoneSkillReplayToComposer));
      await tester.pumpAndSettle();
      expect(prepared!.ready.invocation, _invocation);
      expect(prepared!.origin.current(container), isTrue);
      expect(prepared!.text, contains('mcp__phone__replay'));
      expect(calls.map((c) => c.method).toList(), ['inspectSkillReplay', 'prepareSkillReplay']);
      expect(calls.last.arguments, {'skillId': _skill, 'revision': _revision, 'sessionId': 'S',
        'parameters': {'appSlots': {'app1': {'packageName': 'test.app', 'uid': 10002}}, 'values': {}}});
      expect(host.rpcCalls.where((c) => c['method'] == 'session/prompt'), isEmpty);
    } finally { await close(tester); }
  });

  for (final leave in [false, true]) {
    testWidgets('late prepare after ${leave ? 'close' : 'session change'} discards only original invocation', (tester) async {
      final reply = Completer<Object?>();
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(_method, (call) async {
        calls.add(call);
        if (call.method == 'inspectSkillReplay') return _available;
        if (call.method == 'prepareSkillReplay') return reply.future;
        return {'kind': 'discarded'};
      });
      await open(tester);
      try {
        await tester.tap(find.text('Test app'));
        await tester.pump();
        await tester.tap(find.byType(CheckboxListTile));
        await tester.pump();
        await tester.tap(find.text(appL10n.phoneSkillReplayToComposer));
        await tester.pump();
        expect(calls.where((c) => c.method == 'prepareSkillReplay').length, 1);
        if (leave) {
          await tester.tap(find.text(appL10n.commonClose));
          await tester.pumpAndSettle();
        } else {
          container.read(currentSessionProvider.notifier).select('other');
        }
        reply.complete(_ready);
        await tester.pumpAndSettle();
        expect(prepared, isNull);
        final discards = calls.where((c) => c.method == 'discardSkillReplay').toList();
        expect(discards.length, 1);
        expect(discards.single.arguments, {'invocation': _invocation});
        expect(host.rpcCalls.where((c) => c['method'] == 'session/prompt'), isEmpty);
      } finally {
        if (!reply.isCompleted) reply.complete({'kind': 'rejected', 'reason': 'stale'});
        await close(tester);
      }
    });
  }
}
