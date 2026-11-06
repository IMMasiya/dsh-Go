import 'dart:io';

import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/l10n/gen/app_localizations.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/companion/companion_chrome.dart';
import 'package:dsh_app/ui/companion/companion_page.dart';
import 'package:dsh_app/ui/companion/companion_stage.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(Widget child) => ProviderScope(
  // No host here: the page must stand on its own without one.
  overrides: [activeConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null))],
  child: MaterialApp(
    theme: buildDarkTheme(),
    localizationsDelegates: L10n.localizationsDelegates,
    supportedLocales: L10n.supportedLocales,
    locale: const Locale('zh'),
    home: child,
  ),
);

/// Lets real file and preference futures finish, then the frames they cause.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// Real file work (the pack check) takes longer on a busy machine: wait for
/// the stage itself, not a fixed number of rounds.
Future<CompanionStageEvents> _stageUp(WidgetTester tester, CompanionStageEvents? Function() events) async {
  for (var i = 0; i < 100 && events() == null; i++) {
    await _settle(tester);
  }
  final up = events();
  expect(up, isNotNull, reason: 'the stage was never built');
  return up!;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('chrome', () {
    testWidgets('the name plate says what she is doing', (tester) async {
      await tester.pumpWidget(
        _app(
          const Scaffold(
            body: Center(
              child: CompanionNamePlate(name: '鲸鱼娘', activity: CompanionActivity.thinking),
            ),
          ),
        ),
      );
      expect(find.text('鲸鱼娘'), findsOneWidget);
      expect(find.text('在想'), findsOneWidget);
    });

    testWidgets('the composer offers the one action that makes sense', (tester) async {
      final input = TextEditingController();
      final focus = FocusNode();
      addTearDown(input.dispose);
      addTearDown(focus.dispose);
      var sent = 0;
      var stopped = 0;
      var voiced = 0;
      Widget composer({bool running = false, bool voice = true}) => _app(
        Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return CompanionComposer(
                input: input,
                focus: focus,
                hint: '和她说点什么',
                running: running,
                busy: false,
                listening: false,
                voiceAvailable: voice,
                onSend: () => sent++,
                onStop: () => stopped++,
                onVoice: () => voiced++,
              );
            },
          ),
        ),
      );

      await tester.pumpWidget(composer());
      await tester.tap(find.bySemanticsLabel('语音'));
      await tester.pumpAndSettle();
      expect(voiced, 1);

      await tester.pumpWidget(composer(running: true));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('让她停下'));
      await tester.pumpAndSettle();
      expect(stopped, 1);

      input.text = '你好';
      await tester.pumpWidget(composer(running: true));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('发送'));
      await tester.pumpAndSettle();
      expect(sent, 1);
    });

    testWidgets('a long reply stays inside its bubble', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: CompanionSpeech(text: '很长的一段话。' * 200),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(CompanionSpeech)).height, lessThan(640 * 0.26 + 40));
    });
  });

  group('page', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('companion-page'));
    tearDown(() => root.deleteSync(recursive: true));

    CompanionPackStore installedStore() {
      Directory('${root.path}/pack/runtime').createSync(recursive: true);
      Directory('${root.path}/pack/character').createSync(recursive: true);
      File('${root.path}/pack/runtime/live2dcubismcore.min.js').writeAsStringSync('core');
      File('${root.path}/pack/character/index.json').writeAsStringSync('[]');
      File('${root.path}/pack/character/character.json').writeAsStringSync('{"name":"鲸鱼娘"}');
      return CompanionPackStore(root);
    }

    testWidgets('without a pack it invites you to bring her home', (tester) async {
      final store = CompanionPackStore(root);
      await tester.pumpWidget(_app(CompanionPage(storeOverride: store)));
      await _settle(tester);
      expect(find.text('把她接回家'), findsOneWidget);
      expect(find.text('导入素材包'), findsOneWidget);
    });

    testWidgets('once the stage is ready: greeting, name, input; touches get a line', (tester) async {
      final commands = <(String, Map<String, Object?>)>[];
      CompanionStageEvents? stageEvents;
      await tester.pumpWidget(
        _app(
          CompanionPage(
            storeOverride: installedStore(),
            stageBuilder: (controller, events) {
              stageEvents = events;
              return const SizedBox.expand();
            },
            stageController: CompanionStageController(sink: (type, args) => commands.add((type, args))),
          ),
        ),
      );
      await _stageUp(tester, () => stageEvents);
      expect(find.text('她正在游过来…'), findsOneWidget);

      stageEvents!.onReady();
      await _settle(tester);
      expect(find.text('鲸鱼娘'), findsOneWidget);
      expect(find.text('你好呀，我是鲸鱼娘。以后就住在这里了，请多指教。'), findsOneWidget);
      expect(commands.map((c) => c.$1), containsAll(['emotion', 'action', 'say']));
      expect(find.text('摸摸她的头试试'), findsNothing); // The greeting is showing.

      stageEvents!.onTouch('tail', 'tap');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining(RegExp('尾巴|好痒')), findsWidgets);

      stageEvents!.onMood('sleeping');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('睡着了'), findsOneWidget);

      // Leave cleanly: timers cancelled with the page.
      await tester.pumpWidget(_app(const SizedBox()));
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('her things answer without a host: activity, a line, the status', (tester) async {
      SharedPreferences.setMockInitialValues({'companion_touch_hint_done': true});
      final commands = <(String, Map<String, Object?>)>[];
      CompanionStageEvents? stageEvents;
      await tester.pumpWidget(
        _app(
          CompanionPage(
            storeOverride: installedStore(),
            stageBuilder: (controller, events) {
              stageEvents = events;
              return const SizedBox.expand();
            },
            stageController: CompanionStageController(sink: (type, args) => commands.add((type, args))),
          ),
        ),
      );
      await _stageUp(tester, () => stageEvents);
      stageEvents!.onReady();
      await _settle(tester);
      // The greeting first; then the hint for her things.
      await tester.pump(const Duration(seconds: 8));
      await _settle(tester);
      expect(find.text('点点贝壳、泡泡和软垫试试'), findsOneWidget);

      commands.clear();
      stageEvents!.onObject('snack');
      await tester.pump(const Duration(milliseconds: 100));
      final activity = commands.where((c) => c.$1 == 'activity').single.$2;
      expect(activity['name'], 'snack');
      expect(activity['remainingMs'], 45000);
      expect(find.text('点点贝壳、泡泡和软垫试试'), findsNothing);
      // Her line waits for the snack to reach her.
      expect(commands.where((c) => c.$1 == 'say'), isEmpty);
      await tester.pump(const Duration(milliseconds: 1800));
      expect(commands.where((c) => c.$1 == 'say'), isNotEmpty);

      stageEvents!.onActivity('snack');
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('在吃点心'), findsOneWidget);
      stageEvents!.onActivity('idle');
      // The plate cross-fades its label.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('在吃点心'), findsNothing);

      await tester.pumpWidget(_app(const SizedBox()));
      await tester.pump(const Duration(seconds: 10));
    });
  });
}
