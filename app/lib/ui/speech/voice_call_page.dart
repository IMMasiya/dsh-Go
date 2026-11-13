// 语音通话: one page over the conversation, dark like a phone call. A light in
// the middle breathes with whoever is talking — the person's microphone while
// they speak, her voice while she answers, a slow turn while she thinks. What
// was heard and what she says run underneath, two lines each. Mute, hang up
// and loudspeaker sit at the bottom; an approval or question the conversation
// waits on comes up above them and is answered right here.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../companion/companion_voice.dart';
import '../../companion/companion_voice_source.dart';
import '../../l10n/l10n.dart';
import '../../speech/call/chat_call.dart';
import '../../speech/call/voice_call.dart';
import '../../speech/deepseek_speech.dart';
import '../../speech/read_aloud.dart';
import '../../speech/speech_audio.dart';
import '../../speech/speech_out.dart';
import '../../speech/speech_settings.dart';
import '../../speech/voice_cloud.dart';
import '../../state/voice_state.dart';
import '../chat/voice/voice_bridge.dart';
import '../companion/companion_ask.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'speech_ui.dart';

/// Opens a call with the main chat's conversation. [session] gives its id,
/// creating it for a new chat; [title] heads the page.
Future<void> openChatCall(BuildContext context, {required String title, required Future<String?> Function() session}) {
  final container = ProviderScope.containerOf(context, listen: false);
  container.read(readAloudProvider.notifier).stop();
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: true,
      fullscreenDialog: true,
      transitionDuration: AppMotion.of(context, AppMotion.emphasized),
      reverseTransitionDuration: AppMotion.of(context, AppMotion.standard),
      pageBuilder: (_, _, _) => VoiceCallPage(title: title, conversation: ChatCallConversation(container, session)),
      transitionsBuilder: (_, animation, _, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: AppMotion.enter),
        child: ScaleTransition(
          scale: Tween(begin: 1.04, end: 1.0).animate(CurvedAnimation(parent: animation, curve: AppMotion.enter)),
          child: child,
        ),
      ),
    ),
  );
}

class VoiceCallPage extends ConsumerStatefulWidget {
  const VoiceCallPage({super.key, required this.title, required this.conversation});

  final String title;
  final CallConversation conversation;

  @override
  ConsumerState<VoiceCallPage> createState() => _VoiceCallPageState();
}

