import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_app/pets/pet_library.dart';
import 'package:flutter_test/flutter_test.dart';

/// A real (transparent) PNG of [w] × [h].
Uint8List png(int w, int h) {
  List<int> chunk(String type, List<int> data) {
    final body = [...ascii.encode(type), ...data];
    final length = ByteData(4)..setUint32(0, data.length);
    final crc = ByteData(4)..setUint32(0, getCrc32(body));
    return [...length.buffer.asUint8List(), ...body, ...crc.buffer.asUint8List()];
  }

  final header = ByteData(13)
    ..setUint32(0, w)
    ..setUint32(4, h)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 6); // RGBA
  final rows = <int>[
    for (var y = 0; y < h; y++) ...[0, ...List.filled(w * 4, 0)],
  ];
  return Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    ...chunk('IHDR', header.buffer.asUint8List()),
    ...chunk('IDAT', ZLibCodec().encode(rows)),
    ...chunk('IEND', const []),
  ]);
}

/// A small valid pack: one idle animation, two 16×16 cells side by side.
Map<String, Object?> packJson({String id = 'cat', String name = '小猫', String sheet = 'idle.png', int frames = 2}) => {
  'schema': 1,
  'id': id,
  'name': name,
  'author': '阿周',
  'license': 'CC0',
  'canvas': {'w': 16, 'h': 16},
  'contentBox': {'x': 2, 'y': 2, 'w': 12, 'h': 12},
  'animations': {
    'idle': {
      'sheet': sheet,
      'frameW': 16,
      'frameH': 16,
      'cols': 2,
      'box': {'x': 0, 'y': 0, 'w': 16, 'h': 16},
      'frames': [
        for (var i = 0; i < frames; i++) {'i': i, 'ms': 200},
      ],
    },
  },
  'states': {
    'idle': ['idle'],
  },
};

