part of 'engine.dart';

/// Only owned data crosses the seal. These methods cannot read an engine,
/// execute a host callback, or turn a sample ledger into a real bind proof.
final class _AuthoringPromptContextCapture {
  _AuthoringPromptContextCapture({
    required this.turn,
    required this.history,
    required this.parent,
    required this.userSiblingIndex,
    required this.actorData,
    required this.hostData,
    required this.global,
    required this.macroChatIdentity,
    required this.books,
    required this.missingBooks,
    required this.origin,
    required this.scripts,
    required _AuthoringSecretFacts secretFacts,
    required List<String> contextPath,
    required Map<String, Object?>? directorSource,
    required Map<String, Object?> authorizationSource,
    required Map<String, Object?> storyState,
    required Map<String, StoredAgentRun> audits,
    required List<({String id, Map<String, Object?> entry, bool valid})> legacy,
    required List<StoredRememberMemory> remembered,
    required Set<String> physicalParents,
    required StoredAgentRun? persistedProposal,
    required Map<String, Object?>? bindingSource,
    required Map<String, Object?>? bindingState,
    required Map<String, Object?>? bindingExtra,
  }) : _secretFacts = secretFacts,
       _contextPath = contextPath,
       _directorSource = directorSource,
       _authorizationSource = authorizationSource,
       _storyState = storyState,
       _audits = audits,
       _legacy = legacy,
       _remembered = remembered,
       _physicalParents = physicalParents,
       _persistedProposal = persistedProposal,
       _bindingSource = bindingSource,
       _bindingState = bindingState,
       _bindingExtra = bindingExtra;

  final _Turn turn;
  final List<StoredNode> history;
  final String? parent;
  final int userSiblingIndex;
  final Map<String, Object?> actorData, hostData, global, origin;
  final String macroChatIdentity;
  final List<WorldInfoBook> books;
  final List<Map<String, Object?>> missingBooks;
  final _AuthoringScriptCapture scripts;
  final _AuthoringSecretFacts _secretFacts;
  final List<String> _contextPath;
  final Map<String, Object?>? _directorSource, _bindingSource, _bindingState, _bindingExtra;
  final Map<String, Object?> _authorizationSource, _storyState;
  final Map<String, StoredAgentRun> _audits;
  final List<({String id, Map<String, Object?> entry, bool valid})> _legacy;
  final List<StoredRememberMemory> _remembered;
  final Set<String> _physicalParents;
  final StoredAgentRun? _persistedProposal;

  bool prepareBeforeUser() {
    if (_prepareSecretBindingFromFacts(
      turn,
      hostData,
      parent,
      currentChat: turn.chat,
      physicalParents: _physicalParents,
      persistedProposal: _persistedProposal,
      source: _bindingSource,
      saved: _bindingState,
      rawExtra: _bindingExtra,
      facts: _secretFacts,
    )) {
      return true;
    }
    _prepareStateTurn(turn, hostData);
    turn.directorPrepared = _prepareDirectorFromFacts(
      turn,
      hostData,
      parent,
      contextPath: _contextPath,
      source: _directorSource,
      currentSettings: _secretFacts.settings,
      authorizationSource: _authorizationSource,
      storyState: _storyState,
      bindAudits: _audits,
    );
    _prepareCardEventTurnFromFacts(turn, hostData, _audits);
    return false;
  }

  List<WorldInfoBook> directorBooks() {
    final prepared = _directorBooksFromFacts(turn, books, legacy: _legacy, remembered: _remembered);
    if (prepared.inspection case final inspection?) {
      turn.inspection = inspection;
    }
    return prepared.books;
  }

  List<PromptInjection> secretInjections() => _secretTurnInjectionsFromFacts(turn, hostData, _secretFacts);

  void captureAssembly(PromptAssembly assembly, WorldInfoResult world) {
    final inspection = _directorAssemblyInspection(turn, assembly, world);
    if (inspection != null) {
      turn.inspection = inspection;
    }
  }

  void finalSecretCheck({required String? currentLeafId, required Map<String, Object?> replyState}) {
    final inspection = _prepareSecretRequestFromFacts(
      turn,
      _secretFacts,
      currentLeafId: currentLeafId,
      replyState: replyState,
    );
    if (inspection != null) {
      turn.inspection = inspection;
    }
  }
}

typedef _AuthoringAuditRead = ({StoredAgentRun? row, Object? error, StackTrace? stack});

/// Audits may become relevant only after local state initialization. A failed
/// read is retained as that dependency's error, not treated as an absent proof
/// or thrown before the original definition/path/value gate reaches it.
final class _AuthoringCapturedAudits extends MapBase<String, StoredAgentRun> {
  _AuthoringCapturedAudits(this.reads);
  final Map<String, _AuthoringAuditRead> reads;
  @override
  StoredAgentRun? operator [](Object? key) {
    final value = reads[key];
    if (value == null) {
      return null;
    }
    final error = value.error;
    if (error != null) {
      Error.throwWithStackTrace(error, value.stack!);
    }
    return value.row;
  }

