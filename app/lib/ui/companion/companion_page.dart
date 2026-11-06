// 伙伴小屋: a whole page for the companion (docs/design/companion.md). She fills
// the screen in a WebView; on top of it, in Flutter, her words and a small input.
// Touches are answered on the spot without a model call. Talking goes, in full
// mode, through an ordinary session on the active host (companion_state.dart);
// in light mode, straight from the phone to the model (companion_light.dart).

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dsh_client/dsh_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../companion/companion_light.dart';
import '../../companion/companion_pack.dart';
import '../../companion/companion_reply.dart';
import '../../companion/companion_state.dart';
import '../../l10n/l10n.dart';
import '../../pets/pet_state.dart';
import '../../state/chat_state.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../../state/sessions_state.dart';
import '../../state/settings_state.dart';
import '../../state/voice_model_state.dart';
import '../../state/voice_settings.dart';
import '../../state/voice_state.dart';
import '../chat/voice/voice_controller.dart';
import '../common/app_dialog.dart';
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/surfaces.dart';
import 'companion_chrome.dart';
import 'companion_memory_page.dart';
import 'companion_stage.dart';

const _hintDoneKey = 'companion_touch_hint_done';
const _homeHintDoneKey = 'companion_home_hint_done';

final _sentenceEnd = RegExp(r'[。！？!?…~～]');

enum _Phase { checking, setup, stage, failed }

typedef CompanionStageBuilder = Widget Function(CompanionStageController controller, CompanionStageEvents events);

class CompanionPage extends ConsumerStatefulWidget {
  const CompanionPage({super.key, this.storeOverride, this.stageBuilder, this.stageController});

  /// Tests point this at a temporary folder.
  final CompanionPackStore? storeOverride;

  /// Tests have no WebView.
  final CompanionStageBuilder? stageBuilder;
  final CompanionStageController? stageController;

  @override
  ConsumerState<CompanionPage> createState() => _CompanionPageState();
}

class _CompanionPageState extends ConsumerState<CompanionPage> {
  late final _stage = widget.stageController ?? CompanionStageController();
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _random = Random();
  late final VoiceInputController _voice;

  CompanionPackStore? _store;
  CompanionCharacter _character = const CompanionCharacter();
  _Phase _phase = _Phase.checking;
  String? _failure;
  bool _stageReady = false;
  bool _installing = false;
  String? _installError;
  bool _showTouchHint = false;

  /// After the first touch: her shell, bubble and cushion can be tapped too.
  bool _showHomeHint = false;
  bool _homeHintDone = true;

  // The conversation.
  String? _sessionId;
  ProviderSubscription<ChatState>? _chat;
  late HostRef _bindingHost;
  DshClient? _bindingClient;
  int _bindingEpoch = 0;

  /// Light or full when the page last bound (see _bindingChanged).
  late bool _boundLight;
  bool _sending = false;
  bool _running = false;
  bool _needsAttention = false;
  bool _asleep = false;

  /// What she's doing in her corner (the stage's word for it).
  String _home = 'idle';
  String? _baselineUser;
  bool _baselineSet = false;
  int _marksHandled = 0;
  int _wordsSpoken = 0;
  final List<String> _notes = [];

  // Light mode: her conversation on this phone, and the reply on its way.
  CompanionLightHistory? _lightHistory;
  StreamSubscription<String>? _lightReply;
  http.Client? _lightClient;
  String _lightTurn = '';
  String _lightText = '';
  String _lightAsked = '';
  int _lightTurns = 0;

  // Her state on the Host (null: this host can't keep it).
  CompanionSnapshot? _vitals;
  DshClient? _vitalsClient;
  Future<void> _vitalsQueue = Future.value();

  // What's on screen.
  String? _bubble;
  bool _bubbleIsError = false;
  String? _myLine;
  String? _lastLine;
  Timer? _bubbleTimer;
  Timer? _settleTimer;
  Timer? _objectTimer;

  @override
  void initState() {
    super.initState();
    _bindingHost = ref.read(activeHostProvider);
    _bindingClient = ref.read(activeConnectionProvider).value?.client;
    _boundLight = _light;
    _voice = VoiceInputController(
      input: _input,
      bridge: ref.read(voiceBridgeProvider),
      mode: () => ref.read(voiceSettingsProvider.notifier).ready(),
      modelReady: () =>
          mounted &&
          (ref.read(activeConnectionProvider).value?.isLocal ?? false) &&
          ref.read(voiceModelProvider).status == VoiceModelStatus.ready,
      client: () => mounted ? ref.read(activeConnectionProvider).value?.client : null,
      onRecognized: () {
        final current = _currentRoom();
        scheduleMicrotask(() {
          if (current() && _input.text.trim().isNotEmpty) unawaited(_send());
        });
      },
    );
    _voice.addListener(_voiceChanged);
    _focus.addListener(_refreshMood);
    _input.addListener(_inputChanged);
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    final store =
        widget.storeOverride ??
        CompanionPackStore(Directory('${(await getApplicationSupportDirectory()).path}/companion'));
    final installed = await store.installed();
    final character = installed ? await store.character() : const CompanionCharacter();
    if (!mounted) return;
    setState(() {
      _store = store;
      _character = character;
      _phase = installed ? _Phase.stage : _Phase.setup;
    });
  }

