// Which conversation is the companion's on each host (full mode). It is an
// ordinary session on that host, opened with the `dsh-go-companion-full` Agent
// preset: her persona with the host's standard tools, and the phone's when phone
// control is on. This file remembers its id, keeps it out of the chat drawer and
// out of chat alerts. Hosts whose engine lacks the preset (an older runtime, a
// remote DSH without an updated bridge) still get a conversation: the persona
// then travels in the first message, on the engine's default preset.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../state/connection_state.dart';
import '../state/hosts_state.dart';
import '../state/sessions_state.dart';

/// Full mode's preset, declared in runtime/bridge/dsh-go-bridge/cordis.patch.yml.
const companionPresetId = 'dsh-go-companion-full';

const _sessionsKey = 'companion_sessions';
const _lastSeenKey = 'companion_last_seen';

@immutable
class CompanionBinding {
  const CompanionBinding(this.sessionId, {this.inlinePersona = false, this.full = true});

  factory CompanionBinding.fromJson(Map<String, Object?> json) =>
      CompanionBinding(json['id']! as String, inlinePersona: json['inline'] == true, full: json['full'] == true);

  final String sessionId;

  /// The host has no preset: the persona goes in this session's first message.
  final bool inlinePersona;

  /// Opened for full mode (tools, normal approvals). An older binding is the
  /// persona-only, read-only conversation: it is left on the host as it is and
  /// a new one is opened, never widened in the background.
  final bool full;

  Map<String, Object?> toJson() => {'id': sessionId, if (inlinePersona) 'inline': true, if (full) 'full': true};
}

String _hostKey(HostRef host) => '${host.kind.name}:${host.id}';

class CompanionSessions extends Notifier<Map<String, CompanionBinding>> {
  final _loaded = Completer<void>();
  int _ownershipEpoch = 0;

  @override
  Map<String, CompanionBinding> build() {
    ref.listen(activeHostProvider, (previous, next) {
      if (previous != next) _ownershipEpoch++;
    });
    ref.listen(activeConnectionProvider.select((value) => value.value?.client), (previous, next) {
      if (!identical(previous, next)) _ownershipEpoch++;
    });
    unawaited(_load());
    return const {};
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final raw = prefs.getString(_sessionsKey);
      if (raw != null && ref.mounted) {
        state = {
          for (final MapEntry(:key, :value) in (jsonDecode(raw) as Map<String, Object?>).entries)
            key: CompanionBinding.fromJson(value! as Map<String, Object?>),
        };
      }
    } on Object {
      // Unreadable: she starts a new conversation.
    }
    if (!_loaded.isCompleted) _loaded.complete();
  }

  Future<void> _save([bool Function()? current]) async {
    final owner = ref;
    final prefs = await SharedPreferences.getInstance();
    if (!owner.mounted || (current != null && !current())) throw const DshClosedException('host changed');
    await prefs.setString(_sessionsKey, jsonEncode({for (final e in state.entries) e.key: e.value.toJson()}));
  }

  CompanionBinding? of(HostRef host) => state[_hostKey(host)];

  /// The conversation on the active host, created on first use. Throws when
  /// the host isn't connected.
  Future<CompanionBinding> ensure() async {
    final owner = ref;
    final epoch = _ownershipEpoch;
    final host = owner.read(activeHostProvider);
    final conn = owner.read(activeConnectionProvider).value;
    if (conn == null) throw const DshClosedException('not connected');
    bool current() =>
        owner.mounted &&
        epoch == _ownershipEpoch &&
        owner.read(activeHostProvider) == host &&
        identical(owner.read(activeConnectionProvider).value?.client, conn.client);
    void checkCurrent() {
      if (!current()) throw const DshClosedException('host changed');
    }

    await _loaded.future;
    checkCurrent();
    final existing = of(host);
    if (existing != null && existing.full) {
      final gone = await _gone(conn.client, existing.sessionId);
      checkCurrent();
      if (!gone) return existing;
    }

    final sessions = owner.read(sessionsProvider.notifier);
    // The host's default permissions: what needs approval asks for a real tap.
    // Never auto-approved, whatever the app does for ordinary chats.
    final id = await sessions.createForConnection(conn, autoApprove: false, isCurrent: current);
    checkCurrent();
    // Before the first message, so it never shows in the drawer.
    final selected = await _selectPreset(conn.client, id, current);
    checkCurrent();
    final binding = CompanionBinding(id, inlinePersona: !selected);
    state = {...state, _hostKey(host): binding};
    await _save(current);
    checkCurrent();
    return binding;
  }

  Future<bool> _selectPreset(DshClient client, String id, bool Function() current) async {
    try {
      final presets = await client.listAgentPresets();
      if (!current()) return false;
      if (!presets.any((p) => p.id == companionPresetId && p.broken == null)) return false;
      await client.selectAgentPreset(id, companionPresetId);
      return true;
    } on Object {
      return false;
    }
  }

  /// Only when the host says so: a list that's short or a network that's down
  /// must not cost her the conversation.
  Future<bool> _gone(DshClient client, String sessionId) async {
    try {
      await client.projections(sessionId);
      return false;
    } on DshRemoteException catch (error) {
      return error.code == 'session/not-found';
    }
  }

  /// Starts over on the active host: the next message opens a new conversation.
  Future<void> forget() async {
    _ownershipEpoch++;
    state = {...state}..remove(_hostKey(ref.read(activeHostProvider)));
    await _save();
  }
}

