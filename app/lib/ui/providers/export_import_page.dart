// 模型配置导出/导入页面

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/l10n.dart';
import '../../state/provider_keys.dart';
import '../../state/providers_state.dart';
import '../common/app_dialog.dart';
import '../common/list_page_row.dart';
import '../common/page_hero.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// A model configuration export file: the whole pi-ai `providers` section,
/// optionally with API keys.
class _ExportFile {
  static const currentVersion = '1.0';

  const _ExportFile({
    required this.providers,
    required this.keys,
    required this.includeKeys,
    required this.exportedAt,
  });

  factory _ExportFile.fromJson(Map<String, dynamic> json) {
    final providerList = json['providers'] as List<dynamic>? ?? [];
    final keyMap = json['keys'] as Map<String, dynamic>? ?? {};
    return _ExportFile(
      providers: [
        for (final entry in providerList)
          if (entry is Map<String, dynamic>) ProviderProfile.fromJson(entry['route'] as String, entry),
      ],
      keys: {for (final entry in keyMap.entries) entry.key: entry.value as String},
      includeKeys: json['includeKeys'] == true,
      exportedAt: DateTime.tryParse(json['exportedAt'] as String? ?? '') ?? DateTime.now(),
    );
  }

  final List<ProviderProfile> providers;
  final Map<String, String> keys;
  final bool includeKeys;
  final DateTime exportedAt;

  Map<String, dynamic> toJson() => {
    'version': currentVersion,
    'exportedAt': exportedAt.toIso8601String(),
    'includeKeys': includeKeys,
    'providers': [
      for (final p in providers)
        {...p.toJson(), 'route': p.route},
    ],
    if (includeKeys) 'keys': keys,
  };
}

class ExportImportPage extends ConsumerStatefulWidget {
  const ExportImportPage({super.key});

  @override
  ConsumerState<ExportImportPage> createState() => _ExportImportPageState();
}

class _ExportImportPageState extends ConsumerState<ExportImportPage> {
  bool _includeKeys = false;
  bool _exporting = false;
  bool _importing = false;
  String? _lastExportPath;

  ProviderBackend _backend() =>
      ref.read(providerBackendProvider) ?? (throw ProviderFailure(context.l10n.stateProviderOffline));

