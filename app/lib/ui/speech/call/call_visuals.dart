// What 语音通话 draws: a round light on a dark field. One colour, one shape;
// only its size and glow move — breathing while it waits, swelling with the
// voice, breathing a little quicker while she thinks, greying when muted. One
// clock ([CallScene]) drives it; the painters repaint from it without rebuilding.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../speech/call/voice_call.dart';

/// The light's colours, top to bottom: nearly white, a soft blue, a deeper blue.
abstract final class CallTones {
  static const top = Color(0xFFF6F8FF);
  static const soft = Color(0xFFB4C4FF);
  static const body = Color(0xFF6B86FA);
  static const deep = Color(0xFF4B63E6);
  static const field = Color(0xFF05070F);
}

/// The clock and the smoothed state the painters draw from. [tick] once a frame.
class CallScene extends ChangeNotifier {
  /// Seconds since the call page opened.
  double time = 0;

  /// The voice now (the person's or hers), smoothed: rises quickly, settles slowly.
  double level = 0;

  /// How much it is thinking (0–1, eased).
  double think = 0;
  double muted = 0;

  /// 0 → 1 as the call opens, back to 0 as it ends.
  double appear = 0;

  void tick(
    double seconds, {
    required CallPhase phase,
    required double mic,
    required double voice,
    required bool isMuted,
  }) {
    final dt = (seconds - time).clamp(0.0, 0.1);
    time = seconds;
    final target = switch (phase) {
      CallPhase.hearing => mic,
      CallPhase.speaking => voice,
      _ => 0.0,
    }.clamp(0.0, 1.0);
    double ease(double from, double to, double rate) => from + (to - from) * (1 - math.exp(-rate * dt));
    level = ease(level, target, target > level ? 10 : 4);
    think = ease(think, phase == CallPhase.thinking || phase == CallPhase.starting ? 1 : 0, 3);
    muted = ease(muted, isMuted && phase != CallPhase.speaking ? 1 : 0, 5);
    appear = ease(appear, phase == CallPhase.ended ? 0 : 1, phase == CallPhase.ended ? 6 : 3);
    notifyListeners();
  }

  /// How big the light is now, relative to its resting size.
  double get scale {
    final breath = math.sin(time * (1.4 + think * 1.6)) * (0.012 + think * 0.018);
    return (0.82 + 0.18 * appear) * (1 + breath + level * 0.13);
  }
}

Color _grey(Color c, double amount) {
  if (amount <= 0) return c;
  final l = c.r * 0.3 + c.g * 0.59 + c.b * 0.11;
  final g = Color.from(alpha: c.a, red: l, green: l, blue: math.min(1, l * 1.04));
  return Color.lerp(c, g, amount * 0.85)!;
}

/// The dark field, with one soft light behind where the round light sits.
class CallField extends StatelessWidget {
  const CallField({super.key, required this.scene, this.center = 0.4});

  final CallScene scene;

  /// The light's height on the screen (0 top, 1 bottom).
  final double center;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(painter: _FieldPainter(scene, center), child: const SizedBox.expand()),
  );
}

class _FieldPainter extends CustomPainter {
  _FieldPainter(this.scene, this.center) : super(repaint: scene);

  final CallScene scene;
  final double center;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = CallTones.field);
    final glow = _grey(CallTones.deep, scene.muted);
    final at = Offset(size.width / 2, size.height * center);
    final radius = size.width * (0.95 + scene.level * 0.12);
    canvas.drawCircle(
      at,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            glow.withValues(alpha: (0.2 + scene.level * 0.1) * scene.appear),
            glow.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: at, radius: radius)),
    );
  }

  @override
  bool shouldRepaint(_FieldPainter old) => old.center != center;
}

/// The round light. Its resting diameter is [size] × 0.5; the rest is glow.
class CallLight extends StatelessWidget {
  const CallLight({super.key, required this.scene, this.size = 300});

  final CallScene scene;
  final double size;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _LightPainter(scene)),
    ),
  );
}

class _LightPainter extends CustomPainter {
  _LightPainter(this.scene) : super(repaint: scene);

  final CallScene scene;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.shortestSide * 0.25 * scene.scale;
    if (r <= 0.5) return;
    final muted = scene.muted;
    final top = _grey(CallTones.top, muted);
    final soft = _grey(CallTones.soft, muted);
    final body = _grey(CallTones.body, muted);
    final deep = _grey(CallTones.deep, muted);
    final fade = scene.appear;

    // The glow: soft, a little stronger with the voice.
    canvas.drawCircle(
      center,
      r * 1.02,
      Paint()
        ..color = body.withValues(alpha: (0.38 + scene.level * 0.3) * fade)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.42),
    );

    final disc = Rect.fromCircle(center: center, radius: r);
    // The body: lit from above like a pearl, its edge just soft enough to read as light.
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -0.55),
          radius: 1.1,
          colors: [
            top.withValues(alpha: fade),
            soft.withValues(alpha: fade),
            body.withValues(alpha: fade),
            deep.withValues(alpha: fade),
          ],
          stops: const [0, 0.35, 0.78, 1],
        ).createShader(disc)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.018),
    );
    canvas.save();
    canvas.clipPath(Path()..addOval(disc));
    // A faint light drifting inside, slow enough to feel alive, not busy.
    final t = scene.time;
    final drift = Offset(math.cos(t * 0.23) * 0.32, math.sin(t * 0.19) * 0.28 + 0.12);
    canvas.drawRect(
      disc,
      Paint()
        ..shader = RadialGradient(
          center: Alignment(drift.dx, drift.dy),
          radius: 0.62,
          colors: [
            Colors.white.withValues(alpha: 0.12 * fade),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(disc),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LightPainter old) => false;
}

/// Drives a [CallScene] from a ticker for as long as it is mounted.
class CallClock extends StatefulWidget {
  const CallClock({super.key, required this.onTick, required this.child});

  final void Function(double seconds) onTick;
  final Widget child;

  @override
  State<CallClock> createState() => _CallClockState();
}

class _CallClockState extends State<CallClock> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((elapsed) => widget.onTick(elapsed.inMicroseconds / 1e6));

  @override
  void initState() {
    super.initState();
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
