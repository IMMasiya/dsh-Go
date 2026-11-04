// A phone's header and side panel: the title gets the header's width, the model moves
// beside the composer, and the panel shows the conversation's panes.

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_header.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/empty_state.dart' show chatClock;
import 'package:dsh_app/ui/chat/model_sheet.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart' show AttachButton;
import 'package:dsh_app/ui/session/conversation_overview.dart';
import 'package:dsh_app/ui/session/conversation_panel.dart';
import 'package:dsh_app/ui/session/conversation_panes.dart';
import 'package:dsh_app/ui/session/session_tab.dart';
import 'package:dsh_app/ui/shell/drawer/drawer_destination.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import '../chat/support/sample_chat.dart';

ChatState _chat() => ChatState(
  items: <ChatItem>[
    user(1, '问题'),
    assistant(2, '回答', rowKey: 'm'),
  ],
  title: '修复登录重复提交的问题并补上回归测试',
  loading: false,
);

ChatHarness _harness() => ChatHarness(session: 's1', states: {'s1': _chat()});

void main() {
  setUpAll(() async {
    await loadTestFonts();
    chatClock = () => DateTime(2026, 10, 23, 9);
  });

  group('the header', () {
    Future<void> screen(WidgetTester tester, Size size) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      mockClipboard(tester);
      await tester.pumpWidget(testApp(const ChatScreen(), overrides: _harness().overrides));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('on a phone the title has the room, the model under it', (tester) async {
      await screen(tester, const Size(390, 844));
      expect(find.byType(ModelChip), findsNothing);
      expect(find.descendant(of: find.byType(ChatHeader), matching: find.textContaining(' · ')), findsOneWidget);
      final title = tester.getRect(find.byKey(const ValueKey('chat-title-pill')));
      final fresh = tester.getRect(find.byKey(const ValueKey('chat-new-chat')));
      expect(fresh.left - title.right, lessThan(12), reason: 'a long title reaches the key');
      expect(tester.takeException(), isNull);
    });

    testWidgets('typing opens the composer: corners tighten, the model shows, then it folds', (tester) async {
      await screen(tester, const Size(390, 844));
      final row = find.byKey(const ValueKey('composer-model'));
      BorderRadiusGeometry? corners() => tester
          .widget<GlassSurface>(find.ancestor(of: find.byType(TextField), matching: find.byType(GlassSurface)).first)
          .borderRadius;
      final capsule = corners();
      final resting = tester.getSize(find.byType(Composer)).height;
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(corners(), isNot(capsule));
      expect(tester.getSize(find.byType(Composer)).height, greaterThan(resting));
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.text('思考深度'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tapAt(const Offset(195, 60));
      await tester.pumpAndSettle();
      expect(corners(), isNot(capsule), reason: 'it waited behind the sheet');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(corners(), capsule);
      expect(tester.getSize(find.byType(Composer)).height, resting);
    });

    testWidgets('the keyboard going down closes it, with the field still focused', (tester) async {
      await screen(tester, const Size(390, 844));
      BorderRadiusGeometry? corners() => tester
          .widget<GlassSurface>(find.ancestor(of: find.byType(TextField), matching: find.byType(GlassSurface)).first)
          .borderRadius;
      final capsule = corners();
      final resting = tester.getSize(find.byType(Composer)).height;
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      final field = tester.getSize(find.byType(TextField)).width;
      expect(find.byType(TextField), findsOneWidget);
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.hasFocus, isTrue);
      expect(corners(), capsule);
      expect(tester.getSize(find.byType(Composer)).height, resting);
      expect(tester.getSize(find.byType(TextField)).width, lessThan(field));
      // And tapping back in opens it again.
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(corners(), isNot(capsule));
    });

    testWidgets('the keys slide down evenly as it opens, no jump', (tester) async {
      await screen(tester, const Size(390, 844));
      final key = find.byKey(const ValueKey('composer-model'));
      expect(tester.getSize(find.byType(Composer)).height, greaterThan(0));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      var last = tester.getSize(find.byType(Composer)).height;
      var largest = 0.0;
      for (var i = 0; i < 24; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final now = tester.getSize(find.byType(Composer)).height;
        largest = largest > (now - last).abs() ? largest : (now - last).abs();
        last = now;
      }
      await tester.pumpAndSettle();
      expect(largest, lessThan(8), reason: 'the height moves a little every frame');
      expect(tester.getRect(key).left, greaterThan(tester.getRect(find.byType(AttachButton)).right));
      expect(tester.getRect(key).top, greaterThan(tester.getRect(find.byType(TextField)).top));
    });

    testWidgets('a wide window keeps its chip', (tester) async {
      await screen(tester, const Size(900, 800));
      expect(find.byType(ModelChip), findsOneWidget);
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('composer-model')), findsNothing, reason: 'the chip says it');
    });
  });

  group('the panel', () {
    Future<List<DrawerDestination>> panel(WidgetTester tester) async {
      usePhoneView(tester);
      mockClipboard(tester);
      final opened = <DrawerDestination>[];
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: SizedBox(
              width: 334,
              child: ConversationPanel(sessionId: 's1', onOpen: opened.add),
            ),
          ),
          overrides: _harness().overrides,
        ),
      );
      await tester.pump();
      return opened;
    }

    testWidgets('opens on the overview, with the whole title', (tester) async {
      await panel(tester);
      expect(find.byType(ConversationOverview), findsOneWidget);
      expect(find.text('修复登录重复提交的问题并补上回归测试'), findsOneWidget);
      expect(find.byKey(const ValueKey('overview-model')), findsOneWidget);
    });

    testWidgets('panes open and come back', (tester) async {
      await panel(tester);
      // The rest ask the host for their data; the page's own tests have those.
      for (final id in ['trajectory', 'changes', 'overview']) {
        await tester.tap(find.byKey(ValueKey('pane-$id')), warnIfMissed: false);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull, reason: id);
      }
      expect(find.byType(ConversationOverview), findsOneWidget);
    });

    testWidgets('remembers the pane picked', (tester) async {
      await panel(tester);
      await tester.tap(find.byKey(const ValueKey('pane-changes')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ConversationOverview), findsNothing);
    });

    testWidgets('its foot opens the shortcuts', (tester) async {
      final opened = await panel(tester);
      await tester.tap(find.byKey(const ValueKey('quick-panel-settings')));
      expect(opened, [DrawerDestination.settings]);
    });
  });

  test('every tab of the page is a registered pane', () {
    for (final tab in SessionTab.values) {
      expect(ConversationPane.ofTab(tab).tab, tab);
    }
  });
}