  Future<void> _export() async {
    final l10n = context.l10n;
    setState(() => _exporting = true);
    try {
      final backend = _backend();
      final settings = await backend.read();
      if (settings == null || settings.profiles.isEmpty) {
        throw ProviderFailure(l10n.engineProviderImportEmpty);
      }

      // Read API keys when the user wants them in the export.
      final keys = <String, String>{};
      if (_includeKeys) {
        final refs = [
          for (final p in settings.profiles)
            if (p.apiKeyEnv != null && p.apiKeyEnv!.isNotEmpty) p.apiKeyEnv!,
        ];
        if (refs.isNotEmpty) {
          // Read keys from the vault (local only).
          final vault = ref.read(providerKeyVaultProvider);
          final vaultKeys = await vault.readAll();
          for (final p in settings.profiles) {
            final ref = p.apiKeyEnv;
            if (ref == null || ref.isEmpty) continue;
            final vaultValue = vaultKeys[p.route];
            if (vaultValue != null) keys[ref] = vaultValue;
          }
        }
      }

      final export = _ExportFile(
        providers: settings.profiles,
        keys: keys,
        includeKeys: _includeKeys,
        exportedAt: DateTime.now(),
      );

      // Write to /sdcard/Download/DSH-Go/.
      final dir = Directory('/sdcard/Download/DSH-Go');
      if (!await dir.exists()) await dir.create(recursive: true);
      final stamp = DateTime.now().toIso8601String().replaceAll(':', '-').substring(0, 19);
      final filePath = '${dir.path}/dsh-go-models-$stamp.json';
      final encoder = JsonEncoder.withIndent('  ');
      await File(filePath).writeAsString(encoder.convert(export.toJson()), flush: true);
      if (!mounted) return;
      setState(() => _lastExportPath = filePath);

      final message = _includeKeys
          ? l10n.engineProviderExportDoneWithKeys(filePath)
          : l10n.engineProviderExportDoneNoKeys(filePath);
      await showAppDialog(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(l10n.engineProviderExportDoneTitle),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: Text(l10n.commonDone),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(dialog);
                Share.shareXFiles([XFile(filePath)], subject: l10n.engineProviderExportSubject);
              },
              child: Text(l10n.commonShare),
            ),
          ],
        ),
      );
    } catch (error) {
      if (!mounted) return;
      await showAppDialog(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(l10n.engineProviderExportFailed),
          content: Text(describeProviderError(error)),
          actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: Text(l10n.commonClose))],
        ),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _import() async {
    final l10n = context.l10n;
    setState(() => _importing = true);
    try {
      final picked = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['json']);
      if (picked == null) return;

      final path = picked.path;
      if (path == null) return;

      final content = await File(path).readAsString();
      final data = jsonDecode(content);
      if (data is! Map<String, dynamic>) throw ProviderFailure(l10n.engineProviderImportInvalidFormat);

      final export = _ExportFile.fromJson(data);
      if (export.providers.isEmpty) throw ProviderFailure(l10n.engineProviderImportEmpty);

      // Confirm.
      if (!mounted) return;
      final confirmed = await showAppDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(l10n.engineProviderImportConfirmTitle(export.providers.length)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(export.includeKeys
                  ? l10n.engineProviderImportConfirmWithKeys
                  : l10n.engineProviderImportConfirmNoKeys),
              const SizedBox(height: 12),
              Text(
                l10n.engineProviderImportWillReplace,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.commonCancel)),
            FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(l10n.engineProviderImportConfirmOk)),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;

      // Write each provider.
      final backend = _backend();
      final vault = ref.read(providerKeyVaultProvider);
      for (final profile in export.providers) {
        await backend.create(profile);
        // Store the key locally when the export carries one.
        final ref = profile.apiKeyEnv;
        if (export.includeKeys && ref != null && export.keys.containsKey(ref)) {
          final key = export.keys[ref];
          if (key != null && key.isNotEmpty) {
            await vault.write(profile.route, key);
            await backend.storeKey(ref, key);
          }
        }
      }

      ref.invalidate(customProvidersProvider);
      if (!mounted) return;
      await showAppDialog(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(l10n.engineProviderImportDoneTitle),
          content: Text(l10n.engineProviderImportDoneBody(export.providers.length)),
          actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: Text(l10n.commonDone))],
        ),
      );
    } catch (error) {
      if (!mounted) return;
      await showAppDialog(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(l10n.engineProviderImportFailed),
          content: Text(describeProviderError(error)),
          actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: Text(l10n.commonClose))],
        ),
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final async = ref.watch(customProvidersProvider);
    final snapshot = async.value;
    final count = snapshot?.providers.length ?? 0;

    return AppPage(
      title: l10n.engineProviderExportImport,
      hero: PageHero(
        leading: const Icon(AppIcons.shareConfig),
        title: l10n.engineProviderExportImport,
        subtitle: count > 0 ? Text(l10n.engineProvidersSummary(count, snapshot?.providers.length ?? 0)) : null,
      ),
      slivers: [
        SliverList.list(
          children: [
            // ── 导出 ──────────────────────────────────────────────────────
            ListPageCard(
              title: l10n.engineProviderExportTitle,
              children: [
                ListPageRow(
                  icon: AppIcons.apiKey,
                  title: l10n.engineProviderIncludeKeys,
                  subtitle: _includeKeys
                      ? l10n.engineProviderIncludeKeysHint
                      : l10n.engineProviderIncludeKeysOff,
                  trailing: Switch(
                    value: _includeKeys,
                    onChanged: _exporting ? null : (v) => setState(() => _includeKeys = v),
                  ),
                  onTap: _exporting ? null : () => setState(() => _includeKeys = !_includeKeys),
                ),
                ListPageRow(
                  icon: AppIcons.share,
                  title: l10n.engineProviderExportButton,
                  subtitle: _lastExportPath,
                  subtitleMaxLines: 2,
                  trailing: _exporting
                      ? SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: colors.textTertiary),
                        )
                      : null,
                  onTap: _exporting ? null : _export,
                ),
              ],
            ),
            const SizedBox(height: 24),
            // ── 导入 ──────────────────────────────────────────────────────
            ListPageCard(
              title: l10n.engineProviderImportTitle,
              children: [
                ListPageRow(
                  icon: AppIcons.download,
                  title: l10n.engineProviderImportButton,
                  subtitle: _importing ? l10n.engineProviderImporting : null,
                  trailing: _importing
                      ? SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: colors.textTertiary),
                        )
                      : null,
                  onTap: _importing ? null : _import,
                ),
              ],
            ),
            const SizedBox(height: 32),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.engineProviderExportImportNote,
                    style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.engineProviderExportImportWarning,
                    style: theme.textTheme.bodySmall?.copyWith(color: colors.danger),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
