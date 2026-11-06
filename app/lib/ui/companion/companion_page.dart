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

import '../../companion/companion_bond.dart';
import '../../companion/companion_initiative.dart';
import '../../companion/companion_initiative_owner.dart';
import '../../companion/companion_keeper.dart';
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

/// The person removed her pack: the one inside the app waits to be asked for.
const _packRemovedKey = 'companion_pack_removed';
const _hintDoneKey = 'companion_touch_hint_done';
const _homeHintDoneKey = 'companion_home_hint_done';

final _sentenceEnd = RegExp(r'[。！？!?…~～]');

enum _Phase { checking, setup, stage, failed }

typedef CompanionStageBuilder = Widget Function(CompanionStageController controller, CompanionStageEvents events);
typedef _ReplyPart = ({AssistantChatItem item, int? retry});

class CompanionPage extends ConsumerStatefulWidget {
  const CompanionPage({super.key, this.storeOverride, this.stageBuilder, this.stageController, this.bundledPack});

  /// Tests point this at a temporary folder.
  final CompanionPackStore? storeOverride;

  /// The pack inside the app. Tests bring their own; with a test folder and
  /// none given, there is none.
  final Future<Uint8List?> Function()? bundledPack;

  /// Tests have no WebView.
  final CompanionStageBuilder? stageBuilder;
  final CompanionStageController? stageController;

  @override
  ConsumerState<CompanionPage> createState() => _CompanionPageState();
}

class _CompanionPageState extends ConsumerState<CompanionPage> implements CompanionInitiativeRoom {
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
  bool _greetingPending = true;
  bool _installing = false;

  /// This app carries a pack, and the first one is unpacking while she arrives.
  bool _bundledHere = false;
  bool _arriving = false;
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
  List<_ReplyPart> _replyParts = const [];
  String _replyWords = '';
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
  CompanionKeeper? _keeper;

  /// Light mode's keeper: her state and memories on this phone.
  CompanionKeeper? _phone;
  CompanionKeeper get _phoneKeeper => _phone ??= ref.read(companionPhoneKeeperProvider)(_store!.root);
  Future<void> _vitalsQueue = Future.value();

  // What's on screen.
  String? _bubble;
  bool _bubbleIsError = false;
  String? _myLine;
  String? _lastLine;
  Timer? _bubbleTimer;
  Timer? _settleTimer;
  Timer? _objectTimer;

  // Her invitation to rest (Pro C451/C452): the installation's owner decides,
  // this page shows it and says what the person really does.
  static int _pages = 0;
  final int _page = ++_pages;
  late final CompanionInitiative _initiative;
  late final AppLifecycleListener _lifecycle;
  int _stageEpoch = 0;
  CompanionInitiativeDisplay? _invite;
  int? _inviteEnds;

  /// The invitation shown, until it is answered or the page moves on.
  String? _inviteOpen;
  bool _routeShown = true;
  bool _accessible = false;
  bool _entered = false;
  bool _leaving = false;
  bool _observeQueued = false;

  @override
  void initState() {
    super.initState();
    _initiative = ref.read(companionInitiativeProvider);
    _lifecycle = AppLifecycleListener(onStateChange: (_) => _observeInitiative());
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
    final bundled = await _hasBundled();
    final removed = (await SharedPreferences.getInstance()).getBool(_packRemovedKey) ?? false;
    if (!mounted) return;
    setState(() {
      _store = store;
      _character = character;
      _bundledHere = bundled;
      _phase = installed ? _Phase.stage : _Phase.setup;
    });
    // The first time, the pack inside the app is unpacked while she swims over.
    // After the person removed it, it waits on the setup screen to be asked for.
    if (!installed && bundled && !removed) await _installBundled(arriving: true);
  }

  Future<bool> _hasBundled() async {
    final own = widget.bundledPack;
    if (own != null) return await own() != null;
    return widget.storeOverride == null && await hasBundledCompanionPack();
  }

