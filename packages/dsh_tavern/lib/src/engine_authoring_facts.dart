part of 'engine.dart';

/// Capture-owned facts, detached once before sealing. The audit map contains
/// only rows read from the origin chat; neither a sample nor a host can supply
/// an audit. A missing row is absent evidence, never an inferred local bind.
final class _AuthoringSecretFacts {
  const _AuthoringSecretFacts({
    required this.settings,
    required this.persona,
    required this.cardRevision,
    required this.bindAudits,
  });
  final Map<String, Object?> settings, persona;
  final int cardRevision;
  final Map<String, StoredAgentRun> bindAudits;
}

_DirectorPrepared? _prepareDirectorFromFacts(
  _Turn turn,
  Map<String, Object?> data,
  String? parent, {
  required List<String> contextPath,
  required Map<String, Object?>? source,
  required Map<String, Object?> currentSettings,
  required Map<String, Object?> authorizationSource,
  required Map<String, Object?> storyState,
  required Map<String, StoredAgentRun> bindAudits,
}) {
  final stored = turn.directorCaptured;
  if (stored == null || turn.kind == _TurnKind.impersonate) {
    return null;
  }
  try {
    final run = _directorRun(stored);
    final reason = run.sourceKind == 'empty' && turn.kind == _TurnKind.regenerate
        ? 'director_source_not_on_path'
        : _directorEligibilityFromFacts(
            run,
            stored,
            turn.chat.characterId,
            data,
            _directorPersona(turn.personaSelection, turn.settings),
            parent,
            contextPath: contextPath,
            source: source,
            currentSettings: currentSettings,
            authorizationSource: authorizationSource,
            storyState: storyState,
            bindAudits: bindAudits,
          );
    return _directorPreparation(stored, run, reason);
  } catch (_) {
    return _DirectorPrepared(stored, null, false, [
      _directorIssue('saved_director_run_unavailable', id: stored.id),
    ], const {});
  }
}

String? _directorEligibilityFromFacts(
  TavernDirectorRun run,
  StoredAgentRun stored,
  String characterId,
  Map<String, Object?> data,
  Map<String, Object?> persona,
  String? parent, {
  required List<String> contextPath,
  required Map<String, Object?>? source,
  required Map<String, Object?> currentSettings,
  required Map<String, Object?> authorizationSource,
  required Map<String, Object?> storyState,
  required Map<String, StoredAgentRun> bindAudits,
}) {
  try {
    final pathReason = _directorPathReason(run, parent, contextPath);
    if (pathReason != null) {
      return pathReason;
    }
    if (source == null) {
      return 'director_source_unavailable';
    }
    final sourceReason = _directorSourceReason(run, data, persona, source);
    if (sourceReason != null) {
      return sourceReason;
    }
    final current = _ordinarySecretInputFromFacts(
      characterId,
      data,
      currentSettings,
      authorizationSource,
      bindAudits,
    ).policy;
    final prior = stored.result['secretPolicy'];
    final secretReason = current == null && prior == null
        ? null
        : prior is! Map<String, Object?>
        ? 'director_secret_knowledge_changed'
        : _secretKnowledgeReason(current, prior);
    return secretReason ?? _storyDirectorEligibilityFromState(stored, data, storyState);
  } catch (_) {
    return 'director_source_unavailable';
  }
}

({List<WorldInfoBook> books, TavernTurnInspection? inspection}) _directorBooksFromFacts(
  _Turn turn,
  List<WorldInfoBook> loaded, {
  required List<({String id, Map<String, Object?> entry, bool valid})> legacy,
  required List<StoredRememberMemory> remembered,
}) {
  final prepared = turn.directorPrepared;
  final legacyBook = prepared != null && prepared.eligible
      ? _directorMemoryBookFromRows(turn.chat.id, turn.at, legacy)
      : (book: null, issues: <Map<String, Object?>>[]);
  final withLegacy = [...loaded, if (legacyBook.book != null) legacyBook.book!];
  final rememberedBook = _rememberMemoryBookFromRows(_rememberMemoryBookId(turn.chat.id, withLegacy), remembered);
  return _directorBooksPrepared(turn, loaded, legacyBook, rememberedBook);
}

