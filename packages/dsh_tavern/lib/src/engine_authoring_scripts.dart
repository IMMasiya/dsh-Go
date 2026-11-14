part of 'engine.dart';

/// Static preparation inputs and read-only seal evidence. Registrations in
/// [uses] are local copies; no live context, host or coordinator is retained.
final class _AuthoringScriptCapture {
  _AuthoringScriptCapture({
    required this.uses,
    required this.chatId,
    required int hostVersion,
    required String contexts,
    required String registrations,
    required String? persistent,
    required ChatJsonlMetadataSource? persistentSource,
    required Map<String, Object?> localPersistent,
    required Map<String, _ScriptInjectionRegistration> localRegistrations,
  }) : _hostVersion = hostVersion,
       _contexts = contexts,
       _registrations = registrations,
       _persistent = persistent,
       _persistentSource = persistentSource,
       _localPersistent = localPersistent,
       _localRegistrations = localRegistrations;

  final _ScriptInjectionUseSet uses;
  final String? chatId;
  final int _hostVersion;
  final String _contexts, _registrations;
  final String? _persistent;
  final ChatJsonlMetadataSource? _persistentSource;
  final Map<String, Object?> _localPersistent;
  final Map<String, _ScriptInjectionRegistration> _localRegistrations;

  /// Runs at the native claim point, after the detached reply has been built.
  /// All local eligibility checks precede every local once mutation.
  List<TavernJsonObject> claim(_Turn turn) {
    if (turn.reply == null) {
      throw StateError('An isolated reply must exist before injection claim.');
    }
    for (final candidate in uses.used) {
      if (candidate.registration != null) {
        _checkScriptRegistrationClaim(candidate, _localRegistrations[candidate.rawId], turn.generationId);
      } else if (candidate.source == 'persistent') {
        final current = candidate.persistentSource?.identity == _persistentSource?.identity
            ? _localPersistentInjectionVersion(_persistentSource!, candidate.rawId, _localPersistent)
            : null;
        _checkScriptPersistentClaim(candidate, current, turn.generationId);
      }
    }
    return _claimScriptInjectionOnce(uses);
  }
}

extension _AuthoringScriptPreparation on _ScriptCoordinator {
  _AuthoringScriptCapture captureAuthoringScripts({
    required String captureId,
    required String? chatId,
    required Map<String, Object?> metadata,
    required ChatJsonlMetadataSource? persistentSource,
  }) {
    final active = _authoringScriptContexts(chatId);
    // The native host interface has no handler inventory. Every active chat
    // context receives both preparation lifecycles, so an attached host here
    // needs an actual isolated adapter even if it might ignore these events.
    if (_host != null && active.isNotEmpty) {
      throw const TavernAuthoringException(
        'unsupported_preview',
        'Active script preparation contexts require an isolated preview host.',
      );
    }
    if (chatId != null && persistentSource == null) {
      throw StateError('A captured chat requires its metadata source.');
    }
    final registrations = chatId == null
        ? <_ScriptInjectionRegistration>[]
        : (injectionRegistry._byChat[chatId]?.values ?? <_ScriptInjectionRegistration>[]).toList();
    final localRegistrations = <String, _ScriptInjectionRegistration>{};
    final localPersistent = <String, Object?>{};
    final candidates = <_ScriptInjectionCandidate>[];
    var index = 0;
    String assemblerId() => 'authoring:$captureId:script:${index++}';
    if (chatId != null) {
      for (final entry in _persistentScriptInjections(chatId, metadata).entries) {
        final raw = _captureScriptJson(entry.value);
        localPersistent[entry.key] = raw;
        final parsed = _parsePersistentScriptInjection(chatId, entry.key, raw);
        candidates.add(
          _ScriptInjectionCandidate(
            source: 'persistent',
            rawId: entry.key,
            sourceRef: parsed.sourceRef,
            raw: raw,
            assemblerId: assemblerId(),
            sourceOrder: 0,
            injection: parsed.injection,
            issues: parsed.issues,
            filterStatus: parsed.filterStatus,
            persistentSource: persistentSource,
            persistentVersion: _localPersistentInjectionVersion(persistentSource!, entry.key, localPersistent),
          ),
        );
      }
      for (final registration in registrations) {
        if (registration.claimed) {
          continue;
        }
        final local = _ScriptInjectionRegistration(
          chatId: registration.chatId,
          ownerContextId: registration.ownerContextId,
          ownerInstanceId: registration.ownerInstanceId,
          version: registration.version,
          leaseId: registration.leaseId,
          injection: _copyInjection(registration.injection),
          once: registration.once,
        );
        localRegistrations[local.injection.id] = local;
        candidates.add(_transientScriptInjection(local, assemblerId: assemblerId()));
      }
    }
    for (final candidate in candidates) {
      if (candidate.injection == null) {
        throw _scriptInjectionFailure(
          TavernScriptErrorCode.shapeMismatch,
          'A captured persistent injection cannot be prepared.',
          candidate,
          captureId,
          issues: candidate.issues,
        );
      }
      if (candidate.filterStatus == 'unsupportedPersistent' || candidate.injection!.filter != null) {
        throw TavernAuthoringException(
          'unsupported_preview',
          'Injection "${candidate.rawId}" requires an isolated filter capability.',
        );
      }
    }
    return _AuthoringScriptCapture(
      uses: _ScriptInjectionUseSet(candidates),
      chatId: chatId,
      hostVersion: _hostVersion,
      contexts: jsonEncode(active),
      registrations: _authoringRegistrationFingerprint(registrations),
      persistent: chatId == null ? null : _authoringPersistentFingerprint(metadata),
      persistentSource: persistentSource,
      localPersistent: localPersistent,
      localRegistrations: localRegistrations,
    );
  }

