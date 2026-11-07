// Pets the person brings: a schema-1 pack (docs/design/pets.md §3) zipped,
// unpacked into `<app support>/pets/<id>/`, which on Android is the very
// `files/pets/<id>/` the overlay falls back to (PetSprites.kt `sourceFor`:
// pack.json and the sheets side by side, nothing in folders).
//
// A pack from outside goes through the same parse as the built-in ones
// (PetPack.parse) and then what a file nobody here made needs: safe names,
// real PNG sheets with every cell inside them, and the format's size caps.
// Only pack.json and the sheets it names are kept; anything else in the zip
// is left behind.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'pet_pack.dart';

/// Ids of brought pets start with this; the built-in ones never do.
const userPetPrefix = 'user-';

bool isUserPet(String id) => id.startsWith(userPetPrefix);

/// Why a zip was turned away.
enum PetImportProblem {
  /// Not a zip at all.
  notAZip,

  /// No pack.json at its top (or in its one top folder).
  noPack,

  /// pack.json didn't parse as a schema-1 pack; [PetImportException.detail] says where.
  badPack,

  /// A sheet pack.json names isn't in the zip.
  missingSheet,

  /// A sheet isn't a PNG, is too big, or its cells don't fit in it.
  badSheet,

  /// Bigger than a pet should be.
  tooLarge,

  /// The phone wouldn't let it be written.
  storage,
}

class PetImportException implements Exception {
  const PetImportException(this.problem, [this.detail]);

  final PetImportProblem problem;
  final String? detail;

  @override
  String toString() => 'PetImportException(${problem.name}${detail == null ? '' : ': $detail'})';
}

/// A sheet decodes to at most this many bytes (RGBA). The format suggests
/// 8 MB; Deepy's biggest is 12.9 MB, so a little room past that.
const petSheetDecodedCap = 16 * 1024 * 1024;

/// Neither side of a sheet longer than this (many GPUs' texture limit).
const petSheetSideCap = 4096;

const _packJsonCap = 256 * 1024;
const _sheetFileCap = 8 * 1024 * 1024;
const _sheetsCap = 64;
const _totalCap = 48 * 1024 * 1024;

/// Where brought pets are kept (tests swap in a temporary folder).
final petLibraryProvider = Provider<PetLibrary>(
  (ref) => PetLibrary(() async => Directory('${(await getApplicationSupportDirectory()).path}/pets')),
);

/// The brought pets on this phone.
class PetLibrary {
  PetLibrary(this._root);

  /// `<app support>/pets` (tests: a temporary folder).
  final Future<Directory> Function() _root;

  Future<Directory> folder(String id) async => Directory('${(await _root()).path}/$id');