  @override
  Iterable<String> get keys =>
      reads.entries.where((entry) => entry.value.row != null || entry.value.error != null).map((entry) => entry.key);
  @override
  void operator []=(String key, StoredAgentRun value) => throw UnsupportedError('Captured audits are read-only.');
  @override
  void clear() => throw UnsupportedError('Captured audits are read-only.');
  @override
  StoredAgentRun? remove(Object? key) => throw UnsupportedError('Captured audits are read-only.');
}

extension _AuthoringPromptContexts on TavernEngine {
  Future<_AuthoringPromptContextCapture> _captureAuthoringPromptContext(
    TavernAuthoringPromptRequest request,
    String captureId,
    ModelCancellation cancellation,
  ) async {
    cancellation.check();
    final storedDraft = _requireAuthoringDraft(request.draftId, request.draftRevision);
    final draft = _authoringView(storedDraft);
    final candidates = _materializeAuthoring(draft, request.changeIds.toSet(), includeDiffs: false).candidates;
    final draftText = jsonEncode(storedDraft.data);
    final sourceById = {for (final source in draft.sources) source.physicalResourceId: source};
    final domain = _authoringAuthority.domainId;
    final configVersion = _authoringConfigVersion;
    final personaVersion = _personas.authoringVersion;
    final settingsIdentity = _document['settings'];
    final globalSettings = _map(settingsIdentity);
    final settingsText = jsonEncode(globalSettings);
    final globalObservation = _globalVariables.observation;
    final global = _runtimeCopy(_globalVariables);
    final defaultPresetId = _store.defaultPresetId;
    final context = request.context;
    final real = context is TavernAuthoringChatContext;
    final StoredChat chat;
    final TavernGroupChat? group;
    final _TurnKind kind;
    final StoredNode? target;
    final String actorId;
    final String? parent, sourceFile;
    final Map<String, Object?> metadata, initialState, identityState, local;
    final List<StoredNode> history;
    final PersonaSelection persona;
    final TavernModelConfig selectedConfig;
    final ChatJsonlMetadataSource? metadataSource;
    final String versionKey;
    final Object chatVersion;
    final ({String? leaf, Map<String, Object?> values})? liveLocal;
    final String? liveLocalFingerprint;

    // All selected chat facts and identities are captured before the first
    // await. Later conditional reads must pass this same admission guard.
    if (context is TavernAuthoringChatContext) {
      kind = switch (context.generationType) {
        'normal' => _TurnKind.send,
        'regenerate' => _TurnKind.regenerate,
        'continue' => _TurnKind.continueReply,
        'impersonate' => _TurnKind.impersonate,
        _ => throw const TavernAuthoringException('invalid_change', 'Unknown preview generation type.'),
      };
      if (kind != _TurnKind.send && request.text.isNotEmpty) {
        _authoringInvalid('Only normal previews accept new input text.');
      }
      if ((kind == _TurnKind.send || kind == _TurnKind.impersonate) && context.nodeId != null ||
          (kind == _TurnKind.regenerate || kind == _TurnKind.continueReply) && context.nodeId == null) {
        _authoringInvalid('Only regenerate/continue contexts take a required target node.');
      }
      chat = _store.chat(context.chatId);
      versionKey = chat.id;
      chatVersion = _store.displayVersion(versionKey);
      group = _store.groupChat(chat.id);
      target = context.nodeId == null ? null : _store.node(chat.id, context.nodeId!);
      if (target != null && target.message.role != TavernRole.character) {
        _authoringInvalid('The target must be a character message.');
      }
      if (group == null) {
        if (context.actorId != null && context.actorId != chat.characterId) {
          _authoringInvalid('A single chat uses its own character.');
        }
        actorId = chat.characterId;
        selectedConfig = _config;
      } else {
        if (kind == _TurnKind.impersonate) {
          throw const TavernAuthoringException('unsupported_preview', 'Group impersonation is unsupported.');
        }
        final member = group.members.where((value) => value.characterId == context.actorId).firstOrNull;
        if (member == null || target != null && target.message.speakerCharacterId != member.characterId) {
          _authoringInvalid('Select the actual roster actor for this group context.');
        }
        if (kind == _TurnKind.send && request.text.isNotEmpty) {
          throw const TavernAuthoringException(
            'unsupported_preview',
            'Group user preparation before the actor turn needs an isolated adapter.',
          );
        }
        actorId = member.characterId;
        selectedConfig = _groupModelConfig(_config, member.modelRole);
      }
      parent = kind == _TurnKind.regenerate
          ? target!.message.parentId
          : kind == _TurnKind.continueReply
          ? target!.message.nodeId
          : chat.currentLeafId;
      final sourceNode = target ?? (chat.currentLeafId == null ? null : _store.node(chat.id, chat.currentLeafId!));
      metadata = _chatCodec.metadataForCapturedNode(_store, chat, sourceNode);
      final sourceState = sourceNode == null
          ? _store.groupInitialState(chat.id)
          : _stateFromNode(chat.id, sourceNode, chat: chat);
      final rawSource =
          sourceState['chatJsonlSourceFile'] ?? _map(_map(chat.metadata['dshgo'])['chatJsonl'])['rootFile'];
      sourceFile = rawSource is String ? rawSource : null;
      metadataSource = _chatCodec.metadataSourceTargetForState(chat, sourceState);
      initialState = group != null && parent == null
          ? _store.groupInitialState(chat.id)
          : parent == null && chat.currentLeafId == null && kind != _TurnKind.regenerate
          ? _emptyChatState(metadata)
          : _stateAt(chat.id, parent);
      identityState = _stateAt(chat.id, context.nodeId ?? parent);
      liveLocal = _liveVariables[chat.id];
      liveLocalFingerprint = liveLocal == null ? null : _scriptRuntimeFingerprint(liveLocal.values);
      local = kind != _TurnKind.regenerate && liveLocal != null && liveLocal.leaf == parent
          ? _runtimeCopy(liveLocal.values)
          : initialState.containsKey('variables')
          ? _map(initialState['variables'])
          : kind == _TurnKind.regenerate || parent != null && sourceFile != null
          ? <String, Object?>{}
          : _copy(chat.variables);
      history = _historyTo(chat.id, parent);
      persona = _personas.resolve(personaId: chat.personaId);
    } else {
      final sample = context as TavernAuthoringSampleContext;
      final source = sourceById[sample.characterResourceId];
      if (source == null || source.target.kind != TavernAuthoringTargetKind.character) {
        _authoringInvalid('A sample character must be a character source in this draft.');
      }
      actorId = source.target.id;
      kind = _TurnKind.send;
      group = null;
      target = null;
      selectedConfig = _config;
      metadata = <String, Object?>{};
      sourceFile = null;
      metadataSource = null;
      initialState = _copy(sample.state);
      identityState = _copy(sample.state);
      local = _copy(sample.variables);
      history = _authoringSampleHistory(sample, captureId, request.at);
      parent = history.lastOrNull?.message.nodeId;
      chat = StoredChat(
        id: '$captureId:chat',
        characterId: actorId,
        title: '',
        createdAt: request.at,
        updatedAt: request.at,
        metadata: metadata,
        variables: _copy(sample.variables),
        settings: _copy(sample.settings),
        currentLeafId: parent,
        selectedRootId: history.firstOrNull?.message.nodeId,
        personaId: sample.personaId,
        presetId: sample.presetId,
      );
      // Preset commits already invalidate every display token. One fixed
      // cache-only key also covers sample selection without creating a chat.
      versionKey = '\u0000authoring:presets';
      chatVersion = _store.displayVersion(versionKey);
      liveLocal = null;
      liveLocalFingerprint = null;
      persona = _personas.resolve(personaId: sample.personaId);
    }
    String? selectedPresetId;
    Map<String, Object?>? presetRaw;
    final presetRows = <String, Map<String, Object?>?>{};
    bool selectPreset(String id) {
      final candidate = candidates['preset:$id'];
      // Retain the native stored-row validation when no draft replaces it.
      final current = candidate == null ? _store.preset(id) : null;
      presetRows[id] = _store.readAuthoringPresetData(id);
      if (candidate == null && current == null) {
        return false;
      }
      selectedPresetId = id;
      if (candidate == null) {
        presetRaw = current!.raw;
      } else {
        final raw = _authoringObject(candidate['raw'], 'The preset raw value must be an object.');
        final envelope = candidate['envelope'] == null
            ? null
            : _authoringObject(candidate['envelope'], 'The preset envelope must be an object.');
        const PresetCodec().validate(raw, envelope: envelope);
        presetRaw = raw;
      }
      return true;
    }

    // Match native bound/inline/default precedence, resolving each referenced
    // ID against the saved candidate before considering a lower fallback.
    // The current row or its absence remains separate seal evidence.
    final boundPresetId = chat.presetId;
    if ((boundPresetId == null || !selectPreset(boundPresetId)) &&
        !chat.settings.containsKey('preset') &&
        defaultPresetId != null) {
      selectPreset(defaultPresetId);
    }
    final director = real ? _directors.latestSuccess(chat.id) : null;
    final rawTurnSettings = _authoringContextSettings(
      globalSettings,
      chat,
      metadata,
      selectedPreset: presetRaw,
      managedRegex: const [],
    );
    final admissionSettings = _personaSettings(rawTurnSettings, persona);
    final secret = real && kind != _TurnKind.impersonate && _secretsEnabled(admissionSettings)
        ? _store.agentRunsByKind(chat.id, const {'director.secret_proposal'}, limit: 1).firstOrNull
        : null;
    final cardRevision = real ? _directors._cardRevisions[chat.characterId] ?? 0 : 0;
    final links = real && (secret != null || kind == _TurnKind.send && request.text.isNotEmpty)
        ? _store.treeLinks(chat.id).values.toList()
        : <StoredTreeLink>[];
    final physicalParents = {
      for (final link in links)
        if (link.parentId != null) link.parentId!,
    };
    final userSiblingIndex = kind == _TurnKind.send && request.text.isNotEmpty
        ? links.where((link) => !link.deleted && link.parentId == parent).length
        : 0;
    final policyScope = kind == _TurnKind.impersonate ? null : _toolScope(this, chat);
    final scripts = _scripts.captureAuthoringScripts(
      captureId: captureId,
      chatId: real ? chat.id : null,
      metadata: metadata,
      persistentSource: metadataSource,
    );
    final resources = <String, _AuthoringCapturedResource>{};
    final auditReads = <String, _AuthoringAuditRead>{};
    final audits = _AuthoringCapturedAudits(auditReads);

    void checkAdmission() {
      cancellation.check();
      if (_authoringAuthority.domainId != domain ||
          !identical(_authoringConfigVersion, configVersion) ||
          !identical(_personas.authoringVersion, personaVersion) ||
          !identical(_document['settings'], settingsIdentity) ||
          jsonEncode(_map(_document['settings'])) != settingsText ||
          _globalVariables.observation != globalObservation ||
          !identical(_store.displayVersion(versionKey), chatVersion) ||
          _store.defaultPresetId != defaultPresetId) {
        _authoringContextConflict();
      }
      if (real) {
        final current = _liveVariables[chat.id];
        if (current == null || liveLocal == null) {
          if ((current == null) != (liveLocal == null)) {
            _authoringContextConflict();
          }
        } else if (current.leaf != liveLocal.leaf ||
            !identical(current.values, liveLocal.values) ||
            _scriptRuntimeFingerprint(current.values) != liveLocalFingerprint) {
          _authoringContextConflict();
        }
        if ((_directors._cardRevisions[chat.characterId] ?? 0) != cardRevision) {
          _authoringContextConflict();
        }
      }
    }

    Future<_AuthoringCapturedResource> capture(TavernAuthoringTarget target) async {
      final previous = resources[target.physicalResourceId];
      if (previous != null) {
        return previous;
      }
      cancellation.check();
      final value = await _captureAuthoringResource(target, seedDraft: storedDraft);
      cancellation.check();
      resources[target.physicalResourceId] = value;
      return value;
    }

    void captureAudit(String id) {
      if (!real || auditReads.containsKey(id)) {
        return;
      }
      try {
        auditReads[id] = (row: _store.agentRunById(chat.id, id), error: null, stack: null);
      } catch (error, stack) {
        auditReads[id] = (row: null, error: error, stack: stack);
      }
    }

    void captureLedger(Map<String, Object?> saved) {
      if (!real) {
        return;
      }
      final ledger = _SecretLedger(saved);
      for (final binding in ledger.bindings) {
        captureAudit(binding['bindReceiptId']! as String);
      }
    }

    final cards = <String, StoredCharacter>{};
    final cardDocuments = <String, Map<String, Object?>>{};
    for (final id in {chat.characterId, actorId, ...?group?.members.map((value) => value.characterId)}) {
      final resource = await capture(TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: id));
      final document = candidates[resource.target.physicalResourceId] ?? resource.document;
      if (resource.document == null || document == null) {
        continue;
      }
      cardDocuments[id] = document;
      cards[id] = _authoringRuntimeCharacter(resource, document, request.at);
    }
    final host = cards[chat.characterId], actor = cards[actorId];
    if (host == null || actor == null) {
      throw const TavernImportError('角色不存在。');
    }