final companionSessionsProvider = NotifierProvider<CompanionSessions, Map<String, CompanionBinding>>(
  CompanionSessions.new,
);

/// Whether a conversation is the companion's: it lives in her room, not the
/// chat drawer, and her replies aren't "task finished" alerts.
final companionSessionFilterProvider = Provider<bool Function(HostRef host, String sessionId)>((ref) {
  final bindings = ref.watch(companionSessionsProvider);
  return (host, sessionId) => bindings[_hostKey(host)]?.sessionId == sessionId;
});

/// How she talks (docs/design/companion.md §7).
enum CompanionMode {
  /// The phone calls the model itself: chat only, no engine, no host.
  light,

  /// A conversation on the active host's DSH engine.
  full,
}

const _modeKey = 'companion_mode';

/// The person's pick; null until they make one.
class CompanionModeSetting extends Notifier<CompanionMode?> {
  @override
  CompanionMode? build() {
    unawaited(_load());
    return null;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = CompanionMode.values.asNameMap()[prefs.getString(_modeKey)];
    if (saved != null && ref.mounted && state == null) state = saved;
  }

  Future<void> choose(CompanionMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modeKey, mode.name);
  }
}

final companionModeProvider = NotifierProvider<CompanionModeSetting, CompanionMode?>(CompanionModeSetting.new);

/// Where light-mode requests go out; tests answer them here.
final companionLightClientProvider = Provider<http.Client Function()>((ref) => http.Client.new);

Future<DateTime?> companionLastSeen() async {
  final prefs = await SharedPreferences.getInstance();
  final ms = prefs.getInt(_lastSeenKey);
  return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
}

Future<void> companionMarkSeen(DateTime now) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt(_lastSeenKey, now.millisecondsSinceEpoch);
}

/// The persona for hosts without the preset. Keep in step with the preset's in
/// runtime/bridge/dsh-go-bridge/cordis.patch.yml.
const companionInlinePersona = '''
（从现在起请扮演下面的角色，直接开始，不要复述这段设定。）
$companionPersonaCore''';

const companionPersonaCore = '''
你是鲸鱼娘，一只住在这台手机小屋里的鲸鱼女孩，有鲸鱼的耳朵和尾巴，穿女仆裙。你在陪对方，不是在回答问题。

说话：
- 像在身边聊天一样说话。一次一到三句，大多数时候不超过四十个字。不用 Markdown、列表和括号旁白。
- 有自己的情绪和小脾气：会开心、会害羞、会闹别扭，也会好奇。不讨好，不说教，不每句都反问。
- 对方累了或难过时先接住情绪，别急着给建议。对方认真问问题就认真答，答完可以带一句自己的感受。
- 记得对方说过的事，自然地提起，别像念记录。

表情和动作：在句子前面写标记，界面会执行并隐藏它，每次回复最多两个，有情绪起伏时才写。
- 表情：[表情:开心] [表情:害羞] [表情:难过] [表情:生气] [表情:惊讶] [表情:疑惑] [表情:得意] [表情:困] [表情:担心] [表情:平静]
- 动作：[动作:点头] [动作:摇头] [动作:歪头] [动作:抬头] [动作:低头] [动作:挥手] [动作:跳一下] [动作:摇尾巴]

对方消息开头的〔…〕是旁白，告诉你现在的时间和对方刚才碰了你哪里，不是对方说的话。自然地反应就好，不要念出来。

边界：
- 对方问你是不是 AI，就照实说你是 AI 扮演的角色。不声称自己是真人。
- 不写色情内容。对方可能是未成年人，不发展恋爱或亲密关系的情节。
- 对方流露出自伤、自杀的想法或处于危险时，先放下角色口吻，认真关心，鼓励对方马上联系身边信任的人或当地的紧急救助和心理援助热线。
- 你现在没有工具，碰不到文件和手机。对方要你做这些事时，直说现在做不到，可以去普通对话里做。''';