class _VoiceCallPageState extends ConsumerState<VoiceCallPage> with WidgetsBindingObserver {
  late final VoiceCallController _call;
  final _clock = Stopwatch();
  Timer? _tick;
  Timer? _leave;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final settings = ref.read(callSettingsProvider);
    final voice =
        ref.read(speechVoiceSettingsProvider) ?? const CompanionVoiceSettings(source: CompanionVoiceSource.deepseek);
    final speaker = ref.read(speechSpeakerProvider);
    final audio = ref.read(speechAudioProvider);
    final deepseek = ref.read(deepSeekSpeechProvider);
    final recognize = ref.read(callRecognizerProvider);
    final bridge = ref.read(voiceBridgeProvider);
    _call = VoiceCallController(
      audio: audio,
      conversation: widget.conversation,
      recognizer: () async {
        // The phone's own voice warms up while the recognizer is found.
        if (voice.source != CompanionVoiceSource.deepseek) unawaited(speaker.ready(voice));
        return recognize();
      },
      voice: () => speechOutFor(voice, deepseek: deepseek, audio: audio, speaker: speaker, call: true, levels: true),
      bargeIn: settings.bargeIn,
      speaker: settings.speaker,
      spokenHint: settings.spoken ? appL10n.speechCallHint : null,
      permission: () async => await bridge.requestPermission() == VoicePermission.granted,
    )..addListener(_changed);
    _clock.start();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _call.phase != CallPhase.ended) setState(() {});
    });
    HapticFeedback.mediumImpact();
    unawaited(_call.start());
  }

  void _changed() {
    if (!mounted) return;
    if (_call.phase == CallPhase.ended && _leave == null) {
      _clock.stop();
      _tick?.cancel();
      // Hung up: gone at once. Ended for a reason: the reason stays a moment.
      _leave = Timer(_call.ended == CallEnd.hungUp ? Duration.zero : const Duration(milliseconds: 2400), () {
        if (mounted) Navigator.of(context).maybePop();
      });
    }
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) _call.backgrounded();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tick?.cancel();
    _leave?.cancel();
    _call
      ..removeListener(_changed)
      ..dispose();
    super.dispose();
  }

  void _hangUp() {
    HapticFeedback.mediumImpact();
    _call.hangUp();
  }

  String _status(L10n l10n) {
    if (_call.phase == CallPhase.ended) {
      return switch (_call.ended) {
        CallEnd.permission => l10n.speechCallEndPermission,
        CallEnd.microphone => l10n.speechCallEndMicrophone,
        CallEnd.noRecognizer => l10n.speechCallEndNoRecognizer,
        CallEnd.background => l10n.speechCallEndBackground,
        CallEnd.failed => l10n.speechCallEndFailed,
        CallEnd.hungUp || null => l10n.speechCallEnded,
      };
    }
    if (_call.muted && _call.phase != CallPhase.speaking && _call.phase != CallPhase.thinking) {
      return l10n.speechCallMuted;
    }
    return switch (_call.phase) {
      CallPhase.starting => l10n.speechCallStarting,
      CallPhase.listening => l10n.speechCallListening,
      CallPhase.hearing => l10n.speechCallHearing,
      CallPhase.thinking => l10n.speechCallThinking,
      CallPhase.speaking => l10n.speechCallSpeaking,
      CallPhase.ended => l10n.speechCallEnded,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final ink = Colors.white;
    final dim = Colors.white.withValues(alpha: 0.62);
    final faint = Colors.white.withValues(alpha: 0.42);
    final elapsed = _clock.elapsed;
    final time =
        '${elapsed.inMinutes.toString().padLeft(2, '0')}:${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}';
    final error = _call.error;
    final sessionId = switch (widget.conversation) {
      final ChatCallConversation chat => chat.sessionId,
      _ => null,
    };
    final level = switch (_call.phase) {
      CallPhase.hearing || CallPhase.listening => _call.micLevel,
      CallPhase.speaking => _call.voiceLevel,
      _ => 0.0,
    };

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Theme(
        data: theme.copyWith(
          brightness: Brightness.dark,
          colorScheme: theme.colorScheme.copyWith(brightness: Brightness.dark),
        ),
        child: Scaffold(
          backgroundColor: Color.lerp(Colors.black, accent, 0.08),
          body: Stack(
            fit: StackFit.expand,
            children: [
              // A glow behind the light, the conversation's own colour.
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -0.22),
                    radius: 0.9,
                    colors: [accent.withValues(alpha: 0.26), Colors.transparent],
                  ),
                ),
              ),
              SafeArea(
                child: Column(
                  children: [
                    const SizedBox(height: 28),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        widget.title,
                        key: const ValueKey('call-title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium?.copyWith(color: ink, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      time,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: faint,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    Expanded(
                      child: Center(
                        child: Semantics(
                          button: _call.phase == CallPhase.speaking,
                          label: _status(l10n),
                          hint: _call.phase == CallPhase.speaking ? l10n.speechCallSkipHint : null,
                          child: GestureDetector(
                            onTap: _call.phase == CallPhase.speaking ? _call.skip : null,
                            child: _Light(phase: _call.phase, level: level, muted: _call.muted, color: accent),
                          ),
                        ),
                      ),
                    ),
                    AnimatedSwitcher(
                      duration: AppMotion.of(context, AppMotion.quick),
                      child: Text(
                        _status(l10n),
                        key: ValueKey(_status(l10n)),
                        style: theme.textTheme.titleSmall?.copyWith(color: dim, letterSpacing: 0.4),
                      ),
                    ),
                    const SizedBox(height: 18),
                    _Lines(
                      heard: _call.heard,
                      reply: _call.reply,
                      error: error == null ? null : speechErrorText(l10n, error, listening: true),
                      dim: dim,
                      ink: ink,
                    ),
                    if (sessionId != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: CompanionAsk(sessionId: sessionId),
                      ),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _RoundKey(
                          key: const ValueKey('call-mute'),
                          icon: _call.muted ? AppIcons.micMuted : AppIcons.voice,
                          label: _call.muted ? l10n.speechCallUnmute : l10n.speechCallMute,
                          on: _call.muted,
                          onTap: _call.phase == CallPhase.ended ? null : () => _call.setMuted(!_call.muted),
                        ),
                        _RoundKey(
                          key: const ValueKey('call-hang-up'),
                          icon: AppIcons.hangUp,
                          label: l10n.speechCallHangUp,
                          danger: true,
                          size: 72,
                          onTap: _call.phase == CallPhase.ended ? null : _hangUp,
                        ),
                        _RoundKey(
                          key: const ValueKey('call-speaker'),
                          icon: _call.speaker ? AppIcons.readAloud : AppIcons.earpiece,
                          label: _call.speaker ? l10n.speechCallSpeakerOn : l10n.speechCallEarpiece,
                          on: _call.speaker,
                          onTap: _call.phase == CallPhase.ended
                              ? null
                              : () => unawaited(_call.setSpeaker(!_call.speaker)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 28),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What was heard (small) and what she is saying (the last two lines of it).
class _Lines extends StatelessWidget {
  const _Lines({required this.heard, required this.reply, required this.error, required this.dim, required this.ink});

  final String heard;
  final String reply;
  final String? error;
  final Color dim;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final said = speakable(reply).replaceAll('\n', ' ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: SizedBox(
        height: 92,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (error != null)
              Text(
                error!,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: theme.textTheme.bodyMedium?.copyWith(color: DshColors.of(context).danger),
              )
            else ...[
              if (heard.isNotEmpty)
                Text(
                  heard,
                  key: const ValueKey('call-heard'),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: dim),
                ),
              if (said.isNotEmpty) ...[
                const SizedBox(height: 6),
                // The newest words in view: the start fades out above.
                ShaderMask(
                  shaderCallback: (rect) => const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.white, Colors.white],
                    stops: [0, 0.35, 1],
                  ).createShader(rect),
                  blendMode: BlendMode.dstIn,
                  child: Text(
                    said.length > 90 ? '…${said.substring(said.length - 90)}' : said,
                    key: const ValueKey('call-reply'),
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.clip,
                    style: theme.textTheme.bodyLarge?.copyWith(color: ink, height: 1.45),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _RoundKey extends StatelessWidget {
  const _RoundKey({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.on = false,
    this.danger = false,
    this.size = 60,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool on;
  final bool danger;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    final fill = danger
        ? colors.danger
        : on
        ? Colors.white
        : Colors.white.withValues(alpha: 0.12);
    final glyph = danger
        ? colors.onDanger
        : on
        ? Colors.black
        : Colors.white;
    return Semantics(
      button: true,
      toggled: danger ? null : on,
      label: label,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: fill,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap == null
                  ? null
                  : () {
                      HapticFeedback.selectionClick();
                      onTap!();
                    },
              child: SizedBox.square(
                dimension: size,
                child: Icon(icon, color: glyph, size: size * 0.4),
              ),
            ),
          ),
          const SizedBox(height: 8),
          ExcludeSemantics(
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.white.withValues(alpha: 0.7)),
            ),
          ),
        ],
      ),
    );
  }
}

/// The light in the middle: breathes while listening, swells with the
/// person's voice while they speak, turns while she thinks, ripples with her
/// voice while she speaks. Dim when muted.
class _Light extends StatefulWidget {
  const _Light({required this.phase, required this.level, required this.muted, required this.color});

  final CallPhase phase;
  final double level;
  final bool muted;
  final Color color;

  @override
  State<_Light> createState() => _LightState();
}

class _LightState extends State<_Light> with SingleTickerProviderStateMixin {
  late final AnimationController _time = AnimationController(vsync: this, duration: const Duration(seconds: 6))
    ..repeat();
  double _level = 0;

  @override
  void dispose() {
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = AppMotion.reduced(context);
    if (still) _time.stop();
    return SizedBox.square(
      dimension: 240,
      child: AnimatedBuilder(
        animation: _time,
        builder: (context, _) {
          // Smoothed toward the latest level: rises quickly, falls slowly.
          final target = widget.level.clamp(0.0, 1.0);
          _level += (target - _level) * (target > _level ? 0.35 : 0.08);
          return CustomPaint(
            painter: _LightPainter(
              t: still ? 0 : _time.value,
              level: _level,
              phase: widget.phase,
              muted: widget.muted,
              color: widget.color,
            ),
          );
        },
      ),
    );
  }
}

class _LightPainter extends CustomPainter {
  _LightPainter({required this.t, required this.level, required this.phase, required this.muted, required this.color});

  final double t;
  final double level;
  final CallPhase phase;
  final bool muted;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final base = size.width * 0.27;
    final angle = t * 2 * math.pi;
    final breath = math.sin(angle * 2) * 0.025;
    final ended = phase == CallPhase.ended;
    final quiet = muted || ended;
    final swell = switch (phase) {
      CallPhase.hearing || CallPhase.speaking => level * 0.32,
      CallPhase.listening => level * 0.12,
      _ => 0.0,
    };
    final r = base * (1 + breath + swell);
    final core = quiet ? Colors.white.withValues(alpha: 0.18) : Color.lerp(color, Colors.white, 0.35)!;

    // Ripples while she speaks: rings drifting outward, louder ones brighter.
    if (phase == CallPhase.speaking) {
      for (var i = 0; i < 3; i++) {
        final p = (t * 3 + i / 3) % 1.0;
        final ring = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = color.withValues(alpha: (1 - p) * (0.18 + level * 0.5));
        canvas.drawCircle(center, r * (1 + p * 0.9), ring);
      }
    }

    // The halo.
    canvas.drawCircle(
      center,
      r * 1.6,
      Paint()
        ..shader = RadialGradient(
          colors: [
            core.withValues(alpha: quiet ? 0.08 : 0.28 + swell),
            Colors.transparent,
          ],
        ).createShader(Rect.fromCircle(center: center, radius: r * 1.6)),
    );

    // The body: lit from the upper left.
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.4),
          radius: 1.1,
          colors: quiet
              ? [Colors.white.withValues(alpha: 0.22), Colors.white.withValues(alpha: 0.06)]
              : [Color.lerp(color, Colors.white, 0.65)!, color, Color.lerp(color, Colors.black, 0.35)!],
        ).createShader(Rect.fromCircle(center: center, radius: r)),
    );

    // Thinking: a bright arc turning around the body.
    if (phase == CallPhase.thinking || phase == CallPhase.starting) {
      final arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 3
        ..shader = SweepGradient(
          colors: [Colors.transparent, Colors.white.withValues(alpha: 0.9)],
          transform: GradientRotation(angle * 2),
        ).createShader(Rect.fromCircle(center: center, radius: r * 1.18));
      canvas.drawArc(Rect.fromCircle(center: center, radius: r * 1.18), angle * 2, math.pi * 1.2, false, arc);
    }
  }

  @override
  bool shouldRepaint(_LightPainter old) =>
      old.t != t || old.level != level || old.phase != phase || old.muted != muted || old.color != color;
}