    for (final id in presetRows.keys) {
      final resource = await capture(TavernAuthoringTarget(kind: TavernAuthoringTargetKind.preset, id: id));
      if (!_stateJsonEqual(resource.document, presetRows[id])) {
        _authoringContextConflict();
      }
    }
    final regex = await capture(
      const TavernAuthoringTarget(kind: TavernAuthoringTargetKind.regexLibrary, id: 'global'),
    );
    final managedRegex = candidates['regex-library'] == null
        ? [
            for (final script in regex._regexRecords!) {...script.raw, if (!script.compatible) 'disabled': true},
          ]
        : await _authoringContextRegex(
            candidates['regex-library']!,
            sourceById['regex-library']!.base,
            _regexWorker,
            cancellation,
          );
    final settings = _personaSettings(
      _authoringContextSettings(globalSettings, chat, metadata, selectedPreset: presetRaw, managedRegex: managedRegex),
      persona,
    );
    final config = TavernModelConfig(
      apiKey: _noAuthoringTransportKey,
      model: selectedConfig.model,
      deepseek: selectedConfig.deepseek,
      thinking: selectedConfig.thinking,
    );
    final turn = _Turn(
      chat,
      kind,
      request.text,
      target?.message.nodeId,
      null,
      config,
      settings,
      request.at,
      persona,
      metadata,
      sourceFile,
      selectedPresetId,
      actorId: actorId,
      groupView: group == null ? null : _GroupView(group, host, cards),
      previewId: captureId,
      previewCancellation: cancellation,
    );
    turn.originalTarget = target;
    turn.directorCaptured = director;
    turn.secretCaptured = secret;
    turn.secretCardRevision = cardRevision;
    turn.variables = local;
    turn.state = _copy(initialState);
    if (sourceFile != null) {
      turn.state['chatJsonlSourceFile'] = sourceFile;
    }
    turn.inspection = turn.inspection.copyWith(contextNodeId: parent, clearContextNodeId: parent == null);
    turn.scriptInjectionUses = scripts.uses;
    final data = _effectiveCard(actor.card.data, settings);
    final hostData = _effectiveCard(host.card.data, settings);
    turn.directorCard = _copy(hostData);
    if (kind != _TurnKind.impersonate) {
      final roundPolicy = group != null && kind == _TurnKind.send;
      final hostPolicy = captureToolCardPolicy(
        roundPolicy ? host.card.data : _authoringPolicyCard(cardDocuments[host.id]!, host),
        characterId: host.id,
      );
      final actorPolicy = actor.id == host.id
          ? hostPolicy
          : captureToolCardPolicy(
              roundPolicy ? actor.card.data : _authoringPolicyCard(cardDocuments[actor.id]!, actor),
              characterId: actor.id,
            );
      turn.toolPolicyScope = policyScope;
      turn.toolPolicy = captureToolPolicy(scope: policyScope!, host: hostPolicy, actor: actorPolicy);
    }

