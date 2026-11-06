// 她的声音: whether she speaks, and in whose voice. The phone's own; an
// OpenAI-compatible speech API; or any HTTP API the person describes
// (companion_voice_source.dart). Fields save as they are edited; 试听 says a
// line with what is filled in now.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../companion/companion_voice.dart';
import '../../companion/companion_voice_source.dart';
import '../../l10n/l10n.dart';
import '../providers/provider_widgets.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/semantic_colors.dart';

class CompanionVoicePage extends ConsumerStatefulWidget {
  const CompanionVoicePage({super.key});

  @override
  ConsumerState<CompanionVoicePage> createState() => _CompanionVoicePageState();
}

class _CompanionVoicePageState extends ConsumerState<CompanionVoicePage> {
  final _base = TextEditingController();
  final _key = TextEditingController();
  final _model = TextEditingController();
  final _voice = TextEditingController();
  final _url = TextEditingController();
  final _headers = TextEditingController();
  final _body = TextEditingController();
  final _field = TextEditingController();
  bool _filled = false;

  // Held from the start: edits still waiting are saved as the page closes,
  // when it can no longer read providers.
  late final CompanionVoiceSettingsController _store = ref.read(companionVoiceSettingsProvider.notifier);
  CompanionVoiceSettings? _seen;

  @override
  void initState() {
    super.initState();
    _store; // Bind now, not on first use.
  }

  bool _obscure = true;
  Timer? _saveTimer;

  /// 试听: null idle, '' requesting, 'ok', or why it failed.
  String? _preview;

  List<TextEditingController> get _all => [_base, _key, _model, _voice, _url, _headers, _body, _field];