List<state_core.SecretRelease> _secretReleasesFromFacts(
  String characterId,
  Map<String, Object?> data,
  Map<String, Object?> settings,
  Map<String, Object?> saved,
  _SecretProtection protection,
  Map<String, StoredAgentRun> bindAudits,
) {
  final input = _secretReleaseInput(data, settings, saved, protection);
  if (input == null) {
    return [];
  }
  final result = <state_core.SecretRelease>[];
  for (final binding in protection.ledger.bindings) {
    final release = _secretReleaseForBinding(characterId, input, protection, binding);
    if (release == null) {
      continue;
    }
    if (_secretProofMatches(bindAudits[binding['bindReceiptId']], binding)) {
      result.add(release);
    }
  }
  return result;
}

_SecretInput _ordinarySecretInputFromFacts(
  String characterId,
  Map<String, Object?> data,
  Map<String, Object?> settings,
  Map<String, Object?> source,
  Map<String, StoredAgentRun> bindAudits, {
  Map<String, Object?>? authorizationSource,
}) {
  final prepared = _prepareSecretInput(data, source, authorizationSource: authorizationSource);
  if (!prepared.active) {
    return _finishSecretInput(prepared, const {}, const []);
  }
  final currentReleases = prepared.unavailable
      ? <state_core.SecretRelease>[]
      : _secretReleasesFromFacts(
          characterId,
          data,
          settings,
          prepared.authorizationSaved,
          prepared.currentProtection,
          bindAudits,
        );
  final currentKnowledge = {for (final release in currentReleases) _directorHash(_secretKnowledge(release))};
  final releases = prepared.unavailable
      ? <state_core.SecretRelease>[]
      : _secretReleasesFromFacts(characterId, data, settings, prepared.saved, prepared.protection, bindAudits);
  return _finishSecretInput(prepared, currentKnowledge, releases);
}

String? _secretContextReasonFromFacts(_Turn turn, _AuthoringSecretFacts facts) =>
    _secretCardRevisionReason(turn, facts.cardRevision) ?? _secretPersonaReason(turn, facts.persona);

String? _secretDirectorTurnReasonFromFacts(_Turn turn, Map<String, Object?> saved, _AuthoringSecretFacts facts) {
  final prepared = turn.directorPrepared;
  if (prepared == null || !prepared.eligible) {
    return null;
  }
  final prior = prepared.stored.result['secretPolicy'];
  if (prior == null && turn.secretProtection?.active != true) {
    return null;
  }
  final data = turn.directorCard;
  if (data == null) {
    return 'secret_card_unavailable';
  }
  final reason = _secretContextReasonFromFacts(turn, facts);
  if (reason != null) {
    return reason;
  }
  final current = _ordinarySecretInputFromFacts(
    turn.chat.characterId,
    data,
    facts.settings,
    _secretStateSource(saved),
    facts.bindAudits,
  ).policy;
  return _secretKnowledgeReason(current, prior);
}

List<PromptInjection> _secretTurnInjectionsFromFacts(
  _Turn turn,
  Map<String, Object?> data,
  _AuthoringSecretFacts facts,
) {
  if (turn.kind == _TurnKind.impersonate || !_secretsEnabled(turn.settings)) {
    return [];
  }
  final reason = _secretContextReasonFromFacts(turn, facts);
  if (reason != null) {
    if (turn.secretProtection?.active == true) {
      turn.secretIssues.add(_directorIssue(reason));
    }
    return [];
  }
  final saved = turn.currentState;
  final releases = _secretReleasesFromFacts(
    turn.chat.characterId,
    data,
    facts.settings,
    saved,
    _SecretProtection(data, saved),
    facts.bindAudits,
  );
  return _secretReleaseInjections(turn, releases);
}