void main() {
  late Directory temp;
  late PetLibrary library;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('pet-library');
    library = PetLibrary(() async => Directory('${temp.path}/pets'));
  });
  tearDown(() => temp.deleteSync(recursive: true));

  File zip(Map<String, List<int>> files) {
    final archive = Archive();
    files.forEach((name, data) => archive.add(ArchiveFile.bytes(name, data)));
    final file = File('${temp.path}/in-${DateTime.now().microsecondsSinceEpoch}.zip');
    file.writeAsBytesSync(ZipEncoder().encode(archive));
    return file;
  }

  Matcher problem(PetImportProblem expected) =>
      throwsA(isA<PetImportException>().having((e) => e.problem, 'problem', expected));

  List<String> leftovers() => [
    for (final e in Directory('${temp.path}/pets').listSync())
      if (e.uri.pathSegments.lastWhere((s) => s.isNotEmpty).startsWith('.')) e.path,
  ];

  test('an id for a folder, after the prefix', () {
    expect(userPetIdFor('cat'), 'user-cat');
    expect(userPetIdFor('My Cat!'), 'user-my-cat');
    expect(userPetIdFor('user-cat'), 'user-cat');
    expect(userPetIdFor('小猫'), 'user-pet');
    expect(userPetIdFor('a' * 60), 'user-${'a' * 40}');
    expect(isUserPet('user-cat'), isTrue);
    expect(isUserPet('deepy-whale'), isFalse);
  });

  test("a PNG's size from its header", () {
    expect(pngSize(png(32, 16)), (32, 16));
    expect(pngSize(Uint8List.fromList(utf8.encode('not a png at all, really not'))), isNull);
  });

  test('a pack zipped from its folder: kept under its id, only what it uses', () async {
    final result = await library.install(
      zip({
        'cat/pack.json': utf8.encode(jsonEncode(packJson())),
        'cat/idle.png': png(32, 16),
        'cat/readme.txt': utf8.encode('hi'),
        'cat/run.js': utf8.encode('x'),
      }),
    );
    expect(result, (id: 'user-cat', replaced: false));
    final dir = Directory('${temp.path}/pets/user-cat');
    expect(dir.listSync().map((e) => e.uri.pathSegments.last).toSet(), {'pack.json', 'idle.png'});

    final pack = await library.load('user-cat');
    expect(pack.id, 'user-cat');
    expect(pack.name, '小猫');
    expect(pack.author, '阿周');
    expect(pack.dir, dir.path);
    expect((await library.list()).map((p) => p.id), ['user-cat']);
    expect(leftovers(), isEmpty);
  });

  test('the same pet again replaces it; a different one sits beside it', () async {
    await library.install(zip({'pack.json': utf8.encode(jsonEncode(packJson())), 'idle.png': png(32, 16)}));
    final again = await library.install(
      zip({'pack.json': utf8.encode(jsonEncode(packJson(name: '大猫'))), 'idle.png': png(32, 16)}),
    );
    expect(again.replaced, isTrue);
    expect((await library.load('user-cat')).name, '大猫');
    await library.install(zip({'pack.json': utf8.encode(jsonEncode(packJson(id: 'dog'))), 'idle.png': png(32, 16)}));
    expect((await library.list()).map((p) => p.id), ['user-cat', 'user-dog']);

    await library.remove('user-cat');
    expect((await library.list()).map((p) => p.id), ['user-dog']);
    // Never a built-in one.
    await library.remove('deepy-whale');
    expect(leftovers(), isEmpty);
  });

  group('turned away, nothing left behind', () {
    tearDown(() async {
      if (await Directory('${temp.path}/pets').exists()) expect(leftovers(), isEmpty);
    });

    test('not a zip', () async {
      final file = File('${temp.path}/not.zip')..writeAsStringSync('hello');
      await expectLater(library.install(file), problem(PetImportProblem.notAZip));
    });

    test('no pack.json at its top', () async {
      await expectLater(
        library.install(zip({'a/b/pack.json': utf8.encode('{}'), 'idle.png': png(32, 16)})),
        problem(PetImportProblem.noPack),
      );
    });

    test('a pack.json that does not parse', () async {
      await expectLater(
        library.install(
          zip({
            'pack.json': utf8.encode(jsonEncode({...packJson(), 'schema': 2})),
          }),
        ),
        problem(PetImportProblem.badPack),
      );
      await expectLater(library.install(zip({'pack.json': utf8.encode('{')})), problem(PetImportProblem.badPack));
    });

    test('a sheet it names is missing', () async {
      await expectLater(
        library.install(zip({'pack.json': utf8.encode(jsonEncode(packJson()))})),
        problem(PetImportProblem.missingSheet),
      );
    });

    test('a sheet that climbs out, nests, or is not a PNG', () async {
      for (final sheet in ['../idle.png', 'sheets/idle.png', 'idle.gif', '.idle.png']) {
        await expectLater(
          library.install(zip({'pack.json': utf8.encode(jsonEncode(packJson(sheet: sheet))), sheet: png(32, 16)})),
          problem(PetImportProblem.badSheet),
          reason: sheet,
        );
      }
      await expectLater(
        library.install(zip({'pack.json': utf8.encode(jsonEncode(packJson())), 'idle.png': utf8.encode('GIF89a')})),
        problem(PetImportProblem.badSheet),
      );
    });

    test('cells outside the sheet, or a sheet too big to draw', () async {
      // Three cells, two columns: the third needs a second row.
      await expectLater(
        library.install(zip({'pack.json': utf8.encode(jsonEncode(packJson(frames: 3))), 'idle.png': png(32, 16)})),
        problem(PetImportProblem.badSheet),
      );
      await expectLater(
        library.install(zip({'pack.json': utf8.encode(jsonEncode(packJson())), 'idle.png': png(4100, 16)})),
        problem(PetImportProblem.badSheet),
      );
    });
  });
}
