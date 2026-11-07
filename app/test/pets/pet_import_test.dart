import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dsh_app/pets/pet_library.dart';
import 'package:dsh_app/pets/pet_prefs.dart';
import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/ui/pets/pet_picker.dart';
import 'package:dsh_app/ui/pets/pet_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pet_library_test.dart' show packJson, png;
import 'support.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('pet-import'));
  tearDown(() => temp.deleteSync(recursive: true));

  File zip(Map<String, List<int>> files) {
    final archive = Archive();
    files.forEach((name, data) => archive.add(ArchiveFile.bytes(name, data)));
    final file = File('${temp.path}/in-${DateTime.now().microsecondsSinceEpoch}.zip');
    file.writeAsBytesSync(ZipEncoder().encode(archive));
    return file;
  }

  /// Lets the real file work (unzip, write, read back) finish.
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<ProviderContainer> open(WidgetTester tester, File? Function() picked) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        const PetSettingsPage(),
        overrides: [
          petClockProvider.overrideWithValue(TestClock().call),
          petLibraryProvider.overrideWithValue(PetLibrary(() async => Directory('${temp.path}/pets'))),
          petPackPickerProvider.overrideWithValue(() async => picked()),
          petPackProvider.overrideWith(
            (ref, id) async => isUserPet(id) ? ref.watch(petLibraryProvider).load(id) : diskPack(id),
          ),
          petPrefsProvider.overrideWith(() => FixedPetPrefs(const PetPrefs(loaded: true))),
        ],
      ),
    );
    await settle(tester, () => false);
    return ProviderScope.containerOf(tester.element(find.byType(PetSettingsPage)));
  }

  testWidgets('导入: your pet joins the picker, chosen, and says who made it', (tester) async {
    final file = zip({'cat/pack.json': utf8.encode(jsonEncode(packJson())), 'cat/idle.png': png(32, 16)});
    final container = await open(tester, () => file);
    expect(find.text('导入'), findsOneWidget);
    expect(find.textContaining('导入你自己的像素宠物'), findsOneWidget);

    await tester.tap(find.text('导入'));
    await settle(tester, () => find.text('「小猫」来了').evaluate().isNotEmpty);
    expect(find.text('「小猫」来了'), findsOneWidget);
    expect(find.text('小猫'), findsOneWidget);
    expect(container.read(petPrefsProvider).packId, 'user-cat');
    expect(find.textContaining('阿周 · CC0'), findsOneWidget);
    // The picked copy is tidied away.
    expect(file.existsSync(), isFalse);

    // Long press: gone, and the default is back.
    await tester.longPress(find.text('小猫'));
    await tester.pumpAndSettle();
    expect(find.text('删除「小猫」？'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await settle(tester, () => find.text('小猫').evaluate().isEmpty);
    expect(find.text('小猫'), findsNothing);
    expect(container.read(petPrefsProvider).packId, defaultPetId);
    expect(Directory('${temp.path}/pets/user-cat').existsSync(), isFalse);
  });

  testWidgets('a pack that is turned away says why, and nothing changes', (tester) async {
    final file = zip({'pack.json': utf8.encode(jsonEncode(packJson()))});
    final container = await open(tester, () => file);
    await tester.tap(find.text('导入'));
    await settle(tester, () => find.textContaining('少了序列帧图').evaluate().isNotEmpty);
    expect(find.text('zip 里少了序列帧图 idle.png'), findsOneWidget);
    expect(container.read(petPrefsProvider).packId, defaultPetId);
  });

  testWidgets('cancelling the pick does nothing', (tester) async {
    final container = await open(tester, () => null);
    await tester.tap(find.text('导入'));
    await settle(tester, () => false);
    expect(find.byType(SnackBar), findsNothing);
    expect(container.read(petPrefsProvider).packId, defaultPetId);
  });
}