    checkAdmission();
    Map<String, Object?>? currentSettings;
    Map<String, Object?> readCurrentSettings() {
      if (currentSettings case final value?) {
        return value;
      }
      final currentMetadata = real ? _chatCodec.metadataForNode(_store, chat.id) : metadata;
      return currentSettings = _authoringContextSettings(
        globalSettings,
        chat,
        currentMetadata,
        selectedPreset: presetRaw,
        managedRegex: managedRegex,
      );
    }

    // The binding wrapper reads current settings before its disabled gate;
    // final injections read them only when this turn enabled secrets.
    if (secret != null || kind != _TurnKind.impersonate && _secretsEnabled(settings)) {
      readCurrentSettings();
    }
    final contextPath = history.map((node) => node.message.nodeId).toList();
    Map<String, Object?>? directorSource;
    var authorizationSource = <String, Object?>{};
    var storyState = <String, Object?>{};
    var directorEligible = false;
    if (director != null && kind != _TurnKind.impersonate) {
      try {
        final run = _directorRun(director);
        if (!(run.sourceKind == 'empty' && kind == _TurnKind.regenerate) &&
            _directorPathReason(run, parent, contextPath) == null) {
          directorSource = _directorSource(this, chat.id, run.sourceNodeId);
          if (_directorSourceReason(run, hostData, _directorPersona(persona, settings), directorSource) == null) {
            final current = readCurrentSettings();
            final authorizationState = parent == null && group == null
                ? _emptyChatState(_chatCodec.metadataForNode(_store, chat.id))
                : _stateAt(chat.id, parent);
            authorizationSource = _secretStateSource(authorizationState);
            captureLedger(authorizationState);
            final policy = _ordinarySecretInputFromFacts(
              chat.characterId,
              hostData,
              current,
              authorizationSource,
              audits,
            ).policy;
            final prior = director.result['secretPolicy'];
            final reason = policy == null && prior == null
                ? null
                : prior is! Map<String, Object?>
                ? 'director_secret_knowledge_changed'
                : _secretKnowledgeReason(policy, prior);
            if (reason == null) {
              final definition = _storyDefinition(hostData);
              if (definition.defined && definition.executable) {
                storyState = parent == null ? <String, Object?>{} : _stateAt(chat.id, parent);
              }
              directorEligible =
                  _storyDirectorEligibilityFromState(director, hostData, storyState, definition: definition) == null;
            }
          }
        }
      } catch (_) {
        // This is precisely the native director eligibility catch, not a
        // fallback for main state, secret binding, or resource I/O errors.
        directorSource = null;
      }
    }
    if (directorEligible) {
      final savedDirector = director!;
      final events = _directorRun(savedDirector).events;
      for (var index = 0; index < events.length; index++) {
        captureAudit('${savedDirector.id}:event:$index');
      }
    }
    final current = currentSettings ?? settings;
    final secretFacts = _AuthoringSecretFacts(
      settings: current,
      persona: _directorPersona(persona, _personaSettings(current, persona)),
      cardRevision: cardRevision,
      bindAudits: audits,
    );
    StoredAgentRun? persistedProposal;
    Map<String, Object?>? bindingSource, bindingState, bindingExtra;
    if (secret != null &&
        _secretBindingDisabled(turn, hostData, current) == null &&
        _secretContextReasonFromFacts(turn, secretFacts) == null &&
        _secretBindingAnchorReason(turn, parent, secret, chat.currentLeafId) == null &&
        !physicalParents.contains(parent) &&
        _secretProposalShapeReason(secret, chat.characterId) == null) {
      captureAudit(secret.id);
      persistedProposal = audits[secret.id];
      if (_secretProposalPersisted(secret, persistedProposal) &&
          _secretPersonaReason(turn, secretFacts.persona) == null) {
        bindingSource = _directorSource(this, chat.id, parent);
        if (_directorSourceFingerprint(bindingSource, _directorCard(hostData), secretFacts.persona) ==
            secret.result['sourceFingerprint']) {
          bindingState = _stateAt(chat.id, parent);
          final input = _StateInput(bindingState);
          final protection = _SecretProtection(hostData, bindingState);
          if (input.writable && input.valueExists && !protection.unknown && protection.definition.executable) {
            bindingExtra = _store.rawNodeExtra(chat.id, parent!);
          }
        }
      }
    }
    if (kind != _TurnKind.impersonate && _secretsEnabled(settings)) {
      captureLedger(initialState);
    }

