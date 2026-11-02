// Where a typed install spec points. Pure: the page collects text, this says
// what it is, tests pin the answers.
//
// The three forms the Host's `pluginManager/inspect` understands are npm
// (`@scope/plugin`, `plugin@1.2.3`), git (`owner/repo`, `git+https://…`,
// `https://github.com/you/dsh-plugin`) and a tarball URL (`https://…/x.tgz`).
// Local paths are deliberately not offered: a phone has no picker for them.

/// What a typed spec points at.
enum PluginSpecKind {
  /// An npm package name, optionally followed by a version.
  npm,

  /// A git repository shorthand or URL.
  git,

  /// A `.tgz` download URL.
  tarball,

  /// Not something the page sends to the Host.
  invalid,
}

final _npmName = RegExp(r'^(@[a-z0-9][\w.-]*/)?[a-z0-9][\w.-]*(@[\w.^~*x-]+)?$', caseSensitive: false);
final _shorthand = RegExp(r'^[\w.-]+/[\w.-]+$');
final _http = RegExp(r'^https?://', caseSensitive: false);
const _gitHosts = ['github.com', 'gitlab.com', 'bitbucket.org'];

/// Classifies [raw] (trimmed) — never throws, never reports [PluginSpecKind.invalid]
/// for something the Host would accept as npm.
PluginSpecKind classifyPluginSpec(String raw) {
  final spec = raw.trim();
  if (spec.isEmpty || spec.contains(' ') || spec.contains('\n')) return PluginSpecKind.invalid;
  // A phone has no directory picker: a local path is not something to offer.
  if (spec.startsWith('.') || spec.startsWith('/') || spec.startsWith('~')) return PluginSpecKind.invalid;
  final lower = spec.toLowerCase();
  if (lower.startsWith('git+')) return PluginSpecKind.git;
  if (_http.hasMatch(lower)) {
    if (lower.endsWith('.tgz') || lower.endsWith('.tar.gz')) return PluginSpecKind.tarball;
    if (lower.endsWith('.git')) return PluginSpecKind.git;
    if (_gitHosts.any((h) => lower.contains('://$h/') || lower.contains('://www.$h/'))) return PluginSpecKind.git;
    return PluginSpecKind.invalid;
  }
  // `owner/repo` is a git shorthand; `@scope/name` is npm (the @ leads it).
  if (!spec.startsWith('@') && _shorthand.hasMatch(spec)) return PluginSpecKind.git;
  if (_npmName.hasMatch(spec)) return PluginSpecKind.npm;
  return PluginSpecKind.invalid;
}

/// The one-line example the empty field carries, per [kind].
String pluginSpecExample(PluginSpecKind kind) => switch (kind) {
  PluginSpecKind.npm => '@scope/plugin',
  PluginSpecKind.git => 'https://github.com/you/dsh-plugin',
  PluginSpecKind.tarball => 'https://…/x.tgz',
  PluginSpecKind.invalid => '@scope/plugin',
};