  Future<Uint8List?> _bundled() =>
      widget.bundledPack?.call() ??
      (widget.storeOverride == null ? loadBundledCompanionPack() : Future<Uint8List?>.value());

  @override
  void dispose() {
    // Leaving her: no invitation follows, and nothing comes back to this page.
    _leaving = true;
    _initiative.leave(this);
    _lifecycle.dispose();
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
    setState(() {
      _stageReady = true;
      // A new view of her: nothing shown on the last one carries over.
      _stageEpoch++;
    });
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
    // Light mode keeps her on this phone and asks no host for anything.
    final client = ref.read(activeConnectionProvider).value?.client;
    final CompanionKeeper? keeper = _light ? _phoneKeeper : (client == null ? null : HostKeeper(client));
    CompanionSnapshot? snapshot;
    if (keeper != null) {
      try {
        snapshot = await keeper.snapshot().timeout(const Duration(seconds: 3));
      } on Object {
        // Not this host, or not now: she's still here, just without memory of it.
      }
    }
    if (!current()) return;
    if (snapshot != null) {
      _keeper = keeper;
      _applyVitals(snapshot);
    }
    if (greet) await _greet(snapshot?.vitals.lastVisitAt, current);
    if (current() && snapshot != null) _event('visit');
  }

  void _applyVitals(CompanionSnapshot snapshot) {
    final before = _vitals;
    _vitals = snapshot;
    final v = snapshot.vitals;
    _stage.command('vitals', {'valence': v.valence, 'energy': v.energy, 'closeness': v.closeness});
    _stage.command('activity', {'name': v.activity, 'remainingMs': snapshot.activityLeft.inMilliseconds});
    // A step closer while the person is here: a small moment, once, as it
    // happens. Arriving with it already reached is not news.
    if (before != null && before.storeId == snapshot.storeId) {
      final step = companionBond(v.closeness);
      if (step > companionBond(before.vitals.closeness)) _closer(step);
    }
  }

  void _closer(int step) {
    _stage.command('emotion', {'name': 'happy', 'hold': 3200});
    _stage.command('action', {'name': 'hop'});
    _remember('你觉得和对方又亲近了一些');
    if (!mounted || _running || _sending) return;
    final l10n = context.l10n;
    _say(switch (step) {
      1 => l10n.companionCloser1,
      2 => l10n.companionCloser2,
      _ => l10n.companionCloser3,
    });
  }

  /// One event at a time, against the state last read. A conflict reads again;
  /// it never sends the same event twice.
  void _event(String type) {
    final keeper = _keeper;
    if (keeper == null) return;
    final current = _currentRoom();
    _vitalsQueue = _vitalsQueue.then((_) async {
      if (!current() || !identical(keeper, _keeper)) return;
      final read = _vitals;
      if (read == null) return;
      try {
        try {
          final next = await keeper.event(read, type);
          if (current()) _applyVitals(next);
        } on DshRemoteException catch (error) {
          if (!current() || (!error.code.endsWith('conflict') && !error.code.endsWith('store-changed'))) return;
          final again = await keeper.snapshot();
          if (current() && again != null) _applyVitals(again);
        }
      } on Object {
        // The refresh can fail too. Keep the queue usable; never retry a write.
      }
    });
  }

  /// A later intent owns this visit's response, even before it has words.
  void _retireGreeting() => _greetingPending = false;

  bool _takeGreeting(bool Function() current) {
    if (!current() || !_greetingPending) return false;
    _greetingPending = false;
    return !_running && !_sending;
  }