    final loaded = <WorldInfoBook>[];
    final missing = <Map<String, Object?>>[];
    final bindings = _map(settings['lorebooks']);
    final activeWorldName = metadata['world_info'];
    final activeBookId = activeWorldName is String ? _map(chat.settings['stLorebookIds'])[activeWorldName] : null;
    for (final source in WorldInfoSource.values) {
      final ids = <String>[
        ..._strings(bindings[source.name]),
        if (source == WorldInfoSource.character)
          for (final id in group == null ? [actorId] : [for (final member in group.members) member.characterId])
            ..._strings(_map(settings['characterLorebooks'])[id]),
        if (source == WorldInfoSource.persona && persona.persona != null)
          ..._strings(_map(settings['personaLorebooks'])[persona.persona!.id]),
      ];
      for (final id in ids) {
        final resource = await capture(TavernAuthoringTarget(kind: TavernAuthoringTargetKind.lorebook, id: id));
        final document = candidates[resource.target.physicalResourceId] ?? resource.document;
        if (document == null) {
          missing.add({'bookId': id, 'source': source.name, 'reason': 'missing'});
          continue;
        }
        final raw = _authoringBook(document);
        final envelope = !document.containsKey('entries') && document['format'] == 'dshgo-lorebook';
        loaded.add(
          WorldInfoBook.fromJson(
            id: id,
            source: source,
            json: raw,
            stWorldName: activeBookId == id && activeWorldName is String
                ? activeWorldName
                : envelope
                ? document['stWorldName'] as String?
                : null,
          ),
        );
      }
    }
    final embedded = group == null
        ? <String, Map<String, Object?>>{actorId: data}
        : {
            for (final member in group.members)
              if (cards[member.characterId] case final value?) member.characterId: value.card.data,
          };
    for (final entry in embedded.entries) {
      if (entry.value['character_book'] case final Map<String, Object?> book) {
        loaded.add(WorldInfoBook.fromJson(id: '${entry.key}:card', source: WorldInfoSource.character, json: book));
      }
    }
    checkAdmission();
    final legacy = real && directorEligible
        ? _store.directorMemories(chat.id)
        : <({String id, Map<String, Object?> entry, bool valid})>[];
    final remembered = real ? _store.rememberMemories(chat.id, requestedLeafId: parent) : <StoredRememberMemory>[];
    final legacyText = _authoringLegacyText(legacy), rememberedText = _authoringRememberedText(remembered);
    await _recheckCapturedAuthoringResources(
      resources.values,
      check: () {
        checkAdmission();
        final freshDraft = _store.readAuthoringDraftData(request.draftId);
        if (freshDraft == null ||
            freshDraft.revision != request.draftRevision ||
            jsonEncode(freshDraft.data) != draftText) {
          _authoringContextConflict();
        }
        if (real) {
          if (_authoringAuditText(_directors.latestSuccess(chat.id)) != _authoringAuditText(director)) {
            _authoringContextConflict();
          }
          if (kind != _TurnKind.impersonate &&
              _secretsEnabled(admissionSettings) &&
              _authoringAuditText(
                    _store.agentRunsByKind(chat.id, const {'director.secret_proposal'}, limit: 1).firstOrNull,
                  ) !=
                  _authoringAuditText(secret)) {
            _authoringContextConflict();
          }
          for (final entry in auditReads.entries) {
            // An unreadable dependency is not absent evidence. Its original
            // error remains deferred until an actual pure consumer reaches it.
            if (entry.value.error != null) {
              continue;
            }
            if (_authoringAuditText(_store.agentRunById(chat.id, entry.key)) != _authoringAuditText(entry.value.row)) {
              _authoringContextConflict();
            }
          }
          if (directorEligible && _authoringLegacyText(_store.directorMemories(chat.id)) != legacyText ||
              _authoringRememberedText(_store.rememberMemories(chat.id, requestedLeafId: parent)) != rememberedText) {
            _authoringContextConflict();
          }
        }
        _scripts.recheckAuthoringScripts(scripts);
      },
    );
    return _AuthoringPromptContextCapture(
      turn: turn,
      history: history,
      parent: parent,
      userSiblingIndex: userSiblingIndex,
      actorData: data,
      hostData: hostData,
      global: global,
      macroChatIdentity: _macroChatIdentity(
        chat,
        identityState,
        metadata,
        sourceFile,
        node: target ?? history.lastOrNull,
      ),
      books: loaded,
      missingBooks: missing,
      scripts: scripts,
      secretFacts: secretFacts,
      contextPath: contextPath,
      directorSource: directorSource,
      authorizationSource: authorizationSource,
      storyState: storyState,
      audits: audits,
      legacy: legacy,
      remembered: remembered,
      physicalParents: physicalParents,
      persistedProposal: persistedProposal,
      bindingSource: bindingSource,
      bindingState: bindingState,
      bindingExtra: bindingExtra,
      origin: {
        'kind': real ? 'chat' : 'sample',
        'chatId': real ? chat.id : null,
        'contextNodeId': parent,
        'actorId': actorId,
        'generationType': turn.generationType,
        'model': config.model,
        'deepseek': config.deepseek,
        'thinking': config.thinking,
        'presetId': selectedPresetId,
        'resources': [
          for (final resource in resources.values)
            {
              'physicalResourceId': resource.target.physicalResourceId,
              'seedDraftId': resource.seedDraftId,
              'capturedSnapshot': {
                'origin': resource.seedDraftId == null ? 'existing' : 'seed',
                'present': resource.snapshot.present,
                'hash': _directorHash(resource.snapshot.toJson()),
              },
              'knownAuthority': resource.ledger == null
                  ? null
                  : {
                      'domainId': resource.ledger!.domainId,
                      'revision': resource.ledger!.revision,
                      'snapshotHash': resource.ledger!.snapshot == null
                          ? null
                          : _directorHash(resource.ledger!.snapshot!.toJson()),
                    },
              'candidate': {
                'origin': candidates.containsKey(resource.target.physicalResourceId) ? 'draft' : 'capture',
                if (candidates.containsKey(resource.target.physicalResourceId)) 'draftRevision': request.draftRevision,
                'documentHash': _directorHash(candidates[resource.target.physicalResourceId] ?? resource.document),
              },
            },
        ],
      },
    );
  }
}

