part of 'chat_store.dart';

typedef StoredGameplayPack = ({TavernPackVersion? version, Map<String, Uint8List> files});

/// The fixed database facts used by a read-only gameplay preview.
/// No open transaction or database callback crosses this boundary.
final class StoredGameplaySnapshot {
  const StoredGameplaySnapshot({
    required this.domainId,
    required this.chat,
    required this.group,
    required this.node,
    required this.state,
    required this.defaultPresetId,
    required this.selectedPreset,
    required this.presetRows,
    required this.packs,
  });

  final String domainId;
  final StoredChat? chat;
  final TavernGroupChat? group;
  final StoredNode? node;
  final Map<String, Object?>? state;
  final String? defaultPresetId;
  final StoredPreset? selectedPreset;
  final Map<String, Map<String, Object?>?> presetRows;
  final Map<(String, String), StoredGameplayPack> packs;
}

extension GameplaySnapshotStore on ChatStore {
  StoredGameplaySnapshot readGameplaySnapshot({
    String? chatId,
    required List<TavernPackVersionRef> packRefs,
    Set<(String, String)> resourcesFor = const {},
    bool readInitialState = false,
  }) {
    _ensureOpen();
    final failure = _transactionFailure;
    if (failure != null) {
      Error.throwWithStackTrace(failure.error, failure.stackTrace);
    }
    // onCommitted runs after COMMIT while the managed depth is still nonzero.
    // Actual SQLite state determines whether this reader owns a transaction.
    final owns = _db.autocommit;
    final managedDepth = _transactionDepth;
    var started = false;
    try {
      if (owns) {
        _db.execute('BEGIN DEFERRED');
        started = true;
      }
      final domain = authoringDomainId;
      final currentChat = chatId == null ? null : chat(chatId);
      final group = chatId == null ? null : groupChat(chatId);
      final leaf = currentChat?.currentLeafId;
      final currentNode = leaf == null ? null : node(chatId!, leaf);
      Map<String, Object?>? state;
      if (currentNode != null) {
        final own = currentNode.extra['dshgo'];
        final override = own is Map<String, Object?> ? own['tavernState'] : null;
        // A portable override is the existing reader's first choice. Do not
        // read a separate physical delta chain which that reader never uses.
        state = override is Map<String, Object?> ? override : nodeState(chatId!, currentNode.message.nodeId);
      } else if (chatId != null && readInitialState) {
        state = groupInitialState(chatId);
      }
      final defaultId = defaultPresetId;
      final presetRows = <String, Map<String, Object?>?>{};
      StoredPreset? selected;
      bool selectPreset(String id) {
        final value = preset(id);
        presetRows[id] = readAuthoringPresetData(id);
        selected = value;
        return value != null;
      }

      final bound = currentChat?.presetId;
      if ((bound == null || !selectPreset(bound)) &&
          !(currentChat?.settings.containsKey('preset') ?? false) &&
          defaultId != null) {
        selectPreset(defaultId);
      }
      final packs = <(String, String), StoredGameplayPack>{};
      for (final ref in packRefs) {
        final key = (ref.installedPackId, ref.packVersion);
        if (packs.containsKey(key)) {
          continue;
        }
        final version = _readGameplayVersion(ref);
        final files = <String, Uint8List>{};
        if (version != null && !version.removed && resourcesFor.contains(key)) {
          for (final resource in gameplayPackResources(version.manifest)) {
            if (!const {'lorebook', 'regex', 'castCard'}.contains(resource['kind'])) {
              continue;
            }
            final path = resource['path']! as String;
            if (files.containsKey(path)) {
              continue;
            }
            final rows = _db.select(
              '''
              SELECT bytes FROM gameplay_pack_files
              WHERE installed_pack_id = ? AND pack_version = ? AND path = ?''',
              [ref.installedPackId, ref.packVersion, path],
            );
            if (rows.isEmpty) {
              throw StateError('A stored gameplay resource file is missing.');
            }
            files[path] = Uint8List.fromList(rows.single['bytes'] as Uint8List);
          }
        }
        packs[key] = (version: version, files: files);
      }
      final result = StoredGameplaySnapshot(
        domainId: domain,
        chat: currentChat,
        group: group,
        node: currentNode,
        state: state,
        defaultPresetId: defaultId,
        selectedPreset: selected,
        presetRows: presetRows,
        packs: packs,
      );
      if (owns) {
        _db.execute('COMMIT');
      }
      return result;
    } catch (error, stackTrace) {
      try {
        if (owns && started && !_db.autocommit) {
          _db.execute('ROLLBACK');
        }
        if (!owns && managedDepth > 0 && _db.autocommit) {
          _transactionFailure ??= (error: error, stackTrace: stackTrace);
        }
      } catch (_) {
        _transactionFailure ??= (error: error, stackTrace: stackTrace);
      }
      rethrow;
    }
  }
}
