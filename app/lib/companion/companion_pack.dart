// The companion's downloaded assets (docs/design/companion.md): a zip with the
// Live2D runtime (`runtime/`) and one character (`character/`). Neither ships in
// the APK or the repository.
//
// What's checked on the way in, because the page runs this content in a WebView:
//  - `runtime/` is code, so it must match the digest pinned below, whoever made
//    the zip. That's what lets a character come from anywhere.
//  - `character/` is data only: an extension allow-list, no scripts or HTML.
//  - every path stays inside its folder; size and count are capped.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// `runtime digest` printed by tooling/companion/build-pack.mjs.
const companionRuntimeDigest = '20e4e35ce1de09bd9017197363a96afdb4d9fc045d574fb669ebf21b4bc92e81';

/// Where the pack downloads from. Null until one is published: import works
/// without it. (url, bytes, sha256)
const CompanionPackSource? companionPackSource = null;

@immutable
class CompanionPackSource {
  const CompanionPackSource({required this.urls, required this.bytes, required this.sha256});
  final List<String> urls;
  final int bytes;
  final String sha256;
}

enum CompanionPackProblem {
  notAPack,
  unsafePath,
  tooLarge,
  forbiddenFile,
  runtimeMismatch,
  noRuntime,
  noModel,
  storage,
}

class CompanionPackException implements Exception {
  const CompanionPackException(this.problem, [this.detail]);
  final CompanionPackProblem problem;
  final String? detail;

  @override
  String toString() => 'CompanionPackException(${problem.name}${detail == null ? '' : ': $detail'})';
}

/// What the page shows about the installed character.
@immutable
class CompanionCharacter {
  const CompanionCharacter({this.name, this.author, this.license, this.source});

  factory CompanionCharacter.fromJson(Object? json) {
    final map = json is Map ? json : const {};
    String? text(String key) =>
        map[key] is String && (map[key] as String).trim().isNotEmpty ? map[key] as String : null;
    return CompanionCharacter(
      name: text('name'),
      author: text('author'),
      license: text('license'),
      source: text('source'),
    );
  }

  final String? name;
  final String? author;
  final String? license;
  final String? source;
}

const _maxBytes = 400 * 1024 * 1024;
const _maxFiles = 4000;
const _dataExtensions = {'.json', '.moc3', '.png', '.jpg', '.jpeg', '.webp', '.wav', '.mp3', '.txt', '.md'};

/// The recipe in build-pack.mjs: over sorted `name\0sha256hex\n`.
String runtimeDigest(Map<String, String> sha256ByName) {
  final names = sha256ByName.keys.toList()..sort();
  return sha256.convert(utf8.encode([for (final n in names) '$n\u0000${sha256ByName[n]}\n'].join())).toString();
}

/// Whether [path] is a plain relative path with no way out of its folder.
bool isSafePackPath(String path) {
  if (path.isEmpty || path.contains('\\') || path.startsWith('/') || path.contains('\u0000')) return false;
  return path.split('/').every((part) => part.isNotEmpty && part != '.' && part != '..');
}

class CompanionPackStore {
  CompanionPackStore(this.root, {this.expectedRuntime = companionRuntimeDigest});

  /// The app's private folder for this; the pack lands in `<root>/pack`.
  final Directory root;
  final String expectedRuntime;

  Directory get pack => Directory('${root.path}/pack');

  Future<bool> installed() async =>
      await File('${pack.path}/runtime/live2dcubismcore.min.js').exists() &&
      await File('${pack.path}/character/index.json').exists();

  Future<CompanionCharacter> character() async {
    try {
      return CompanionCharacter.fromJson(
        jsonDecode(await File('${pack.path}/character/character.json').readAsString()),
      );
    } catch (_) {
      return const CompanionCharacter();
    }
  }

  /// Unpacks [zip] next to the current pack and swaps it in. A failure leaves
  /// the current pack as it was. A zip with only `character/` keeps the runtime
  /// already installed.
  Future<void> install(String zip) => compute(_install, (zip, root.path, expectedRuntime));