Map<String, Object?> _authoringContextSettings(
  Map<String, Object?> global,
  StoredChat chat,
  Map<String, Object?> metadata, {
  required Map<String, Object?>? selectedPreset,
  required List<Map<String, Object?>> managedRegex,
}) {
  var result = _merge(
    global,
    _chatMetadataSettings(metadata, _map(chat.settings['stLorebookIds']), _map(global['authorNote'])),
  );
  result = _merge(result, chat.settings);
  if (selectedPreset != null) {
    result['preset'] = _copy(selectedPreset);
  } else if (chat.settings.containsKey('preset')) {
    result['preset'] = _map(chat.settings['preset']);
  }
  final overrides = _map(result['presetOverrides']);
  final sampling = <String, Object?>{
    for (final key in const [
      'temperature',
      'top_p',
      'presence_penalty',
      'frequency_penalty',
      'openai_max_tokens',
      'openai_max_context',
    ])
      if (overrides.containsKey(key)) key: overrides[key],
  };
  if (sampling.isNotEmpty) {
    result['preset'] = {..._map(result['preset']), ...sampling};
  }
  result.remove('managedRegexScripts');
  if (managedRegex.isNotEmpty) {
    result['managedRegexScripts'] = managedRegex;
  }
  return result;
}

Future<List<Map<String, Object?>>> _authoringContextRegex(
  Map<String, Object?> document,
  Map<String, Object?> base,
  RegexExecutor worker,
  ModelCancellation cancellation,
) async {
  final records = document['scripts'];
  if (document['version'] != 1 || records is! List<Object?>) {
    _authoringInvalid('A regex candidate must contain version 1 and a scripts array.');
  }
  final savedRecords = (base['scripts']! as List<Object?>).whereType<Map<String, Object?>>();
  final result = <Map<String, Object?>>[];
  for (final record in records) {
    if (record is! Map<String, Object?> || record['raw'] is! Map<String, Object?>) {
      _authoringInvalid('A regex candidate record must contain its raw object.');
    }
    cancellation.check();
    final raw = record['raw']! as Map<String, Object?>;
    final saved = record['id'] is String
        ? savedRecords.where((value) => value['id'] == record['id']).firstOrNull
        : null;
    var incompatible = false;
    if (saved != null && _stateJsonEqual(raw, saved['raw'])) {
      // Native execution preserves a saved compatibility decision until the
      // raw script is edited or explicitly rechecked. An unrelated draft
      // change must not silently re-enable it by compiling the same raw.
      final diagnostics = record['diagnostics'];
      if (diagnostics is! List<Object?>) {
        _authoringInvalid('An unchanged regex record must retain its diagnostics array.');
      }
      for (final value in diagnostics) {
        final diagnostic = TavernRegexDiagnostic.fromJson(
          _authoringObject(value, 'A regex diagnostic must be an object.'),
        );
        if (diagnostic.status == TavernRegexCompatibility.incompatible) {
          incompatible = true;
        }
      }
    } else {
      final diagnostic = await inspectRegexScript(raw, worker);
      cancellation.check();
      incompatible = diagnostic.status == TavernRegexCompatibility.incompatible;
    }
    result.add({...raw, if (incompatible) 'disabled': true});
  }
  return result;
}