  Future<void> _greet(DateTime? lastVisit, bool Function() current) async {
    final now = DateTime.now();
    final greeting = companionGreeting(now, lastVisit ?? await companionLastSeen());
    unawaited(companionMarkSeen(now));
    if (!mounted || !_takeGreeting(current)) return;
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
    _initiative.activate(this);
    _retireGreeting();
    if (_showTouchHint) {
      setState(() {
        _showTouchHint = false;
        _showHomeHint = !_homeHintDone;
      });
      unawaited(SharedPreferences.getInstance().then((p) => p.setBool(_hintDoneKey, true)));
    }
    final l10n = context.l10n;
    // Once they're close she has a fonder word too.
    final close = companionBond(_vitals?.vitals.closeness ?? 0) >= 2;
    final lines = switch ((zone, kind)) {
      (_, 'hug') => [l10n.companionHug1, l10n.companionHug2, l10n.companionHug3, if (close) l10n.companionHugClose],
      (_, 'tease') => [l10n.companionTease1, l10n.companionTease2, l10n.companionTease3],
      (_, 'pat') => [l10n.companionPat1, l10n.companionPat2, l10n.companionPat3, if (close) l10n.companionPatClose],
      ('head', _) => [l10n.companionTapHead1, l10n.companionTapHead2],
      ('face', _) => [l10n.companionTapFace1, l10n.companionTapFace2, l10n.companionTapFace3],
      ('tail', _) => [l10n.companionTapTail1, l10n.companionTapTail2, l10n.companionTapTail3],
      ('legs', _) => [l10n.companionTapLegs1, l10n.companionTapLegs2],
      _ => [l10n.companionTapBody1, l10n.companionTapBody2, l10n.companionTapBody3],
    };
    // A hug is affection the way a pat is: the same event for her state.
    if (kind == 'pat' || kind == 'hug') _event('pet');
    _remember(switch ((zone, kind)) {
      (_, 'hug') => '对方刚才抱了抱你',
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

  /// A tap on one of her things.
  void _onObject(String id) {
    _initiative.activate(this);
    _useObject(id);
  }

  /// One of her things, from a tap or because she asked and the person said
  /// yes ([invited]): the same entry, so the cushion is the cushion either way.
  void _useObject(String id, {bool invited = false}) {
    _retireGreeting();
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
      _ when invited => '你邀请对方陪你在海草软垫上歇一会儿，对方答应了',
      'snack' => '对方刚才给你吃了一块点心',
      'play' => '对方刚才陪你玩了泡泡球',
      _ => '对方刚才让你在海草软垫上歇一会儿',
    });
    if (_running || _sending) return;
    final l10n = context.l10n;
    final lines = switch (id) {
      _ when invited => [l10n.companionInviteYes1, l10n.companionInviteYes2],
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
    _retireGreeting();
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

  // ── Invitations (Pro C451/C452) ──────────────────────────────────────────

  /// This page, this mode and binding, this view of her. A change retires
  /// whatever was shown for the one before (C452 §3).
  String get _initiativeContext => '$_page/${_boundLight ? 'light' : 'full'}/$_bindingEpoch/$_stageEpoch';

  /// Everything that decides whether she may ask now. Anything unsure blocks.
  CompanionInitiativeView _initiativeView() => CompanionInitiativeView.room(
    routeVisible: _routeShown,
    stageReady: _stageReady && _phase == _Phase.stage,
    resumed: WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    inputBusy: _focus.hasFocus || _input.text.trim().isNotEmpty,
    generating: _sending || _running || _lightReply != null,
    // Her mouth still settling counts: the words may still be on their way out.
    audioBusy: _voice.active || (_settleTimer?.isActive ?? false),
    activityBusy: _home != 'idle' || _asleep || (_objectTimer?.isActive ?? false),
    approvalPending: _needsAttention,
    externalPromptBusy: _bubble != null || _myLine != null,
    quietHoursBlocked: false,
    enabled: ref.read(companionInitiativeEnabledProvider) ?? false,
    accessible: _accessible,
    contextKey: _initiativeContext,
  );

  bool _presentable(CompanionInitiativeView view) => view.visible && view.resumed && !view.blocked && view.enabled;

  /// After this frame: the owner hears what the page now looks like.
  void _queueObserve() {
    if (_observeQueued) return;
    _observeQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _observeQueued = false;
      _observeInitiative();
    });
  }

  void _observeInitiative() {
    if (!mounted || _leaving) return;
    final view = _initiativeView();
    if (_entered) {
      _initiative.observe(this, view);
    } else {
      _entered = true;
      _initiative.enter(this, view);
    }
  }

  /// Something the person really did here: no invitation this visit.
  void _acted() => _initiative.activate(this);

  @override
  bool canPresent(CompanionInitiativeTicket ticket) =>
      mounted &&
      !_leaving &&
      // She greets in her own words when the person arrives; only invitations come here.
      ticket.kind == CompanionPromptKind.invite &&
      ticket.contextKey == _initiativeContext &&
      _presentable(_initiativeView());

  @override
  void show(CompanionInitiativeDisplay display) {
    if (!mounted || _leaving) return;
    setState(() {
      _invite = display;
      _inviteEnds = display.expiresAtMono;
      _inviteOpen = display.ticket.id;
    });
    // She looks over at the cushion, and a few bubbles rise from it. No words.
    _stage.command('glance', {'prop': 'rest', 'ms': 1800});
    _stage.command('beckon', {'prop': 'rest'});
  }

  @override
  void hide(String ticketId) {
    if (!mounted || _leaving || _invite?.ticket.id != ticketId) return;
    setState(() => _invite = null);
    _stage.command('beckon', {'prop': null});
  }

  @override
  void retime(String ticketId, int? expiresAtMono) {
    if (!mounted || _leaving || _invite?.ticket.id != ticketId) return;
    setState(() => _inviteEnds = expiresAtMono);
  }

  @override
  void rest(CompanionInitiativeEffect intent) {
    // Only the invitation this page showed, in the room it showed it in, once.
    if (!mounted || _leaving || intent.ticketId != _inviteOpen || intent.contextKey != _initiativeContext) return;
    _inviteOpen = null;
    // The cushion gives under her as if tapped; what lasts is the rest itself.
    _stage.command('prop', {'name': 'rest'});
    _useObject('rest', invited: true);
  }

  void _answerInvite({required bool yes}) {
    final invite = _invite;
    if (invite == null) return;
    final view = _initiativeView();
    final id = invite.ticket.id;
    if (yes) {
      _initiative.accept(this, id, view);
    } else if (_initiative.decline(this, id, view) && mounted) {
      // Fine by her: a small nod, nothing said.
      _stage.command('action', {'name': 'nodSmall'});
    }
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
    _greetingPending = true;
    if (_voice.active) unawaited(_voice.cancel());
    _bubbleTimer?.cancel();
    _settleTimer?.cancel();
    _objectTimer?.cancel();
    _vitals = null;
    _keeper = null;
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
    _replyParts = const [];
    _replyWords = '';
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
  (String?, List<_ReplyPart>) _latestReply(ChatState state) {
    final tail = <ChatItem>[];
    String? user;
    for (final item in state.items.reversed) {
      if (item is UserChatItem) {
        user = item.key;
        break;
      }
      tail.add(item);
    }
    final parts = <_ReplyPart>[];
    int? retry;
    for (final item in tail.reversed) {
      if (item is NoticeChatItem && item.kind == 'retry') retry = item.seq;
      if (item is AssistantChatItem && item.text.isNotEmpty) parts.add((item: item, retry: retry));
    }
    return (user, parts);
  }

  void _onChat(ChatState state) {
    if (!mounted) return;
    final (user, parts) = _latestReply(state);
    _onReply(
      user,
      parts.map((part) => part.item.text).join('\n'),
      parts: parts,
      running: state.running || state.pending.isNotEmpty,
      attention: state.openApproval != null || state.questions.isNotEmpty,
      error: state.error,
      loading: state.loading,
    );
  }

  /// Keep progress only for the same full-mode assistant segments. A retry
  /// can replace a draft without publishing its empty interval to this page.
  void _retainReplyProgress(List<_ReplyPart> next) {
    final prefix = <String>[];
    for (var i = 0; i < min(_replyParts.length, next.length); i++) {
      final old = _replyParts[i];
      final current = next[i];
      // FinishChunk makes a draft nonstreaming too; only seq identifies a
      // durable message. Its row key is shared with the draft it commits.
      final commitsDraft = old.item.seq == null && current.item.seq != null && old.item.key == current.item.key;
      if (old.retry != current.retry || (old.item.id != current.item.id && !commitsDraft)) break;
      final before = old.item.text;
      final after = current.item.text;
      if (before == after) {
        prefix.add(before);
        continue;
      }
      var end = 0;
      while (end < min(before.length, after.length) && before.codeUnitAt(end) == after.codeUnitAt(end)) {
        end++;
      }
      prefix.add(before.substring(0, end));
      break;
    }
    final retainedText = prefix.join('\n');
    if (retainedText != _replyParts.map((part) => part.item.text).join('\n')) {
      final retained = parseCompanionReply(retainedText, streaming: true);
      _marksHandled = min(_marksHandled, retained.marks.length);
      _wordsSpoken = min(_wordsSpoken, retained.words.length);
    }
    _replyParts = next;
  }

  /// The current text owns the subtitle, even when a failed attempt is
  /// replaced by fewer words. Fresh progress also permits a later identical line.
  void _showReplyWords(String words, int fresh) {
    if (fresh <= 0 && words == _replyWords) return;
    _replyWords = words;
    if (words.isEmpty) {
      _bubbleTimer?.cancel();
      _bubble = null;
      _bubbleIsError = false;
    } else {
      _myLine = null;
      _showBubble(words);
    }
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
    List<_ReplyPart>? parts,
  }) {
    if (!_baselineSet) {
      // What's already in the conversation has been said; only news moves her.
      if (loading) return;
      _baselineSet = true;
      _baselineUser = user;
      final old = parseCompanionReply(text);
      _marksHandled = old.marks.length;
      _wordsSpoken = old.words.length;
      _replyParts = parts ?? const [];
      _replyWords = old.words;
      if (!running) {
        setState(() => _needsAttention = attention);
        return;
      }
    }

    if (user != _baselineUser) {
      _retireGreeting();
      _baselineUser = user;
      _marksHandled = 0;
      _wordsSpoken = 0;
      _replyParts = const [];
    }

    if (parts != null) _retainReplyProgress(parts);
    final reply = parseCompanionReply(text, streaming: running);
    for (final mark in reply.marks.skip(_marksHandled)) {
      _retireGreeting();
      switch (mark.kind) {
        case CompanionMarkKind.emotion:
          _stage.command('emotion', {'name': mark.name});
        case CompanionMarkKind.action:
          _stage.command('action', {'name': mark.name});
      }
    }
    _marksHandled = reply.marks.length;

    final fresh = reply.words.length - _wordsSpoken;
    if (fresh > 0) {
      _stage.command('say', {'chars': fresh});
      if (_sentenceEnd.hasMatch(reply.words.substring(_wordsSpoken))) _stage.command('beat');
    }
    _wordsSpoken = reply.words.length;
    _showReplyWords(reply.words, fresh);

    if (running) {
      _retireGreeting();
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
    _acted();
    _retireGreeting();
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
    // What she has been asked to remember, kept on this phone. Unreadable
    // memories only mean she talks without them this time.
    var memories = const <CompanionMemory>[];
    try {
      memories = (await _phoneKeeper.memories().timeout(const Duration(seconds: 2))).memories;
    } on Object {
      // Nothing to bring up this time.
    }
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
          system: companionLightSystem(memories),
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
    _acted();
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

  /// A pack the person picks.
  Future<void> _import() => _installFrom((claim) async {
    final picked = await FilePicker.pickFile();
    if (picked == null) return null;
    // Picks may be content URIs: bring it somewhere the unzipper can seek.
    final temp = claim(
      '${(await getTemporaryDirectory()).path}/companion-import-${DateTime.now().microsecondsSinceEpoch}.zip',
    );
    final sink = temp.openWrite();
    try {
      await sink.addStream(picked.readAsByteStream());
    } finally {
      await sink.close();
    }
    return temp;
  });

  /// The pack inside the app, through the same checks as any other.
  /// [arriving]: the first time, she swims over while it unpacks.
  Future<void> _installBundled({bool arriving = false}) => _installFrom((claim) async {
    final bytes = await _bundled();
    if (bytes == null) throw const CompanionPackException(CompanionPackProblem.notAPack);
    final zip = claim('${_store!.root.parent.path}/companion-bundled-${DateTime.now().microsecondsSinceEpoch}.zip');
    await zip.writeAsBytes(bytes, flush: true);
    return zip;
  }, arriving: arriving);

  /// [bring] makes the zip to install, through `claim` for its temporary
  /// file: claimed before anything is written, so a write that fails halfway
  /// is cleaned up too (Pro C542).
  Future<void> _installFrom(
    Future<File?> Function(File Function(String path) claim) bring, {
    bool arriving = false,
  }) async {
    final store = _store;
    if (store == null || _installing) return;
    setState(() {
      _installing = true;
      _arriving = arriving;
      _installError = null;
    });
    File? temp;
    try {
      final zip = await bring((path) => temp = File(path));
      if (zip == null) return;
      await store.install(zip.path);
      final character = await store.character();
      // She's back: the pack inside the app may come by itself again.
      unawaited(SharedPreferences.getInstance().then((p) => p.remove(_packRemovedKey)));
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
      if (mounted) {
        setState(() {
          _installing = false;
          _arriving = false;
        });
      }
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
    _acted();
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
        // Scrolls on a short screen instead of overflowing.
        builder: (sheet) => SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SheetTitleBar(_character.name ?? l10n.companionTitle),
                SheetGroup(
                  margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
                  children: [
                    // Only where her state is kept: otherwise there is nothing to show.
                    if (_vitals case final vitals?)
                      SettingsTile(
                        icon: AppIcons.postLike,
                        tinted: false,
                        title: l10n.companionBondTitle,
                        value: CompanionBondMeter(
                          step: companionBond(vitals.vitals.closeness),
                          label: switch (companionBond(vitals.vitals.closeness)) {
                            0 => l10n.companionBond0,
                            1 => l10n.companionBond1,
                            2 => l10n.companionBond2,
                            _ => l10n.companionBond3,
                          },
                        ),
                      ),
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
                    SettingsTile(
                      icon: AppIcons.bookmark,
                      tinted: false,
                      title: l10n.companionMemoryTitle,
                      onTap: () {
                        Navigator.of(sheet).pop();
                        unawaited(
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => CompanionMemoryPage(phone: light ? _phoneKeeper : null),
                            ),
                          ),
                        );
                      },
                    ),
                    Consumer(
                      builder: (context, ref, _) => SettingsSwitchTile(
                        icon: AppIcons.companionInvite,
                        tinted: false,
                        title: l10n.companionMenuInvite,
                        subtitle: l10n.companionMenuInviteHint,
                        value: ref.watch(companionInitiativeEnabledProvider) ?? false,
                        onChanged: (on) => unawaited(ref.read(companionInitiativeEnabledProvider.notifier).set(on)),
                      ),
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
    final ok = await _confirm(
      l10n.companionMenuRemovePack,
      _bundledHere ? l10n.companionMenuRemoveConfirmBundled : l10n.companionMenuRemoveConfirm,
    );
    if (!ok || !mounted) return;
    // Removed on purpose: the pack inside the app doesn't come back by itself.
    unawaited(SharedPreferences.getInstance().then((p) => p.setBool(_packRemovedKey, true)));
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
    // What her invitation depends on that only a build can see: this page in
    // front (a sheet or another page over her isn't), a screen reader, the switch.
    _routeShown = TickerMode.valuesOf(context).enabled && (ModalRoute.isCurrentOf(context) ?? true);
    _accessible = MediaQuery.accessibleNavigationOf(context);
    ref.watch(companionInitiativeEnabledProvider);
    _queueObserve();
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
    // Shown only while it still belongs here and nothing else has the floor,
    // in this very frame (the owner hears about it right after).
    final invite = _invite;
    final inviting =
        invite != null && invite.ticket.contextKey == _initiativeContext && _presentable(_initiativeView());
    final inviteLeft = switch (_inviteEnds) {
      final ends? when inviting => Duration(
        milliseconds: max(0, ends - ref.read(companionInitiativeClockProvider)().monoMs),
      ),
      _ => null,
    };
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
            // A finger landing on her already counts, before the stage knows
            // whether it was a tap, a pat or nothing (C452 §5.1).
            Listener(
              onPointerDown: (_) => _acted(),
              child: ExcludeSemantics(
                child:
                    widget.stageBuilder?.call(_stage, events) ??
                    CompanionStage(store: store, controller: _stage, events: events),
              ),
            ),
          if ((showStage && !_stageReady) || (_phase == _Phase.setup && _arriving))
            const CompanionWater(child: CompanionArriving())
          else if (_phase == _Phase.setup)
            CompanionWelcome(
              title: l10n.companionSetupTitle,
              message: _bundledHere ? l10n.companionSetupBodyBundled : l10n.companionSetupBody,
              action: _bundledHere ? l10n.companionSetupBundled : l10n.companionSetupImport,
              busy: _installing,
              error: _installError,
              onAction: _bundledHere ? _installBundled : _import,
              secondary: _bundledHere ? l10n.companionSetupImportOther : null,
              onSecondary: _import,
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
                  onTap: () {
                    _acted();
                    unawaited(Navigator.of(context).maybePop());
                  },
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
                  // Her invitation takes the hint's place while it's there.
                  if (_showTouchHint && _bubble == null && !inviting)
                    CompanionPill(icon: AppIcons.tip, label: l10n.companionTouchHint)
                  else if (_showHomeHint && _bubble == null && !inviting)
                    CompanionPill(icon: AppIcons.tip, label: l10n.companionTouchHintHome),
                  if (_needsAttention)
                    CompanionPill(
                      icon: AppIcons.toConfirm,
                      label: l10n.companionNeedsAttention,
                      tone: const Color(0xFFFFD27A),
                      onTap: () {
                        _acted();
                        _openFullChat();
                      },
                    ),
                  CompanionMyLine(text: _myLine),
                  CompanionSpeech(
                    text: _bubble,
                    error: _bubbleIsError,
                    thinking: _sending || (_running && _bubble == null),
                  ),
                  CompanionInvite(
                    ticket: inviting ? invite.ticket.id : null,
                    text: l10n.companionInviteRest,
                    accept: l10n.companionInviteAccept,
                    decline: l10n.companionInviteDecline,
                    remaining: inviteLeft,
                    total: const Duration(milliseconds: CompanionInitiativeRules.promptMs),
                    onAccept: () => _answerInvite(yes: true),
                    onDecline: () => _answerInvite(yes: false),
                  ),
                  const SizedBox(height: 10),
                  CompanionComposer(
                    onUserInput: _acted,
                    input: _input,
                    focus: _focus,
                    hint: l10n.companionInputHint(name),
                    running: _running,
                    busy: _sending,
                    listening: _voice.active,
                    voiceAvailable: _voice.available,
                    onSend: _send,
                    onStop: _stop,
                    onVoice: () {
                      // Reaching for the microphone is already doing something.
                      _acted();
                      _voice.active ? _voice.stop() : _voice.start();
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