  /// Every brought pet that still parses, oldest first.
  Future<List<PetPack>> list() async {
    final root = await _root();
    if (!await root.exists()) return const [];
    final found = <(DateTime, PetPack)>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final id = entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (!isUserPet(id)) continue;
      try {
        final json = File('${entity.path}/pack.json');
        found.add((await json.lastModified(), await load(id)));
      } on Object {
        // Half there or broken: not offered.
      }
    }
    found.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final (_, pack) in found) pack];
  }

  /// One brought pet, reading its sheets from its folder.
  Future<PetPack> load(String id) async {
    final dir = await folder(id);
    final json = jsonDecode(await File('${dir.path}/pack.json').readAsString());
    if (json is! Map<String, Object?>) throw const FormatException('pack.json');
    final pack = PetPack.parse(json, dir: dir.path);
    if (pack.id != id) throw const FormatException('pack.json: id');
    return pack;
  }

  /// Checks and unpacks [zip]; a pet with the same id is replaced. Returns
  /// its id and whether it replaced one.
  Future<({String id, bool replaced})> install(File zip) async {
    final root = await _root();
    return compute(_install, (zip.path, root.path, DateTime.now().microsecondsSinceEpoch));
  }

  Future<void> remove(String id) async {
    if (!isUserPet(id)) return;
    final dir = await folder(id);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

/// The id a pack is kept under: its own, made safe for a folder name, after
/// [userPetPrefix] (kept when it is there already, as in a pack exported
/// from here).
@visibleForTesting
String userPetIdFor(String packId) {
  var slug = packId.toLowerCase();
  if (slug.startsWith(userPetPrefix)) slug = slug.substring(userPetPrefix.length);
  slug = slug.replaceAll(RegExp('[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.length > 40) slug = slug.substring(0, 40).replaceAll(RegExp(r'-+$'), '');
  return '$userPetPrefix${slug.isEmpty ? 'pet' : slug}';
}

/// A sheet's own name: a plain PNG file name, nothing that climbs or nests.
bool _safeSheet(String name) =>
    name.isNotEmpty &&
    name.length <= 120 &&
    !name.contains('/') &&
    !name.contains('\\') &&
    !name.contains('\u0000') &&
    !name.startsWith('.') &&
    name.toLowerCase().endsWith('.png');

/// A PNG's width and height from its header; null when it isn't one.
@visibleForTesting
(int, int)? pngSize(Uint8List bytes) {
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (bytes.length < 24) return null;
  for (var i = 0; i < 8; i++) {
    if (bytes[i] != signature[i]) return null;
  }
  // The first chunk is IHDR: length, type, then width and height.
  if (String.fromCharCodes(bytes.sublist(12, 16)) != 'IHDR') return null;
  final data = ByteData.sublistView(bytes);
  return (data.getUint32(16), data.getUint32(20));
}

Future<({String id, bool replaced})> _install((String, String, int) args) async {
  final (zipPath, rootPath, stamp) = args;
  final staging = Directory('$rootPath/.staging-$stamp');
  final input = InputFileStream(zipPath);
  try {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeStream(input);
    } on Object {
      throw const PetImportException(PetImportProblem.notAZip);
    }
    // Something that isn't a zip can read as an empty one.
    if (archive.files.isEmpty) throw const PetImportException(PetImportProblem.notAZip);
    final files = {
      for (final f in archive.files)
        if (f.isFile && !f.isSymbolicLink) f.name: f,
    };

    // pack.json at the top, or in the one folder the zip was made from.
    final packs = files.keys.where((n) => n == 'pack.json' || RegExp(r'^[^/]+/pack\.json$').hasMatch(n)).toList()
      ..sort((a, b) => a.length.compareTo(b.length));
    if (packs.isEmpty) throw const PetImportException(PetImportProblem.noPack);
    final packEntry = files[packs.first]!;
    final prefix = packs.first.substring(0, packs.first.length - 'pack.json'.length);
    if (packEntry.size > _packJsonCap) throw const PetImportException(PetImportProblem.tooLarge, 'pack.json');

    final Map<String, Object?> json;
    final PetPack pack;
    try {
      final decoded = jsonDecode(utf8.decode(packEntry.readBytes() ?? Uint8List(0)));
      if (decoded is! Map<String, Object?>) throw const FormatException('pack.json');
      json = decoded;
      pack = PetPack.parse(json);
    } on FormatException catch (error) {
      throw PetImportException(PetImportProblem.badPack, error.message);
    }

    // Every sheet named, there, a PNG, and big enough for the cells it is read at.
    final sheets = <String, List<PetAnimation>>{};
    for (final anim in pack.animations.values) {
      if (!_safeSheet(anim.sheet)) throw PetImportException(PetImportProblem.badSheet, anim.sheet);
      (sheets[anim.sheet] ??= []).add(anim);
    }
    if (sheets.length > _sheetsCap) throw const PetImportException(PetImportProblem.tooLarge);
    final bytes = <String, Uint8List>{};
    var total = 0;
    for (final MapEntry(key: sheet, value: anims) in sheets.entries) {
      final entry = files['$prefix$sheet'];
      if (entry == null) throw PetImportException(PetImportProblem.missingSheet, sheet);
      if (entry.size > _sheetFileCap) throw PetImportException(PetImportProblem.tooLarge, sheet);
      final data = entry.readBytes();
      // A header can lie about the size; what came out can't.
      if (data == null || data.length > _sheetFileCap) throw PetImportException(PetImportProblem.tooLarge, sheet);
      total += data.length;
      if (total > _totalCap) throw const PetImportException(PetImportProblem.tooLarge);
      final size = pngSize(data);
      if (size == null) throw PetImportException(PetImportProblem.badSheet, sheet);
      final (w, h) = size;
      if (w <= 0 || h <= 0 || w > petSheetSideCap || h > petSheetSideCap || w * h * 4 > petSheetDecodedCap) {
        throw PetImportException(PetImportProblem.badSheet, sheet);
      }
      for (final anim in anims) {
        final last = anim.frames.map((f) => f.i).reduce(math.max);
        final rows = last ~/ anim.cols + 1;
        if (anim.cols * anim.frameWidth > w || rows * anim.frameHeight > h) {
          throw PetImportException(PetImportProblem.badSheet, '${anim.name} → $sheet');
        }
      }
      bytes[sheet] = data;
    }

    // Written aside, then swapped in, so a pet is never half there.
    final id = userPetIdFor(pack.id);
    await staging.create(recursive: true);
    for (final MapEntry(key: sheet, value: data) in bytes.entries) {
      await File('${staging.path}/$sheet').writeAsBytes(data, flush: true);
    }
    await File('${staging.path}/pack.json').writeAsString(jsonEncode({...json, 'id': id}), flush: true);
    final live = Directory('$rootPath/$id');
    final old = Directory('$rootPath/.old-$stamp');
    final replaced = await live.exists();
    if (replaced) await live.rename(old.path);
    try {
      await staging.rename(live.path);
    } on FileSystemException {
      if (replaced) await old.rename(live.path);
      rethrow;
    }
    if (replaced) await old.delete(recursive: true);
    return (id: id, replaced: replaced);
  } on PetImportException {
    rethrow;
  } on FileSystemException catch (error) {
    throw PetImportException(PetImportProblem.storage, error.osError?.message);
  } finally {
    await input.close();
    if (await staging.exists()) await staging.delete(recursive: true);
  }
}