StoredCharacter _authoringRuntimeCharacter(
  _AuthoringCapturedResource resource,
  Map<String, Object?> document,
  DateTime at,
) {
  final current = resource.character;
  if (current != null && _stateJsonEqual(document, resource.document)) {
    return current;
  }
  final parsed = const CardCodec().decode(Uint8List.fromList(utf8.encode(jsonEncode(document))));
  final format = TavernCardFormat.values.byName(resource.sourceFormat!);
  return StoredCharacter(
    id: resource.target.id,
    importedAt: current?.importedAt ?? at,
    card: TavernCard(
      json: parsed.json,
      assets: {for (final path in resource.mediaRefs) path: resource.media['resources/$path']!},
      png: resource.media['source.png'] ?? (format == TavernCardFormat.png ? resource.media['original.png'] : null),
      originalBytes: resource.media['original.${format.name}'],
      sourceFormat: format,
    ),
  );
}

Map<String, Object?> _authoringPolicyCard(Map<String, Object?> document, StoredCharacter runtime) =>
    document['spec'] == 'chara_card_v3' && document['data'] is Map<String, Object?>
    ? document['data']! as Map<String, Object?>
    : runtime.card.data;

List<StoredNode> _authoringSampleHistory(TavernAuthoringSampleContext sample, String captureId, DateTime at) => [
  for (var index = 0; index < sample.history.length; index++)
    StoredNode(
      message: TavernMessage(
        nodeId: '$captureId:message:$index',
        parentId: index == 0 ? null : '$captureId:message:${index - 1}',
        role: sample.history[index].role,
        speaker:
            sample.history[index].speaker ?? (sample.history[index].role == TavernRole.user ? 'User' : 'Assistant'),
        text: sample.history[index].text,
        reasoning: sample.history[index].reasoning,
        hidden: sample.history[index].hidden,
        at: sample.history[index].at ?? at,
      ),
      depth: index + 1,
      selectedChildId: index + 1 == sample.history.length ? null : '$captureId:message:${index + 1}',
      extra: <String, Object?>{},
      original: <String, Object?>{},
    ),
];

String? _authoringAuditText(StoredAgentRun? value) => value == null
    ? null
    : jsonEncode({
        'id': value.id,
        'chatId': value.chatId,
        'nodeId': value.nodeId,
        'kind': value.kind,
        'at': value.at.microsecondsSinceEpoch,
        'usage': value.usage,
        'result': value.result,
      });
String _authoringLegacyText(List<({String id, Map<String, Object?> entry, bool valid})> values) => jsonEncode([
  for (final value in values) {'id': value.id, 'entry': value.entry, 'valid': value.valid},
]);
String _authoringRememberedText(List<StoredRememberMemory> values) => jsonEncode([
  for (final value in values)
    {
      'id': value.id,
      'rowId': value.rowId,
      'entry': value.entry,
      'available': value.available,
      'reason': value.unavailableReason,
      'source': value.source?.toJson(),
    },
]);
Never _authoringContextConflict() =>
    throw const TavernAuthoringException('capture_conflict', 'An authoring preview context changed during capture.');