  @override
  void dispose() {
    unawaited(companionMarkSeen(DateTime.now()));
    // Leaving: drop the light request without touching the page any more.
    _lightClient?.close();
    unawaited(_lightReply?.cancel().catchError((Object _) {}));
    _chat?.close();
    _bubbleTimer?.cancel();
    _settleTimer?.cancel();
    _objectTimer?.cancel();
    _voice.removeListener(_voiceChanged);
    _voice.dispose();
    _focus.dispose();
    _input.dispose();
    super.dispose();
  }

  // ── Stage events ─────────────────────────────────────────────────────────

  void _onReady() {
    setState(() => _stageReady = true);
    unawaited(_arrive());
    unawaited(_loadHint());
    if (!_light) {
      final binding = ref.read(companionSessionsProvider.notifier).of(ref.read(activeHostProvider));
      if (binding != null) _bind(binding.sessionId);
    }
  }

  /// Light or full (docs/design/companion.md §7). Until the person picks one:
  /// full when a host is connected, light otherwise.
  bool get _light {
    final mode = ref.read(companionModeProvider);
    return mode == CompanionMode.light || (mode == null && ref.read(activeConnectionProvider).value == null);
  }

  Future<void> _loadHint() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final touchDone = prefs.getBool(_hintDoneKey) ?? false;
    _homeHintDone = prefs.getBool(_homeHintDoneKey) ?? false;
    setState(() {
      _showTouchHint = !touchDone;
      _showHomeHint = touchDone && !_homeHintDone;
    });
  }

  /// Her state first (it knows when the person was last here, on any phone),
  /// then the greeting, then this visit.
  Future<void> _arrive({bool greet = true}) async {
    final current = _currentRoom();
    // Light mode asks no host for anything.
    final client = _light ? null : ref.read(activeConnectionProvider).value?.client;
    CompanionSnapshot? snapshot;
    if (client != null) {
      try {
        snapshot = await client.companionSnapshot().timeout(const Duration(seconds: 3));
      } on Object {
        // Not this host, or not now: she's still here, just without memory of it.
      }
    }
    if (!current()) return;
    if (snapshot != null) {
      _vitalsClient = client;
      _applyVitals(snapshot);
    }
    if (greet) await _greet(snapshot?.vitals.lastVisitAt, current);
    if (current() && snapshot != null) _event('visit');
  }

  void _applyVitals(CompanionSnapshot snapshot) {
    _vitals = snapshot;
    final v = snapshot.vitals;
    _stage.command('vitals', {'valence': v.valence, 'energy': v.energy, 'closeness': v.closeness});
    _stage.command('activity', {'name': v.activity, 'remainingMs': snapshot.activityLeft.inMilliseconds});
  }

  /// One event at a time, against the state last read. A conflict reads again;
  /// it never sends the same event twice.
  void _event(String type) {
    final client = _vitalsClient;
    if (client == null) return;
    final current = _currentRoom();
    _vitalsQueue = _vitalsQueue.then((_) async {
      if (!current() || !identical(client, _vitalsClient)) return;
      final read = _vitals;
      if (read == null) return;
      try {
        try {
          final next = await client.companionEvent(read, type);
          if (current()) _applyVitals(next);
        } on DshRemoteException catch (error) {
          if (!current() || (!error.code.endsWith('conflict') && !error.code.endsWith('store-changed'))) return;
          final again = await client.companionSnapshot();
          if (current() && again != null) _applyVitals(again);
        }
      } on Object {
        // The refresh can fail too. Keep the queue usable; never retry a write.
      }
    });
  }

  Future<void> _greet(DateTime? lastVisit, bool Function() current) async {
    final now = DateTime.now();
    final greeting = companionGreeting(now, lastVisit ?? await companionLastSeen());
    unawaited(companionMarkSeen(now));
    if (!mounted || !current()) return;
    final l10n = context.l10n;
    final (line, emotion, action) = switch (greeting) {
      CompanionGreeting.firstTime => (l10n.companionGreetFirst, 'shy', 'wave'),
      CompanionGreeting.morning => (l10n.companionGreetMorning, 'happy', 'wave'),
      CompanionGreeting.noon => (l10n.companionGreetNoon, 'calm', 'tilt'),
      CompanionGreeting.afternoon => (l10n.companionGreetAfternoon, 'calm', 'nodSmall'),
      CompanionGreeting.evening => (l10n.companionGreetEvening, 'happy', 'wave'),
      CompanionGreeting.lateNight => (l10n.companionGreetLate, 'worried', 'tilt'),
      CompanionGreeting.longAbsence => (l10n.companionGreetLong, 'surprised', 'hop'),
      CompanionGreeting.justNow => (l10n.companionGreetBack, 'calm', 'nodSmall'),
    };
    _stage.command('emotion', {'name': emotion, 'hold': 3200});
    _stage.command('action', {'name': action});
    _say(line);
  }

  void _onTouch(String zone, String kind) {
    if (_showTouchHint) {
      setState(() {
        _showTouchHint = false;
        _showHomeHint = !_homeHintDone;
      });
      unawaited(SharedPreferences.getInstance().then((p) => p.setBool(_hintDoneKey, true)));
    }
    final l10n = context.l10n;
    final lines = switch ((zone, kind)) {
      (_, 'tease') => [l10n.companionTease1, l10n.companionTease2, l10n.companionTease3],
      (_, 'pat') => [l10n.companionPat1, l10n.companionPat2, l10n.companionPat3],
      ('head', _) => [l10n.companionTapHead1, l10n.companionTapHead2],
      ('face', _) => [l10n.companionTapFace1, l10n.companionTapFace2, l10n.companionTapFace3],
      ('tail', _) => [l10n.companionTapTail1, l10n.companionTapTail2, l10n.companionTapTail3],
      ('legs', _) => [l10n.companionTapLegs1, l10n.companionTapLegs2],
      _ => [l10n.companionTapBody1, l10n.companionTapBody2, l10n.companionTapBody3],
    };
    if (kind == 'pat') _event('pet');
    _remember(switch ((zone, kind)) {
      (_, 'tease') => '对方刚才连着戳你',
      (_, 'pat') => '对方刚才摸了摸你的头',
      ('tail', _) => '对方刚才碰了你的尾巴',
      ('face', _) => '对方刚才戳了戳你的脸',
      _ => null,
    });
    if (_running || _sending) return; // Her words first.
    final choices = lines.where((l) => l != _lastLine).toList();
    final line = choices[_random.nextInt(choices.length)];
    _lastLine = line;
    _say(line);
  }

  /// How long an activity lasts when this host can't keep it (the bridge's
  /// own durations, docs/design/companion.md).
  static const _localActivity = {
    'snack': Duration(seconds: 45),
    'play': Duration(seconds: 90),
    'rest': Duration(minutes: 15),
  };

  void _onObject(String id) {
    if (!_homeHintDone) {
      _homeHintDone = true;
      setState(() => _showHomeHint = false);
      unawaited(SharedPreferences.getInstance().then((p) => p.setBool(_homeHintDoneKey, true)));
    }
    if (_vitals != null) {
      _event(id);
    } else {
      // No host to keep it: the page's own guess, so her corner still answers.
      _stage.command('activity', {'name': id, 'remainingMs': _localActivity[id]!.inMilliseconds});
    }
    _remember(switch (id) {
      'snack' => '对方刚才给你吃了一块点心',
      'play' => '对方刚才陪你玩了泡泡球',
      _ => '对方刚才让你在海草软垫上歇一会儿',
    });
    if (_running || _sending) return;
    final l10n = context.l10n;
    final lines = switch (id) {
      'snack' => [l10n.companionSnack1, l10n.companionSnack2, l10n.companionSnack3],
      'play' => [l10n.companionPlay1, l10n.companionPlay2, l10n.companionPlay3],
      _ => [l10n.companionRest1, l10n.companionRest2],
    };
    final choices = lines.where((l) => l != _lastLine).toList();
    final line = choices[_random.nextInt(choices.length)];
    _lastLine = line;
    // After the snack has reached her, not before.
    _objectTimer?.cancel();
    _objectTimer = Timer(Duration(milliseconds: id == 'snack' ? 1700 : 900), () {
      if (mounted && !_running && !_sending) _say(line);
    });
  }

  void _onActivity(String name) {
    if (mounted && name != _home) setState(() => _home = name);
  }

  void _onMood(String mood) {
    final asleep = mood == 'sleeping';
    if (asleep != _asleep && mounted) setState(() => _asleep = asleep);
  }

  void _remember(String? note) {
    if (note == null) return;
    _notes
      ..remove(note)
      ..add(note);
    if (_notes.length > 3) _notes.removeAt(0);
  }

  /// A short line without the model.
  void _say(String line) {
    _objectTimer?.cancel();
    _stage.command('say', {'chars': line.length});
    _showBubble(line, hold: Duration(milliseconds: 2400 + line.length * 90));
  }

  void _showBubble(String text, {Duration? hold, bool error = false}) {
    _bubbleTimer?.cancel();
    setState(() {
      _bubble = text;
      _bubbleIsError = error;
    });
    if (hold != null) {
      _bubbleTimer = Timer(hold, () {
        if (mounted) setState(() => _bubble = null);
      });
    }
  }

  // ── Mood ─────────────────────────────────────────────────────────────────

  void _refreshMood() {
    if (_running || _sending) return;
    _stage.command('mood', {'mood': _focus.hasFocus || _voice.active ? 'listening' : 'idle'});
    if (mounted) setState(() {});
  }

  void _voiceChanged() {
    if (!mounted) return;
    setState(() {});
    _refreshMood();
  }

  void _inputChanged() {
    if (mounted) setState(() {});
  }

  CompanionActivity get _activity {
    if (_asleep) return CompanionActivity.sleeping;
    if (_sending || (_running && _bubble == null)) return CompanionActivity.thinking;
    if (_running) return CompanionActivity.speaking;
    if (_focus.hasFocus || _voice.active) return CompanionActivity.listening;
    return switch (_home) {
      'snack' => CompanionActivity.snacking,
      'play' => CompanionActivity.playing,
      'rest' => CompanionActivity.resting,
      _ => CompanionActivity.idle,
    };
  }

  // ── Talking ──────────────────────────────────────────────────────────────

  /// Work belongs to this visit to this host and client, even after A→B→A.
  bool Function() _currentRoom() {
    final epoch = _bindingEpoch;
    // A light conversation belongs to no host: only leaving the page or
    // switching modes (an unbind) ends what it started.
    if (_light) return () => mounted && epoch == _bindingEpoch;
    final host = ref.read(activeHostProvider);
    final client = ref.read(activeConnectionProvider).value?.client;
    return () =>
        mounted &&
        epoch == _bindingEpoch &&
        host == ref.read(activeHostProvider) &&
        identical(client, ref.read(activeConnectionProvider).value?.client);
  }

  void _bindingChanged() {
    final host = ref.read(activeHostProvider);
    final client = ref.read(activeConnectionProvider).value?.client;
    if (host == _bindingHost && identical(client, _bindingClient)) return;
    _bindingHost = host;
    _bindingClient = client;
    // With no mode picked, a host coming or going turns her light or full.
    final light = _light;
    if (light != _boundLight) {
      _modeChanged();
      return;
    }
    // A light conversation isn't on any host: nothing to rebind.
    if (light) return;
    setState(_unbind);
    final binding = ref.read(companionSessionsProvider.notifier).of(host);
    if (binding != null && _stageReady) _bind(binding.sessionId);
    if (_stageReady) unawaited(_arrive());
  }

  void _bind(String sessionId) {
    if (_sessionId == sessionId && _chat != null) return;
    _chat?.close();
    _sessionId = sessionId;
    _baselineSet = false;
    _chat = ref.listenManual(chatProvider(sessionId), (_, next) => _onChat(next), fireImmediately: true);
  }

  void _unbind() {
    _bindingEpoch++;
    if (_voice.active) unawaited(_voice.cancel());
    _bubbleTimer?.cancel();
    _settleTimer?.cancel();
    _objectTimer?.cancel();
    _vitals = null;
    _vitalsClient = null;
    _vitalsQueue = Future.value();
    _chat?.close();
    _chat = null;
    _sessionId = null;
    _sending = false;
    _running = false;
    _needsAttention = false;
    _baselineSet = false;
    _marksHandled = 0;
    _wordsSpoken = 0;
    _notes.clear();
    _bubble = null;
    _myLine = null;
    _home = 'idle';
    _asleep = false;
    _stage.command('quiet');
    _stage.command('activity', {'name': 'idle', 'remainingMs': 0});
    _stage.command('vitals', {'valence': 0.25, 'energy': 0.75, 'closeness': 0});
    _refreshMood();
  }

  /// The words after the latest thing the person said.
  (String?, String) _latestReply(ChatState state) {
    final parts = <String>[];
    String? user;
    for (final item in state.items.reversed) {
      if (item is UserChatItem) {
        user = item.key;
        break;
      }
      if (item is AssistantChatItem && item.text.isNotEmpty) parts.add(item.text);
    }
    return (user, parts.reversed.join('\n'));
  }

  void _onChat(ChatState state) {
    if (!mounted) return;
    final (user, text) = _latestReply(state);
    _onReply(
      user,
      text,
      running: state.running || state.pending.isNotEmpty,
      attention: state.openApproval != null || state.questions.isNotEmpty,
      error: state.error,
      loading: state.loading,
    );
  }

  /// Her reply so far to the person's latest line [user] (any key that changes
  /// with each line), in either mode: marks once each, words into the bubble
  /// and her mouth, the mood while it runs and after.
  void _onReply(
    String? user,
    String text, {
    required bool running,
    bool attention = false,
    String? error,
    bool loading = false,
  }) {
    if (!_baselineSet) {
      // What's already in the conversation has been said; only news moves her.
      if (loading) return;
      _baselineSet = true;
      _baselineUser = user;
      final old = parseCompanionReply(text);
      _marksHandled = old.marks.length;
      _wordsSpoken = old.words.length;
      if (!running) {
        setState(() => _needsAttention = attention);
        return;
      }
    }

    if (user != _baselineUser) {
      _baselineUser = user;
      _marksHandled = 0;
      _wordsSpoken = 0;
    }

    final reply = parseCompanionReply(text, streaming: running);
    for (final mark in reply.marks.skip(_marksHandled)) {
      switch (mark.kind) {
        case CompanionMarkKind.emotion:
          _stage.command('emotion', {'name': mark.name});
        case CompanionMarkKind.action:
          _stage.command('action', {'name': mark.name});
      }
    }
    _marksHandled = max(_marksHandled, reply.marks.length);

    final fresh = reply.words.length - _wordsSpoken;
    if (fresh > 0) {
      _stage.command('say', {'chars': fresh});
      if (_sentenceEnd.hasMatch(reply.words.substring(_wordsSpoken))) _stage.command('beat');
      _wordsSpoken = reply.words.length;
      _myLine = null;
      _showBubble(reply.words);
    }

    if (running) {
      _settleTimer?.cancel();
      _stage.command('mood', {'mood': reply.words.isEmpty ? 'thinking' : 'speaking'});
    } else if (_running) {
      // Her mouth keeps going for a moment after the text is in.
      _settleTimer?.cancel();
      _settleTimer = Timer(Duration(milliseconds: min(4000, 600 + max(fresh, 0) * 90)), _refreshMood);
      _myLine = null;
      if (error != null) {
        _showBubble(error, hold: const Duration(seconds: 6), error: true);
      } else if (reply.words.isNotEmpty) {
        _bubbleTimer?.cancel();
        _bubbleTimer = Timer(Duration(milliseconds: 9000 + reply.words.length * 60), () {
          if (mounted) setState(() => _bubble = null);
        });
      }
    }

    setState(() {
      _running = running;
      _needsAttention = attention;
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending || _lightReply != null) return;
    if (_voice.active) unawaited(_voice.cancel());
    final current = _currentRoom();
    _input.clear();
    _bubbleTimer?.cancel();
    _objectTimer?.cancel();
    setState(() {
      _sending = true;
      _bubble = null;
      _myLine = text;
    });
    _stage.command('mood', {'mood': 'thinking'});
    try {
      if (_light) {
        await _sendLight(text, current);
        return;
      }
      final binding = await ref.read(companionSessionsProvider.notifier).ensure();
      if (!current()) return;
      _bind(binding.sessionId);
      final chat = ref.read(chatProvider(binding.sessionId).notifier);
      if (!await chat.waitForSync(isCurrent: current)) throw const DshClosedException('not synced');
      if (!current()) return;
      final firstInline = binding.inlinePersona && ref.read(chatProvider(binding.sessionId)).items.isEmpty;
      final aside = companionAside(now: DateTime.now(), notes: List.of(_notes));
      final message = [if (firstInline) companionInlinePersona, ?aside, text].join('\n');
      final sent = await chat.send(message);
      if (!current()) return;
      if (sent) {
        _notes.clear();
      } else {
        throw StateError(ref.read(chatProvider(binding.sessionId)).error ?? 'send');
      }
    } on Object catch (error) {
      if (!current()) return;
      if (_input.text.isEmpty) _input.text = text;
      _stage.command('emotion', {'name': 'worried', 'hold': 3000});
      setState(() => _myLine = null);
      _showBubble(_failureText(error), hold: const Duration(seconds: 6), error: true);
    } finally {
      if (current()) {
        setState(() => _sending = false);
        _refreshMood();
      }
    }
  }

  String _failureText(Object error) {
    final l10n = context.l10n;
    return switch (error) {
      CompanionLightError(failure: CompanionLightFailure.noKey) => l10n.companionLightNoKey,
      CompanionLightError(failure: CompanionLightFailure.badKey) => l10n.companionLightBadKey,
      CompanionLightError(failure: CompanionLightFailure.busy) => l10n.companionLightBusy,
      // Full mode only because nobody picked a mode yet: light would work without a host.
      DshClosedException() when ref.read(companionModeProvider) == null => l10n.companionNotConnectedTryLight,
      DshClosedException() => l10n.companionNotConnected,
      _ => l10n.companionSendFailed,
    };
  }

  /// Light mode: the reply comes straight from the model, and the conversation
  /// stays on this phone.
  Future<void> _sendLight(String text, bool Function() current) async {
    final key = ref.read(settingsProvider).apiKey.trim();
    if (key.isEmpty) throw const CompanionLightError(CompanionLightFailure.noKey);
    final history = _lightHistory ??= CompanionLightHistory.at(_store!.root);
    await history.load();
    // Switched to full (or away) while the history was read: this line is not
    // light mode's any more.
    if (!current()) return;
    final aside = companionAside(now: DateTime.now(), notes: List.of(_notes));
    history.add(CompanionLine.user([?aside, text].join('\n')));
    _notes.clear();
    // Nothing said before this page counts as news.
    _baselineSet = true;
    final turn = _lightTurn = 'light-${++_lightTurns}';
    _lightText = '';
    _lightAsked = text;
    final client = _lightClient = ref.read(companionLightClientProvider)();
    _lightReply =
        streamCompanionReply(
          client: client,
          apiKey: key,
          system: companionPersonaCore,
          lines: history.context(),
        ).listen(
          (delta) {
            if (!mounted || turn != _lightTurn) return;
            _lightText += delta;
            _onReply(turn, _lightText, running: true);
          },
          onError: (Object error) => _endLight(turn, error: error),
          onDone: () => _endLight(turn),
          cancelOnError: true,
        );
    _onReply(turn, '', running: true);
  }

  /// The light reply [turn] is over: finished, failed or stopped. What she
  /// said is kept; a line she never answered goes back into the input.
  void _endLight(String turn, {Object? error}) {
    if (turn != _lightTurn || _lightReply == null) return;
    _lightReply = null;
    _lightTurn = '';
    _lightClient?.close();
    _lightClient = null;
    final history = _lightHistory;
    final answered = _lightText.trim().isNotEmpty;
    if (answered) {
      history?.add(CompanionLine.her(_lightText));
    } else if (error != null) {
      history?.dropUnanswered();
    }
    if (history != null) unawaited(history.save());
    if (!mounted) return;
    if (!answered && error != null) {
      if (_input.text.isEmpty) _input.text = _lightAsked;
      _stage.command('emotion', {'name': 'worried', 'hold': 3000});
    }
    _onReply(turn, _lightText, running: false, error: error == null ? null : _failureText(error));
  }

  /// Ends the light reply on its way, at once: what she has said so far is
  /// kept, the request is dropped (its client closed first), and nothing it
  /// does later reaches the page. Cancelling can itself fail late (a timeout
  /// already under way); that is swallowed, not let loose.
  void _retireLight() {
    final reply = _lightReply;
    if (reply == null) return;
    _endLight(_lightTurn);
    unawaited(reply.cancel().catchError((Object _) {}));
  }

  Future<void> _stop() async {
    if (_lightReply != null) {
      _retireLight();
      return;
    }
    final id = _sessionId;
    if (id == null) return;
    await ref.read(chatProvider(id).notifier).cancel();
  }

  /// Switching modes on the page: drop the reply on its way and the other
  /// mode's conversation, then arrive again.
  void _modeChanged() {
    _boundLight = _light;
    _retireLight();
    setState(_unbind);
    if (!_stageReady) return;
    if (!_light) {
      final binding = ref.read(companionSessionsProvider.notifier).of(ref.read(activeHostProvider));
      if (binding != null) _bind(binding.sessionId);
    }
    // She is already here: no second hello.
    unawaited(_arrive(greet: false));
  }

  void _openFullChat() {
    final id = _sessionId;
    if (id == null) return;
    ref.read(currentSessionProvider.notifier).select(id);
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  // ── Setup ────────────────────────────────────────────────────────────────

  Future<void> _import() async {
    final store = _store;
    if (store == null || _installing) return;
    setState(() {
      _installing = true;
      _installError = null;
    });
    File? temp;
    try {
      final picked = await FilePicker.pickFile();
      if (picked == null) return;
      // Picks may be content URIs: bring it somewhere the unzipper can seek.
      temp = File(
        '${(await getTemporaryDirectory()).path}/companion-import-${DateTime.now().microsecondsSinceEpoch}.zip',
      );
      final sink = temp.openWrite();
      await sink.addStream(picked.readAsByteStream());
      await sink.close();
      await store.install(temp.path);
      final character = await store.character();
      if (!mounted) return;
      setState(() {
        _character = character;
        _failure = null;
        _stageReady = false;
        _phase = _Phase.stage;
      });
    } on CompanionPackException catch (error) {
      if (mounted) setState(() => _installError = _problemText(error.problem));
    } on Object {
      if (mounted) setState(() => _installError = context.l10n.companionPackBroken);
    } finally {
      try {
        await temp?.delete();
      } on FileSystemException {
        // Temp folder; the system clears it.
      }
      if (mounted) setState(() => _installing = false);
    }
  }

  String _problemText(CompanionPackProblem problem) {
    final l10n = context.l10n;
    return switch (problem) {
      CompanionPackProblem.runtimeMismatch => l10n.companionPackRuntimeMismatch,
      CompanionPackProblem.noRuntime => l10n.companionPackNoRuntime,
      CompanionPackProblem.noModel => l10n.companionPackNoModel,
      CompanionPackProblem.forbiddenFile || CompanionPackProblem.unsafePath => l10n.companionPackUnsafe,
      CompanionPackProblem.tooLarge => l10n.companionPackTooLarge,
      CompanionPackProblem.storage => l10n.companionPackStorage,
      CompanionPackProblem.notAPack => l10n.companionPackBroken,
    };
  }

  // ── Menu ─────────────────────────────────────────────────────────────────

  void _chooseMode() {
    final l10n = context.l10n;
    final light = _light;
    unawaited(
      showAppSheet<void>(
        context,
        builder: (sheet) => SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitleBar(l10n.companionMenuMode),
              SheetGroup(
                margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                children: [
                  for (final (mode, icon, title, hint) in [
                    (
                      CompanionMode.light,
                      AppIcons.engineStarting,
                      l10n.companionModeLight,
                      l10n.companionModeLightHint,
                    ),
                    (CompanionMode.full, AppIcons.engine, l10n.companionModeFull, l10n.companionModeFullHint),
                  ])
                    SettingsTile(
                      icon: icon,
                      tinted: false,
                      title: title,
                      subtitle: hint,
                      chevron: false,
                      trailing: (mode == CompanionMode.light) == light ? const Icon(AppIcons.selected, size: 20) : null,
                      onTap: () {
                        Navigator.of(sheet).pop();
                        unawaited(ref.read(companionModeProvider.notifier).choose(mode));
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openMenu() {
    final l10n = context.l10n;
    final light = _light;
    final credit = [
      if (_character.author case final author?) l10n.companionCreditAuthor(author),
      ?_character.license,
      ?_character.source,
    ].join(' · ');
    unawaited(
      showAppSheet<void>(
        context,
        builder: (sheet) => SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitleBar(_character.name ?? l10n.companionTitle),
              SheetGroup(
                margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                children: [
                  SettingsTile(
                    icon: light ? AppIcons.engineStarting : AppIcons.engine,
                    tinted: false,
                    title: l10n.companionMenuMode,
                    value: Text(light ? l10n.companionModeLight : l10n.companionModeFull),
                    onTap: () {
                      Navigator.of(sheet).pop();
                      _chooseMode();
                    },
                  ),
                  // Her memories live on the host for now.
                  if (!light)
                    SettingsTile(
                      icon: AppIcons.bookmark,
                      tinted: false,
                      title: l10n.companionMemoryTitle,
                      onTap: () {
                        Navigator.of(sheet).pop();
                        unawaited(
                          Navigator.of(context)
                              .push(MaterialPageRoute<void>(builder: (_) => const CompanionMemoryPage())),
                        );
                      },
                    ),
                  if (light && (_lightHistory?.lines.isNotEmpty ?? false))
                    SettingsTile(
                      icon: AppIcons.newChat,
                      tinted: false,
                      title: l10n.companionMenuRestart,
                      subtitle: l10n.companionMenuRestartLightHint,
                      onTap: () {
                        Navigator.of(sheet).pop();
                        unawaited(_restart());
                      },
                    ),
                  if (_sessionId != null)
                    SettingsTile(
                      icon: AppIcons.conversations,
                      tinted: false,
                      title: l10n.companionMenuHistory,
                      onTap: () {
                        Navigator.of(sheet).pop();
                        _openFullChat();
                      },
                    ),
                  if (_sessionId != null)
                    SettingsTile(
                      icon: AppIcons.newChat,
                      tinted: false,
                      title: l10n.companionMenuRestart,
                      subtitle: l10n.companionMenuRestartHint,
                      onTap: () {
                        Navigator.of(sheet).pop();
                        unawaited(_restart());
                      },
                    ),
                  SettingsTile(
                    icon: AppIcons.delete,
                    tinted: false,
                    title: l10n.companionMenuRemovePack,
                    onTap: () {
                      Navigator.of(sheet).pop();
                      unawaited(_removePack());
                    },
                  ),
                ],
              ),
              if (credit.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 8, 0, SheetTitleBar.inset + 8, 12),
                  child: Text(credit, style: Theme.of(sheet).textTheme.bodySmall),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _confirm(String action, String message) async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(action),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(dialog.l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(action)),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _restart() async {
    final l10n = context.l10n;
    final light = _light;
    final ok = await _confirm(
      l10n.companionMenuRestart,
      light ? l10n.companionMenuRestartLightConfirm : l10n.companionMenuRestartConfirm,
    );
    if (!ok || !mounted) return;
    if (light) {
      // The reply still on its way would otherwise write itself back after the clear.
      _retireLight();
      await _lightHistory?.clear();
      if (!mounted) return;
      _say(l10n.companionGreetFirst);
      return;
    }
    await ref.read(companionSessionsProvider.notifier).forget();
    if (!mounted) return;
    setState(_unbind);
    _say(l10n.companionGreetFirst);
  }

  Future<void> _removePack() async {
    final l10n = context.l10n;
    final ok = await _confirm(l10n.companionMenuRemovePack, l10n.companionMenuRemoveConfirm);
    if (!ok || !mounted) return;
    setState(() {
      _phase = _Phase.setup;
      _stageReady = false;
    });
    await _store?.remove();
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Changing host while here: her conversation is per host.
    ref.listen(activeHostProvider, (_, _) => _bindingChanged());
    ref.listen(activeConnectionProvider.select((value) => value.value?.client), (_, _) => _bindingChanged());
    ref.listen(companionModeProvider, (before, now) {
      // The saved pick arriving after the page opened changes nothing if it is what she already does.
      bool light(CompanionMode? mode) =>
          mode == CompanionMode.light || (mode == null && ref.read(activeConnectionProvider).value == null);
      if (light(before) != light(now)) _modeChanged();
    });
    final surfaces = DshSurfaces.of(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      // The water is dark at every hour, whatever the app's own theme.
      child: Theme(
        data: buildDarkTheme(accent: surfaces.accent, glassBlur: surfaces.blurEnabled),
        child: Builder(builder: _buildPage),
      ),
    );
  }

  Widget _buildPage(BuildContext context) {
    final l10n = context.l10n;
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    final padding = MediaQuery.paddingOf(context);
    final store = _store;
    final showStage = _phase == _Phase.stage && store != null;
    final name = _character.name ?? l10n.companionDefaultName;
    final events = CompanionStageEvents(
      onReady: _onReady,
      onFailed: (why) {
        if (!mounted) return;
        setState(() {
          _phase = _Phase.failed;
          _failure = why;
        });
      },
      onTouch: _onTouch,
      onWake: () => _say(l10n.companionWake),
      onMood: _onMood,
      onObject: _onObject,
      onActivity: _onActivity,
    );
    return Scaffold(
      backgroundColor: const Color(0xFF0D2F55),
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (showStage)
            ExcludeSemantics(
              child:
                  widget.stageBuilder?.call(_stage, events) ??
                  CompanionStage(store: store, controller: _stage, events: events),
            ),
          if (showStage && !_stageReady) const CompanionWater(child: CompanionArriving()),
          if (_phase == _Phase.setup)
            CompanionWelcome(
              title: l10n.companionSetupTitle,
              message: l10n.companionSetupBody,
              action: l10n.companionSetupImport,
              busy: _installing,
              error: _installError,
              onAction: _import,
            ),
          if (_phase == _Phase.failed)
            CompanionWelcome(
              title: l10n.companionFailedTitle,
              message: l10n.companionFailedBody(_failure ?? ''),
              action: l10n.companionSetupImport,
              state: PetStateName.error,
              busy: _installing,
              error: _installError,
              onAction: _import,
            ),
          Positioned(
            top: padding.top + 8,
            left: companionEdge,
            right: companionEdge,
            child: Row(
              children: [
                CompanionRoundButton(
                  icon: AppIcons.back,
                  label: MaterialLocalizations.of(context).backButtonTooltip,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: Center(
                    child: _stageReady ? CompanionNamePlate(name: name, activity: _activity) : const SizedBox.shrink(),
                  ),
                ),
                if (_stageReady)
                  CompanionRoundButton(icon: AppIcons.more, label: l10n.companionMenu, onTap: _openMenu)
                else
                  const SizedBox(width: 44),
              ],
            ),
          ),
          if (showStage && _stageReady)
            Positioned(
              left: companionEdge,
              right: companionEdge,
              bottom: max(insets, padding.bottom) + companionEdge,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_showTouchHint && _bubble == null)
                    CompanionPill(icon: AppIcons.tip, label: l10n.companionTouchHint)
                  else if (_showHomeHint && _bubble == null)
                    CompanionPill(icon: AppIcons.tip, label: l10n.companionTouchHintHome),
                  if (_needsAttention)
                    CompanionPill(
                      icon: AppIcons.toConfirm,
                      label: l10n.companionNeedsAttention,
                      tone: const Color(0xFFFFD27A),
                      onTap: _openFullChat,
                    ),
                  CompanionMyLine(text: _myLine),
                  CompanionSpeech(
                    text: _bubble,
                    error: _bubbleIsError,
                    thinking: _sending || (_running && _bubble == null),
                  ),
                  const SizedBox(height: 10),
                  CompanionComposer(
                    input: _input,
                    focus: _focus,
                    hint: l10n.companionInputHint(name),
                    running: _running,
                    busy: _sending,
                    listening: _voice.active,
                    voiceAvailable: _voice.available,
                    onSend: _send,
                    onStop: _stop,
                    onVoice: () => _voice.active ? _voice.stop() : _voice.start(),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
