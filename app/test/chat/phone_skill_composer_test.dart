import 'dart:io';
import 'dart:convert';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/phone/phone_channel.dart';
import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/composer_insert.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/phone_skill_use.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_sync_draft_test.dart' as fixture;
import 'support/harness.dart';
import 'support/session_sync_host.dart';

class _Local extends LocalConnectionController {
  _Local(this.connection);
  final HostConnection connection;
  @override
  Future<HostConnection?> build() async => connection;
}
class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
}

const _method = MethodChannel('dsh/phone');
const _revision = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _invocation = 'cccccccccccccccccccccccccccccccc';
const _text = 'Only replay this reviewed route: $_invocation';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(_method, null));

  Future<SyncHarness> open(WidgetTester tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final ui = ChatHarness(session: 'S');
    late HostConnection connection;
    final overrides = [
      petScopedStateProvider.overrideWith((ref, scope) => const PetState()),
      for (final override in ui.overrides)
        if (override.origin != activeConnectionProvider && override.origin != chatProvider &&
            override.origin != localConnectionProvider) override,
      activeHostProvider.overrideWith(_Host.new),
      localConnectionProvider.overrideWith(() => _Local(connection)),
    ];
    late SyncHarness h;
    await tester.runAsync(() => HttpOverrides.runWithHttpOverrides(() async {
      h = await SyncHarness.start(overrides: overrides);
    }, RealSyncHttp()));
    connection = HostConnection(client: h.client, isLocal: true);
    await h.container.read(localConnectionProvider.future);
    await fixture.mount(tester, h);
    await pumpFrames(tester);
    return h;
  }

  PreparedPhoneSkill selection(SyncHarness h, {String invocation = _invocation}) => PreparedPhoneSkill(
    origin: PhoneSkillUseOrigin.capture(h.container, 'S')!, channel: PhoneChannel(), text: _text,
    ready: PhoneSkillReplayReady.parse({'kind': 'ready', 'revision': _revision,
      'invocation': invocation, 'parameterNames': []})!);

  testWidgets('prepared route card never enters ordinary input or saved draft and queues through real Chat', (tester) async {
    messenger.setMockMethodCallHandler(_method, (_) async => {'kind': 'discarded'});
    final h = await open(tester);
    try {
      await tester.enterText(find.byType(TextField), 'my ordinary draft');
      await tester.pump();
      h.container.read(composerInsertProvider.notifier).request(ComposerInsert.phoneRoute(selection(h)));
      await tester.pump();
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'my ordinary draft');
      expect(h.container.read(draftStoreProvider).drafts['S']?.text, 'my ordinary draft');
      expect(find.text(_text), findsOneWidget);
      await tester.ensureVisible(find.text(appL10n.phoneSkillReplayQueue));
      await tester.tap(find.text(appL10n.phoneSkillReplayQueue));
      await tester.pump();
      await fixture.settleIo(tester, () => h.boundary.length == 1 && find.text(_text).evaluate().isEmpty);
      expect(h.boundary.single['endpoint'], 'session/prompt');
      expect((h.boundary.single['request'] as Map)['mode'], 'queue');
      expect(jsonEncode(h.boundary.single['request']), contains(_text));
      expect(jsonEncode(h.boundary.single['request']), isNot(contains('my ordinary draft')));
      expect(h.cancelledBackendRuns, isEmpty);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'my ordinary draft');
      expect(h.container.read(draftStoreProvider).drafts['S']?.text, 'my ordinary draft');
    } finally { await fixture.disposeHarness(tester, h); }
  });

  testWidgets('changing selection after preparation cannot silently restore old session or send', (tester) async {
    final discarded = <Object?>[];
    messenger.setMockMethodCallHandler(_method, (call) async {
      discarded.add(call.arguments);
      return {'kind': 'discarded'};
    });
    final h = await open(tester);
    try {
      final prepared = selection(h);
      h.container.read(currentSessionProvider.notifier).select(null);
      h.container.read(composerInsertProvider.notifier).request(ComposerInsert.phoneRoute(prepared));
      await tester.pump();
      expect(h.container.read(currentSessionProvider), isNull);
      expect(find.text(_text), findsNothing);
      expect(h.boundary, isEmpty);
      expect(discarded, [{'invocation': _invocation}]);
    } finally { await fixture.disposeHarness(tester, h); }
  });

  testWidgets('replacing an unconsumed typed insert discards just its original invocation', (tester) async {
    final discarded = <Object?>[];
    messenger.setMockMethodCallHandler(_method, (call) async {
      discarded.add(call.arguments);
      return {'kind': 'discarded'};
    });
    final h = await open(tester);
    try {
      // A separate container owns no Chat listener, so request replacement is
      // tested before any consumer takes responsibility for the first insert.
      final pending = ProviderContainer();
      try {
        pending.read(composerInsertProvider.notifier).request(ComposerInsert.phoneRoute(selection(h)));
        pending.read(composerInsertProvider.notifier).request(const ComposerInsert.skill('plain', sessionId: 'S'));
        await tester.pump();
        expect(discarded, [{'invocation': _invocation}]);
        expect(pending.read(composerInsertProvider), const ComposerInsert.skill('plain', sessionId: 'S'));
        expect(h.boundary, isEmpty);
      } finally { pending.dispose(); }
    } finally { await fixture.disposeHarness(tester, h); }
  });
}
