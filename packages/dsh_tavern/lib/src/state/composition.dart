part of 'state_engine.dart';

/// Internal compile-only input. The caller already retained each source's
/// presence/version eligibility and passes its original state declaration.
typedef StateCompositionRuleSource = ({Map<String, Object?> source, String sourcePath, Map<String, Object?> state});

/// Plain owned inspection data, never a runnable definition or session.
final class StateCompositionInspection {
  const StateCompositionInspection({
    required this.executable,
    required this.definitionIssues,
    required this.ruleIssues,
    required this.rules,
    required this.validated,
    required this.valueIssues,
    required this.secretExecutable,
    required this.secretIssues,
  });

  final bool executable;
  final List<Map<String, Object?>> definitionIssues;
  final List<Map<String, Object?>> ruleIssues;
  final List<Map<String, Object?>> rules;
  final bool validated;
  final List<Map<String, Object?>> valueIssues;
  final bool secretExecutable;
  final List<Map<String, Object?>> secretIssues;
}

/// Compiles the final schema once. Rule identity/counting stays within each
/// original source while declaration slots share the existing total limit.
StateCompositionInspection inspectStateComposition(
  Object? state, {
  Object? version = 1,
  required List<StateCompositionRuleSource> sources,
  required bool compositionEligible,
  bool validateValue = false,
  bool valueExists = false,
  Object? value,
  Object? secretSlots,
  Object? secretVersion = 1,
}) {
  final schemaState = state is Map<String, Object?> ? (<String, Object?>{...state}..remove('rules')) : state;
  final definition = StateDefinition.parse(schemaState, version: version);
  final ruleIssues = <Map<String, Object?>>[];
  final rules = <Map<String, Object?>>[];
  if (definition.executable) {
    var remaining = 256;
    for (final source in sources) {
      final carrier = StateDefinition._uncompiled(source.state);
      // _compileRules still scans this source's complete original list for
      // duplicate IDs before visiting the admitted prefix.
      _compileRules(carrier, slotLimit: remaining);
      for (final issue in carrier.issues) {
        ruleIssues.add({
          'diagnostic': issue,
          'source': source.source,
          'sourcePath': '${source.sourcePath}${issue['path']! as String}',
        });
      }
      final declarations = source.state['rules'];
      if (declarations is List<Object?>) {
        if (remaining < 256 && declarations.length > remaining) {
          ruleIssues.add({
            'diagnostic': _issue(
              'rules_composition_limit',
              '/rules',
              'Rules beyond the shared 256 declaration slots are not compiled.',
            ),
            'source': source.source,
            'sourcePath': '${source.sourcePath}/rules',
          });
        }
        remaining = declarations.length >= remaining ? 0 : remaining - declarations.length;
      }
      for (final rule in carrier._rules) {
        rules.add({
          'source': source.source,
          'sourcePath': '${source.sourcePath}/rules/${rule.index}',
          'index': rule.index,
          'key': rule.key,
          'once': rule.once,
        });
      }
    }
  }
  final validated = validateValue && compositionEligible && definition.executable;
  final valueIssues = validated ? definition.validate(value, valueExists: valueExists) : <Map<String, Object?>>[];
  final secret = SecretDefinition.parse(secretSlots, state: definition, version: secretVersion);
  return StateCompositionInspection(
    executable: definition.executable,
    definitionIssues: definition.issues,
    ruleIssues: ruleIssues,
    rules: rules,
    validated: validated,
    valueIssues: valueIssues,
    secretExecutable: secret.executable,
    secretIssues: secret.issues,
  );
}