  /// Called inside the context's final synchronous seal. The context guard
  /// also checks its committed chat-view identity, including metadata ABA;
  /// this reader never creates or advances a persistent-injection observer.
  void recheckAuthoringScripts(_AuthoringScriptCapture captured) {
    final chatId = captured.chatId;
    final registrations = chatId == null
        ? <_ScriptInjectionRegistration>[]
        : injectionRegistry._byChat[chatId]?.values ?? <_ScriptInjectionRegistration>[];
    if (_closed ||
        _hostVersion != captured._hostVersion ||
        jsonEncode(_authoringScriptContexts(chatId)) != captured._contexts ||
        _authoringRegistrationFingerprint(registrations) != captured._registrations) {
      _authoringScriptConflict();
    }
    if (chatId != null) {
      final metadata = engine._chatCodec.readMetadataSource(
        engine._store.chat(chatId).metadata,
        captured._persistentSource!,
      );
      if (metadata == null || _authoringPersistentFingerprint(metadata) != captured._persistent) {
        _authoringScriptConflict();
      }
    }
  }

  List<List<String>> _authoringScriptContexts(String? chatId) => [
    if (chatId != null)
      for (final context in contexts.values)
        if (!context.closed && context.value.chatId == chatId) [context.value.id, context.value.instanceId],
  ];
}

String _authoringRegistrationFingerprint(Iterable<_ScriptInjectionRegistration> registrations) => jsonEncode([
  for (final value in registrations)
    [
      value.injection.id,
      value.ownerContextId,
      value.ownerInstanceId,
      value.version,
      value.leaseId,
      value.once,
      value.claimed,
    ],
]);

String _authoringPersistentFingerprint(Map<String, Object?> metadata) =>
    jsonEncode([metadata.containsKey('script_injects'), metadata['script_injects']]);

String _localPersistentInjectionVersion(ChatJsonlMetadataSource source, String id, Map<String, Object?> values) =>
    _scriptRuntimeFingerprint([source.identity, values.containsKey(id), values[id]]);

Never _authoringScriptConflict() => throw const TavernAuthoringException(
  'capture_conflict',
  'Script preparation dependencies changed during authoring capture.',
);