  Future<void> remove() async {
    if (await pack.exists()) await pack.delete(recursive: true);
  }
}

Future<void> _install((String, String, String) args) async {
  final (zipPath, rootPath, expected) = args;
  final staging = Directory('$rootPath/pack.staging');
  final previous = Directory('$rootPath/pack.previous');
  final live = Directory('$rootPath/pack');
  final input = InputFileStream(zipPath);
  try {
    await _forget(staging);
    await staging.create(recursive: true);

    final Archive archive;
    try {
      archive = ZipDecoder().decodeStream(input);
    } on Object {
      throw const CompanionPackException(CompanionPackProblem.notAPack);
    }

    final files = archive.files.where((f) => f.isFile).toList();
    if (files.isEmpty) throw const CompanionPackException(CompanionPackProblem.notAPack);
    if (files.length > _maxFiles) throw const CompanionPackException(CompanionPackProblem.tooLarge);
    var declared = 0;
    for (final file in files) {
      final name = file.name;
      if (!isSafePackPath(name) || (!name.startsWith('runtime/') && !name.startsWith('character/'))) {
        throw CompanionPackException(CompanionPackProblem.unsafePath, name);
      }
      if (file.isSymbolicLink) throw CompanionPackException(CompanionPackProblem.forbiddenFile, name);
      if (name.startsWith('character/') && !_dataExtensions.contains(_extension(name))) {
        throw CompanionPackException(CompanionPackProblem.forbiddenFile, name);
      }
      declared += file.size;
      if (declared > _maxBytes) throw const CompanionPackException(CompanionPackProblem.tooLarge);
    }

    final runtimeHashes = <String, String>{};
    final characterFiles = <String>[];
    var written = 0;
    for (final file in files) {
      final target = File('${staging.path}/${file.name}');
      await target.parent.create(recursive: true);
      final output = OutputFileStream(target.path);
      try {
        file.writeContent(output);
      } on Object {
        await output.close();
        throw CompanionPackException(CompanionPackProblem.notAPack, file.name);
      }
      await output.close();
      // A header can lie about the size; what landed on disk can't.
      written += await target.length();
      if (written > _maxBytes) throw const CompanionPackException(CompanionPackProblem.tooLarge);
      if (file.name.startsWith('runtime/')) {
        runtimeHashes[file.name] = (await sha256.bind(target.openRead()).first).toString();
      } else {
        characterFiles.add(file.name.substring('character/'.length));
      }
    }

    if (runtimeHashes.isNotEmpty) {
      if (runtimeDigest(runtimeHashes) != expected) {
        throw const CompanionPackException(CompanionPackProblem.runtimeMismatch);
      }
    } else {
      final current = Directory('${live.path}/runtime');
      if (!await current.exists()) throw const CompanionPackException(CompanionPackProblem.noRuntime);
      await _copy(current, Directory('${staging.path}/runtime'));
    }
    if (!characterFiles.any((f) => f.endsWith('.model3.json'))) {
      throw const CompanionPackException(CompanionPackProblem.noModel);
    }
    await File('${staging.path}/character/index.json').writeAsString(jsonEncode(characterFiles));

    // The old pack goes last, so a failure here never leaves nothing.
    await _forget(previous);
    if (await live.exists()) await live.rename(previous.path);
    await staging.rename(live.path);
    await _forget(previous);
  } on CompanionPackException {
    await _forget(staging);
    rethrow;
  } on FileSystemException catch (error) {
    await _forget(staging);
    throw CompanionPackException(CompanionPackProblem.storage, error.osError?.message);
  } finally {
    await input.close();
  }
}

String _extension(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot).toLowerCase();
}

Future<void> _copy(Directory from, Directory to) async {
  await for (final entity in from.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final target = File('${to.path}/${entity.path.substring(from.path.length + 1)}');
    await target.parent.create(recursive: true);
    await entity.copy(target.path);
  }
}

Future<void> _forget(Directory staging) async {
  try {
    if (await staging.exists()) await staging.delete(recursive: true);
  } on FileSystemException {
    // The next install starts by clearing it again.
  }
}