/// Checks the locally installed reply and the final included facts. This has
/// no client-call attempt and does not manufacture a committed bind audit.
TavernTurnInspection? _prepareSecretRequestFromFacts(
  _Turn turn,
  _AuthoringSecretFacts facts, {
  required String? currentLeafId,
  required Map<String, Object?> replyState,
}) {
  final directorIncluded = _secretDirectorIncluded(turn);
  final directorReason = _secretDirectorTurnReasonFromFacts(turn, turn.currentState, facts);
  if (directorIncluded && directorReason != null) {
    turn.secretIssues.add(_directorIssue(directorReason));
    throw StateError('Director knowledge authorization changed before the request.');
  }
  if (turn.secretIncluded.isEmpty) {
    return null;
  }
  final data = turn.directorCard;
  final reason = _secretContextReasonFromFacts(turn, facts);
  if (data == null ||
      reason != null ||
      !_secretsEnabled(turn.settings) ||
      !_secretsEnabled(facts.settings) ||
      turn.reply == null ||
      currentLeafId != turn.reply!.nodeId) {
    turn.secretIssues.add(_directorIssue(reason ?? 'secret_release_revoked'));
    throw StateError('Secret release authorization changed before the request.');
  }
  final current = _secretReleasesFromFacts(
    turn.chat.characterId,
    data,
    facts.settings,
    replyState,
    _SecretProtection(data, replyState),
    facts.bindAudits,
  );
  _checkSecretIncluded(turn, current);
  return turn.inspection.copyWith(
    state: {..._statePreparationTrace(turn), 'secrets': _secretTurnTrace(turn, attempted: false)},
  );
}

String? _secretBindingReasonFromFacts(
  _Turn turn,
  Map<String, Object?> data,
  String? parent,
  StoredAgentRun proposal, {
  required StoredChat currentChat,
  required Set<String> physicalParents,
  required StoredAgentRun? persistedProposal,
  required Map<String, Object?>? source,
  required _AuthoringSecretFacts facts,
}) {
  final disabled = _secretBindingDisabled(turn, data, facts.settings);
  if (disabled != null) {
    return disabled;
  }
  final contextReason = _secretContextReasonFromFacts(turn, facts);
  if (contextReason != null) {
    return contextReason;
  }
  final anchorReason = _secretBindingAnchorReason(turn, parent, proposal, currentChat.currentLeafId);
  if (anchorReason != null) {
    return anchorReason;
  }
  if (physicalParents.contains(parent)) {
    return 'secret_source_not_current_physical_leaf';
  }
  final proposalReason = _secretProposalShapeReason(proposal, currentChat.characterId);
  if (proposalReason != null) {
    return proposalReason;
  }
  if (!_secretProposalPersisted(proposal, persistedProposal)) {
    return 'secret_proposal_not_persisted';
  }
  final personaReason = _secretPersonaReason(turn, facts.persona);
  if (personaReason != null) {
    return personaReason;
  }
  if (source == null) {
    throw const TavernAuthoringException('unsupported_preview', 'The secret source was not captured.');
  }
  return _directorSourceFingerprint(source, _directorCard(data), facts.persona) == proposal.result['sourceFingerprint']
      ? null
      : 'secret_source_changed';
}

/// true means the native prepare accepted an actual new binding. C2 stops
/// here with secret_bind_required. A rejected prepare keeps its original
/// session, budget, receipts and trace; it is not a fresh ordinary session.
bool _prepareSecretBindingFromFacts(
  _Turn turn,
  Map<String, Object?> data,
  String? parent, {
  required StoredChat currentChat,
  required Set<String> physicalParents,
  required StoredAgentRun? persistedProposal,
  required Map<String, Object?>? source,
  required Map<String, Object?>? saved,
  required Map<String, Object?>? rawExtra,
  required _AuthoringSecretFacts facts,
}) {
  final proposal = turn.secretCaptured;
  if (proposal == null) {
    return false;
  }
  final reason = _secretBindingReasonFromFacts(
    turn,
    data,
    parent,
    proposal,
    currentChat: currentChat,
    physicalParents: physicalParents,
    persistedProposal: persistedProposal,
    source: source,
    facts: facts,
  );
  if (reason != null) {
    turn.secretIssues.add(_directorIssue(reason, id: proposal.id));
    return false;
  }
  turn.cancellation.check();
  if (saved == null) {
    throw const TavernAuthoringException('unsupported_preview', 'The secret state was not captured.');
  }
  final state = _secretBindingState(turn, data, proposal, saved);
  if (state == null) {
    return false;
  }
  if (rawExtra == null) {
    throw const TavernAuthoringException('unsupported_preview', 'The secret source extra was not captured.');
  }
  final capability = _secretBindingCapability(turn, proposal, state.input, state.protection, rawExtra);
  if (capability == null) {
    return false;
  }
  // The detached turn constructor supplies this capture-scoped identity.
  // Never fall back to the live invocation RNG in a preview.
  final preparation = _prepareSecretBindingPlan(turn, data, proposal, state.input, capability, turn.stateInvocationId!);
  return preparation?.prepared.accepted == true;
}
