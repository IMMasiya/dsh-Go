// 按包名 / Git 地址安装（票 #24）：一个表单页，先检查再安装。
//
// 安装不直接调 `installBundle`：`pluginManager/inspect` 先说出这是什么
// （名称 / 版本 / 来源），再把结果交给现有安装队列，进度、取消、断线恢复
// 与市场安装共用一套。

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/connection_state.dart';
import '../../../state/plugins_state.dart';
import '../../shell/page_frame.dart';
import 'plugin_spec.dart';

class PluginInstallPage extends ConsumerStatefulWidget {
  const PluginInstallPage({super.key, required this.canInstall, required this.safeMode, this.initialSpec});

  /// This host accepts installs (a remote relay may not).
  final bool canInstall;

  /// The engine runs a repair profile: no installs at all.
  final bool safeMode;

  /// Prefilled from the market's "not found?" row.
  final String? initialSpec;

  @override
  ConsumerState<PluginInstallPage> createState() => _PluginInstallPageState();
}

class _PluginInstallPageState extends ConsumerState<PluginInstallPage> {
  late final TextEditingController _input = TextEditingController(text: widget.initialSpec ?? '');
  bool _busy = false;
  PluginInspection? _inspection;
  String? _problem;
  String? _installing;

  bool get _closed => !widget.canInstall || widget.safeMode;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _inspect() async {
    final conn = ref.read(activeConnectionProvider).value;
    if (conn == null || _busy) return;
    final kind = classifyPluginSpec(_input.text);
    setState(() {
      _inspection = null;
      _problem = null;
      _installing = null;
      if (kind == PluginSpecKind.invalid) _problem = context.l10n.pluginsInstallSpecBadSpec;
    });
    if (kind == PluginSpecKind.invalid) return;
    setState(() => _busy = true);
    try {
      final inspection = await conn.client.inspectPlugin(_input.text.trim());
      if (!mounted) return;
      setState(() => _inspection = inspection);
    } catch (e) {
      if (!mounted) return;
      setState(() => _problem = describePluginError(e).message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _install(PluginInspectionAccepted inspection) async {
    final request = customInstallRequest(inspection, _input.text);
    if (request == null) {
      setState(() => _problem = context.l10n.pluginsInstallSpecUnknown);
      return;
    }
    setState(() => _installing = request.name);
    await ref.read(pluginInstallsProvider.notifier).install(request);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final inspection = _inspection;
    final job = _installing == null ? null : ref.watch(pluginInstallsProvider.select((jobs) => jobs[_installing]));
    return AppPage(
      title: l10n.pluginsInstallBySpec,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_closed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      widget.safeMode ? l10n.hubPluginSafeModeInstall : l10n.statePluginRemoteForbidden,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                    ),
                  ),
                TextField(
                  controller: _input,
                  enabled: !_closed,
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(hintText: l10n.pluginsInstallSpecHint, border: const OutlineInputBorder()),
                  onSubmitted: (_) => unawaited(_inspect()),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.pluginsInstallSpecTypes,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    FilledButton(
                      onPressed: _closed || _busy ? null : () => unawaited(_inspect()),
                      child: Text(l10n.pluginsInstallSpecCheck),
                    ),
                    const SizedBox(width: 8),
                    if (inspection is PluginInspectionAccepted && _installing == null)
                      FilledButton.tonal(
                        onPressed: () => unawaited(_install(inspection)),
                        child: Text(l10n.pluginsInstallSpecInstall),
                      ),
                  ],
                ),
                if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
                if (_problem case final problem?)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(problem, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
                  ),
                if (inspection case PluginInspectionRefused(:final problem))
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _problemText(l10n, problem),
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
                    ),
                  ),
                if (inspection is PluginInspectionAccepted) _AcceptedCard(inspection: inspection),
                if (job != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            job.failure?.title ??
                                job.failure?.message ??
                                (job.phase == PluginInstallPhase.succeeded
                                    ? l10n.pluginsInstallSpecInstalled
                                    : job.phase.name),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: job.failure != null ? theme.colorScheme.error : null,
                            ),
                          ),
                        ),
                        if (job.isActive)
                          TextButton(
                            onPressed: () => unawaited(ref.read(pluginInstallsProvider.notifier).cancel(job.request.name)),
                            child: Text(l10n.commonCancel),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _problemText(L10n l10n, String problem) => switch (problem) {
    'invalid-spec' || 'not-a-package' => l10n.pluginsInstallSpecBadSpec,
    'already-installed' => l10n.pluginsInstallSpecInstalled,
    'not-found' => l10n.pluginsInstallSpecNotFound,
    'not-a-bundle' => l10n.pluginsInstallSpecNotBundle,
    'network' => l10n.pluginsInstallSpecNetwork,
    _ => l10n.pluginsInstallSpecUnknown,
  };
}

/// What the Host said the spec is.
class _AcceptedCard extends StatelessWidget {
  const _AcceptedCard({required this.inspection});

  final PluginInspectionAccepted inspection;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final rows = <(String, String)>[
      if (inspection.name case final name?) (l10n.pluginsInstallSpecName, name),
      if (inspection.version case final version?) (l10n.pluginsInstallSpecVersion, version),
      (l10n.pluginsInstallSpecSource, switch (inspection.kind) {
        'git' => l10n.pluginsInstallSpecKindGit,
        'tarball' => l10n.pluginsInstallSpecKindTarball,
        _ => l10n.pluginsInstallSpecKindNpm,
      }),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 64,
                    child: Text(
                      label,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                  Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
                ],
              ),
            ),
          if (inspection.description case final d? when d.isNotEmpty)
            Text(d, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
