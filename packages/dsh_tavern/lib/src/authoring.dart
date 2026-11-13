import 'import_report.dart';
import 'regex/regex_types.dart';

/// Stable failures at the authoring boundary. Storage/IO failures keep their
/// original exception; callers must not infer adoption from an exception.
final class TavernAuthoringException implements Exception {
  const TavernAuthoringException(this.code, this.message, {this.physicalResourceId, this.changeId});

  /// Stage 2A: not_found, revision_conflict, invalid_change, missing_dependency.
  final String code;
  final String message;
  final String? physicalResourceId;
  final String? changeId;

  @override
  String toString() => 'TavernAuthoringException($code): $message';
}

enum TavernAuthoringTargetKind { character, lorebook, regexLibrary, preset }

/// An existing resource. An embedded book belongs to its character target;
/// the managed regex library is one target with id = 'global'.
final class TavernAuthoringTarget {
  const TavernAuthoringTarget({required this.kind, required this.id});

  final TavernAuthoringTargetKind kind;
  final String id;

  String get physicalResourceId => switch (kind) {
    TavernAuthoringTargetKind.character => 'character:$id',
    TavernAuthoringTargetKind.lorebook => 'lorebook:$id',
    TavernAuthoringTargetKind.regexLibrary => 'regex-library',
    TavernAuthoringTargetKind.preset => 'preset:$id',
  };
}

/// A durable authority token, distinct from a draft's edit revision and the
/// script bridge's runtime token. Stage 2A does not issue these tokens.
final class TavernAuthorityRevision {
  const TavernAuthorityRevision({required this.domainId, required this.revision});

  final String domainId;
  final int revision;

  @override
  bool operator ==(Object other) =>
      other is TavernAuthorityRevision && other.domainId == domainId && other.revision == revision;

  @override
  int get hashCode => Object.hash(domainId, revision);
}

/// Detached complete JSON, including the original envelope and unknown keys.
/// Media references are retained; their files are not part of a JSON edit.
final class TavernAuthoringSource {
  const TavernAuthoringSource({
    required this.target,
    required this.sourceFormat,
    required this.base,
    this.mediaRefs = const [],
    this.authorityRevision,
    this.applySupported = false,
  });

  final TavernAuthoringTarget target;
  String get physicalResourceId => target.physicalResourceId;
  final String sourceFormat;
  final Map<String, Object?> base;
  final List<String> mediaRefs;
  final TavernAuthorityRevision? authorityRevision;

  /// False for every Stage 2A source. A later adapter must explicitly rebase a
  /// draft that was captured before durable authority was installed.
  final bool applySupported;
}

enum TavernAuthoringChangeKind { set, remove }

/// A JSON Pointer change. Set supports object keys and existing array slots;
/// remove deletes an object key. Edit array length/order with an entire-array
/// set. Overlapping paths require an explicit dependency on the earlier change.
final class TavernAuthoringChange {
  const TavernAuthoringChange({
    required this.id,
    required this.physicalResourceId,
    required this.path,
    required this.operation,
    this.value,
    this.dependsOn = const [],
  });

  final String id;
  final String physicalResourceId;
  final String path;
  final TavernAuthoringChangeKind operation;
  final Object? value;
  final List<String> dependsOn;
}

final class TavernAuthoringDiff {
  const TavernAuthoringDiff({
    required this.changeId,
    required this.physicalResourceId,
    required this.path,
    required this.beforeExists,
    required this.before,
    required this.afterExists,
    required this.after,
  });

  final String changeId;
  final String physicalResourceId;
  final String path;
  final bool beforeExists;
  final Object? before;
  final bool afterExists;
  final Object? after;
}

/// A detached draft snapshot. Its base never refreshes implicitly on reopen.
final class TavernAuthoringDraft {
  const TavernAuthoringDraft({
    required this.id,
    required this.draftRevision,
    required this.sources,
    required this.changes,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final int draftRevision;
  final List<TavernAuthoringSource> sources;
  final List<TavernAuthoringChange> changes;
  final DateTime createdAt;
  final DateTime updatedAt;
}

final class TavernAuthoringDraftSummary {
  const TavernAuthoringDraftSummary({
    required this.id,
    required this.draftRevision,
    required this.targets,
    required this.updatedAt,
  });

  final String id;
  final int draftRevision;
  final List<TavernAuthoringTarget> targets;
  final DateTime updatedAt;
}

/// Static validation and selected candidates; this is not a prompt assembly or
/// a claim that a rule will activate in a future turn. No candidate is adopted.
final class TavernAuthoringPreview {
  const TavernAuthoringPreview({
    required this.draftId,
    required this.draftRevision,
    required this.changeIds,
    required this.candidates,
    required this.diffs,
    required this.reports,
    required this.issues,
  });

  final String draftId;
  final int draftRevision;
  final List<String> changeIds;
  final Map<String, Map<String, Object?>> candidates;
  final List<TavernAuthoringDiff> diffs;
  final Map<String, List<TavernImportReport>> reports;
  final Map<String, List<TavernImportFinding>> issues;
}

/// Tests only a draft script's pattern. A null match means matching did not
/// execute (for example, compilation was skipped for a runtime macro).
final class TavernAuthoringRegexTest {
  const TavernAuthoringRegexTest({
    required this.draftId,
    required this.draftRevision,
    required this.physicalResourceId,
    required this.scriptPath,
    required this.compilation,
    this.match,
  });

  final String draftId;
  final int draftRevision;
  final String physicalResourceId;
  final String scriptPath;
  final RegexCompileResult compilation;
  final RegexMatchResult? match;
}