  @override
  void dispose() {
    _saveTimer?.cancel();
    _flush();
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  void _fill(CompanionVoiceSettings s) {
    if (_filled) return;
    _filled = true;
    _base.text = s.openaiBase;
    _key.text = s.openaiKey;
    _model.text = s.openaiModel;
    _voice.text = s.openaiVoice;
    _url.text = s.customUrl;
    _headers.text = s.customHeaders;
    _body.text = s.customBody;
    _field.text = s.customField;
  }

  CompanionVoiceSettings _fromFields(CompanionVoiceSettings s) => s.copyWith(
    openaiBase: _base.text.trim(),
    openaiKey: _key.text.trim(),
    openaiModel: _model.text.trim(),
    openaiVoice: _voice.text.trim(),
    customUrl: _url.text.trim(),
    customHeaders: _headers.text,
    customBody: _body.text,
    customField: _field.text.trim(),
  );

  void _edited() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), _flush);
    if (_preview != null && _preview != '') setState(() => _preview = null);
  }

  void _flush() {
    _saveTimer?.cancel();
    final s = _seen;
    if (s == null || !_filled) return;
    final next = _fromFields(s);
    if (next.plain().toString() != s.plain().toString() ||
        next.openaiKey != s.openaiKey ||
        next.customHeaders != s.customHeaders) {
      _seen = next;
      unawaited(_store.update(next));
    }
  }

  Future<void> _set(CompanionVoiceSettings next) async {
    final merged = _fromFields(next);
    _seen = merged;
    await _store.update(merged);
  }

  Future<void> _turn(CompanionVoiceSettings s, bool on) async {
    if (!on) {
      ref.read(companionSpeakerProvider).stop();
      await _set(s.copyWith(on: false));
      return;
    }
    // On only with a voice that can be heard: she says hello in it.
    final next = _fromFields(s).copyWith(on: true);
    setState(() => _preview = '');
    final why = await ref.read(companionSpeakerProvider).preview(next, context.l10n.companionVoiceHello);
    if (!mounted) return;
    setState(() => _preview = why ?? 'ok');
    if (why == null) await _set(next);
  }

  Future<void> _try(CompanionVoiceSettings s) async {
    _flush();
    setState(() => _preview = '');
    final why = await ref.read(companionSpeakerProvider).preview(_fromFields(s), context.l10n.companionVoiceHello);
    if (mounted) setState(() => _preview = why ?? 'ok');
  }

  String _why(String reason) {
    final l10n = context.l10n;
    return switch (reason) {
      'no-phone-voice' => l10n.companionVoiceUnavailable,
      'not-set-up' => l10n.companionVoiceNotSetUp,
      _ => l10n.companionVoicePreviewFailed(reason),
    };
  }

  Widget _text(
    TextEditingController controller, {
    String? hint,
    bool url = false,
    bool secret = false,
    int lines = 1,
  }) => TextField(
    controller: controller,
    onChanged: (_) => _edited(),
    onEditingComplete: _flush,
    minLines: lines,
    maxLines: secret ? 1 : (lines == 1 ? 1 : lines + 3),
    obscureText: secret && _obscure,
    obscuringCharacter: '•',
    autocorrect: false,
    enableSuggestions: !secret,
    enableIMEPersonalizedLearning: !secret,
    keyboardType: secret
        ? TextInputType.visiblePassword
        : url
        ? TextInputType.url
        : (lines > 1 ? TextInputType.multiline : TextInputType.text),
    style: lines > 1 ? const TextStyle(fontFamily: 'monospace', fontSize: 13) : null,
    decoration: InputDecoration(
      hintText: hint,
      suffixIcon: secret
          ? IconButton(
              tooltip: _obscure ? context.l10n.engineFieldShow : context.l10n.commonHide,
              icon: Icon(_obscure ? AppIcons.showSecret : AppIcons.hideSecret, size: 20),
              onPressed: () => setState(() => _obscure = !_obscure),
            )
          : null,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final s = _seen = ref.watch(companionVoiceSettingsProvider);
    if (s == null) return AppPage.list(title: l10n.companionMenuVoice, children: const []);
    _fill(s);
    final busy = _preview == '';
    final status = switch (_preview) {
      null => null,
      '' => Text(l10n.companionVoicePreviewing, style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary)),
      'ok' => Text(
        l10n.companionVoicePreviewOk,
        style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
      ),
      final reason => Text(_why(reason), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
    };

    return AppPage.list(
      title: l10n.companionMenuVoice,
      children: [
        SettingsSection(
          footer: s.on ? null : Text(l10n.companionVoiceOffHint),
          children: [
            SettingsSwitchTile(
              icon: AppIcons.companionVoice,
              tinted: false,
              title: l10n.companionVoiceOn,
              value: s.on,
              onChanged: busy ? null : (on) => unawaited(_turn(s, on)),
            ),
          ],
        ),
        SettingsSection(
          title: l10n.companionVoiceSource,
          children: [
            for (final (source, title, hint) in [
              (CompanionVoiceSource.system, l10n.companionVoiceSystem, l10n.companionVoiceSystemHint),
              (CompanionVoiceSource.openai, l10n.companionVoiceOpenai, l10n.companionVoiceOpenaiHint),
              (CompanionVoiceSource.custom, l10n.companionVoiceCustom, l10n.companionVoiceCustomHint),
            ])
              SettingsTile(
                title: title,
                subtitle: hint,
                chevron: false,
                trailing: s.source == source ? const Icon(AppIcons.selected, size: 20) : null,
                onTap: () {
                  setState(() => _preview = null);
                  unawaited(_set(s.copyWith(source: source)));
                },
              ),
          ],
        ),
        if (s.source == CompanionVoiceSource.openai)
          SettingsSection(
            title: l10n.companionVoiceApi,
            footer: Text(l10n.companionVoicePrivacy),
            children: [
              FormFieldGroup(
                children: [
                  FormFieldBlock(
                    label: l10n.companionVoiceBase,
                    helper: l10n.companionVoiceBaseHelper,
                    child: _text(_base, hint: 'https://api.openai.com/v1', url: true),
                  ),
                  FormFieldBlock(
                    label: 'API Key',
                    helper: l10n.companionVoiceKeyHelper,
                    child: _text(_key, hint: 'sk-…', secret: true),
                  ),
                  FormFieldBlock(
                    label: l10n.companionVoiceModel,
                    child: _text(_model, hint: 'gpt-4o-mini-tts'),
                  ),
                  FormFieldBlock(
                    label: l10n.companionVoiceVoice,
                    helper: l10n.companionVoiceVoiceHelper,
                    child: _text(_voice, hint: 'alloy'),
                  ),
                ],
              ),
            ],
          ),
        if (s.source == CompanionVoiceSource.custom)
          SettingsSection(
            title: l10n.companionVoiceRequest,
            footer: Text(l10n.companionVoicePrivacy),
            children: [
              FormFieldGroup(
                children: [
                  FormFieldBlock(
                    label: l10n.companionVoiceUrl,
                    helper: l10n.companionVoiceUrlHelper,
                    child: _text(_url, hint: 'https://tts.example.com/speak', url: true),
                  ),
                  FormFieldBlock(
                    label: l10n.companionVoiceMethod,
                    child: SegmentedPill<bool>(
                      segments: const [PillSegment(true, 'POST'), PillSegment(false, 'GET')],
                      selected: s.customPost,
                      onChanged: (post) => unawaited(_set(s.copyWith(customPost: post))),
                    ),
                  ),
                  FormFieldBlock(
                    label: l10n.companionVoiceHeaders,
                    helper: l10n.companionVoiceHeadersHelper,
                    child: _text(_headers, hint: 'Authorization: Bearer sk-…', lines: 2),
                  ),
                  if (s.customPost)
                    FormFieldBlock(
                      label: l10n.companionVoiceBody,
                      helper: l10n.companionVoiceBodyHelper,
                      child: _text(_body, hint: '{"text": "{text}"}', lines: 3),
                    ),
                  FormFieldBlock(
                    label: l10n.companionVoiceField,
                    helper: l10n.companionVoiceFieldHelper,
                    child: _text(_field, hint: 'data.audio'),
                  ),
                ],
              ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset + 8, 4, SettingsMetrics.inset + 8, 24),
          child: Row(
            children: [
              FilledButton.tonal(
                onPressed: busy ? null : () => unawaited(_try(s)),
                child: Text(l10n.companionVoicePreview),
              ),
              const SizedBox(width: 12),
              if (status != null) Expanded(child: status),
            ],
          ),
        ),
      ],
    );
  }
}
