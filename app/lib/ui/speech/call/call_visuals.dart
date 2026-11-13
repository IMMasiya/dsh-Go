// What 语音通话 draws: deep water at night, a drop of light in it that breathes
// with whoever is talking, plankton drifting up, a voice line under the light,
// and rings rolling out when she speaks up. One clock ([CallScene]) drives all
// of it; every layer repaints from it without rebuilding widgets.
//
// The light and the water are fragment shaders (app/shaders/); a phone in the
// lightweight tier, or one where they fail to load, gets painted stand-ins.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../speech/call/voice_call.dart';

/// The light's three colours (bright, deep, accent).
@immutable
class CallPalette {
  const CallPalette(this.a, this.b, this.c);

  final Color a;
  final Color b;
  final Color c;

  static CallPalette lerp(CallPalette x, CallPalette y, double t) =>
      CallPalette(Color.lerp(x.a, y.a, t)!, Color.lerp(x.b, y.b, t)!, Color.lerp(x.c, y.c, t)!);

  /// Waiting for the person: calm water blue (DeepSeek's whale blue at its core).
  static const listening = CallPalette(Color(0xFF6FD3FF), Color(0xFF4D6BFE), Color(0xFF8C7BFF));

  /// The person speaking: fresher, greener.
  static const hearing = CallPalette(Color(0xFF7CF5D2), Color(0xFF1FA7E0), Color(0xFF4D6BFE));

  /// Thinking: lavender, turning.
  static const thinking = CallPalette(Color(0xFFC6B5FF), Color(0xFF6A55F5), Color(0xFF3CC8FF));

  /// Her voice: warm pink into violet.
  static const speaking = CallPalette(Color(0xFFFFA6DA), Color(0xFF8E5CFF), Color(0xFF4FA9FF));

  static const muted = CallPalette(Color(0xFFB8C2D6), Color(0xFF52607A), Color(0xFF7C88A3));

  static CallPalette of(CallPhase phase, {required bool muted}) {
    if (muted && phase != CallPhase.speaking && phase != CallPhase.thinking) return CallPalette.muted;
    return switch (phase) {
      CallPhase.hearing => hearing,
      CallPhase.thinking || CallPhase.starting => thinking,
      CallPhase.speaking => speaking,
      CallPhase.listening || CallPhase.ended => listening,
    };
  }
}

class _Ripple {
  _Ripple(this.born, this.strength);
  final double born;
  final double strength;

  /// Seconds from the voice rising to the ring gone.
  static const life = 1.7;
}

/// The clock and the smoothed state every layer draws from. [tick] once a frame.
class CallScene extends ChangeNotifier {
  /// Seconds since the call page opened.
  double time = 0;

  /// The voice now (the person's or hers), smoothed: rises fast, falls slowly.
  double level = 0;

  /// How much the light is thinking (0–1, eased).
  double think = 0;
  double muted = 0;

  /// 0 → 1 as the call opens, back to 0 as it ends.
  double appear = 0;

  /// Someone is speaking: the water brightens a little.
  double energy = 0;
  CallPalette palette = CallPalette.thinking;
  final ripples = <_Ripple>[];
  double _lastRipple = -10;
  double _lastLevel = 0;

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
      CallPhase.listening => mic * 0.35,
      CallPhase.speaking => voice,
      _ => 0.0,
    }.clamp(0.0, 1.0);
    double ease(double from, double to, double rate) => from + (to - from) * (1 - math.exp(-rate * dt));
    level = ease(level, target, target > level ? 18 : 5);
    think = ease(think, phase == CallPhase.thinking || phase == CallPhase.starting ? 1 : 0, 4);
    muted = ease(muted, isMuted ? 1 : 0, 6);
    appear = ease(appear, phase == CallPhase.ended ? 0 : 1, phase == CallPhase.ended ? 5 : 2.6);
    energy = ease(energy, phase == CallPhase.hearing || phase == CallPhase.speaking ? 0.4 + level * 0.6 : 0, 3);
    palette = CallPalette.lerp(palette, CallPalette.of(phase, muted: isMuted), 1 - math.exp(-3.2 * dt));
    // A ring rolls out when a voice rises past a threshold.
    final loud = (phase == CallPhase.speaking || phase == CallPhase.hearing) && level > 0.42;
    if (loud && _lastLevel <= 0.42 && time - _lastRipple > 0.28) {
      ripples.add(_Ripple(time, level));
      _lastRipple = time;
    }
    _lastLevel = level;
    ripples.removeWhere((r) => time - r.born > _Ripple.life);
    notifyListeners();
  }
}

/// The two shader programs, loaded once; null until loaded or when they can't be.
abstract final class CallShaders {
  static ui.FragmentProgram? orb;
  static ui.FragmentProgram? sea;
  static Future<void>? _loading;

  static Future<void> load() => _loading ??= () async {
    try {
      orb = await ui.FragmentProgram.fromAsset('shaders/voice_orb.frag');
      sea = await ui.FragmentProgram.fromAsset('shaders/voice_sea.frag');
    } catch (_) {
      // No shader support here (tests, some GPUs): the painted stand-ins.
      orb = null;
      sea = null;
    }
  }();
}

void _rgb(ui.FragmentShader shader, int at, Color color) {
  shader
    ..setFloat(at, color.r)
    ..setFloat(at + 1, color.g)
    ..setFloat(at + 2, color.b);
}

// ── The water ──────────────────────────────────────────────────────────────

/// Deep water behind everything. [center] is the light's height (0–1).
class SeaBackground extends StatefulWidget {
  const SeaBackground({super.key, required this.scene, this.center = 0.4, this.shaders = true});

  final CallScene scene;
  final double center;
  final bool shaders;

  @override
  State<SeaBackground> createState() => _SeaBackgroundState();
}

class _SeaBackgroundState extends State<SeaBackground> {
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    if (widget.shaders) {
      CallShaders.load().then((_) {
        if (mounted && CallShaders.sea != null) setState(() => _shader = CallShaders.sea!.fragmentShader());
      });
    }
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(painter: _SeaPainter(widget.scene, _shader, widget.center), child: const SizedBox.expand()),
  );
}

class _SeaPainter extends CustomPainter {
  _SeaPainter(this.scene, this.shader, this.center) : super(repaint: scene);

  final CallScene scene;
  final ui.FragmentShader? shader;
  final double center;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final p = scene.palette;
    final s = shader;
    if (s != null) {
      s
        ..setFloat(0, size.width)
        ..setFloat(1, size.height)
        ..setFloat(2, scene.time)
        ..setFloat(3, scene.energy)
        ..setFloat(4, center);
      _rgb(s, 5, p.b);
      _rgb(s, 8, p.a);
      canvas.drawRect(rect, Paint()..shader = s);
      return;
    }
    // Painted: the same deep gradient and a glow at the light's height.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF08112A), Color(0xFF02040B)],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: Alignment(0, center * 2 - 1),
          radius: 0.9,
          colors: [
            p.b.withValues(alpha: 0.22 + scene.energy * 0.12),
            Colors.transparent,
          ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_SeaPainter old) => old.shader != shader || old.center != center;
}

// ── The light ──────────────────────────────────────────────────────────────

/// The drop of light, its glow and the rings it sends out. Its body is about
/// half of [size]; the rest is glow.
class VoiceOrb extends StatefulWidget {
  const VoiceOrb({super.key, required this.scene, this.size = 320, this.shaders = true});

  final CallScene scene;
  final double size;
  final bool shaders;

  @override
  State<VoiceOrb> createState() => _VoiceOrbState();
}

class _VoiceOrbState extends State<VoiceOrb> {
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    if (widget.shaders) {
      CallShaders.load().then((_) {
        if (mounted && CallShaders.orb != null) setState(() => _shader = CallShaders.orb!.fragmentShader());
      });
    }
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(painter: _OrbPainter(widget.scene, _shader)),
    ),
  );
}

class _OrbPainter extends CustomPainter {
  _OrbPainter(this.scene, this.shader) : super(repaint: scene);

  final CallScene scene;
  final ui.FragmentShader? shader;

  /// The body's radius at rest, as the shader draws it.
  double _radius(Size size) => size.shortestSide * 0.25 * (0.75 + 0.25 * scene.appear);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = _radius(size) * (1 + scene.level * 0.14);
    final p = scene.palette;
    // Rings first, under the light.
    for (final ripple in scene.ripples) {
      final age = ((scene.time - ripple.born) / _Ripple.life).clamp(0.0, 1.0);
      final eased = 1 - math.pow(1 - age, 3).toDouble();
      final radius = r * (1.04 + eased * 0.95);
      final alpha = math.pow(1 - age, 2).toDouble() * (0.25 + ripple.strength * 0.45) * scene.appear;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2 + (1 - age) * 1.6
          ..color = Color.lerp(p.a, Colors.white, 0.3)!.withValues(alpha: alpha),
      );
    }
    final s = shader;
    if (s != null) {
      s
        ..setFloat(0, size.width)
        ..setFloat(1, size.height)
        ..setFloat(2, scene.time)
        ..setFloat(3, scene.level)
        ..setFloat(4, scene.think)
        ..setFloat(5, scene.muted)
        ..setFloat(6, scene.appear);
      _rgb(s, 7, p.a);
      _rgb(s, 10, p.b);
      _rgb(s, 13, p.c);
      canvas.drawRect(Offset.zero & size, Paint()..shader = s);
      return;
    }
    _paintPlain(canvas, center, r, p);
  }

  /// Without shaders: the same drop drawn with gradients — a gently rippling
  /// edge, a lit body, a darker band inside a rim of shifting colour, a glint.
  void _paintPlain(Canvas canvas, Offset center, double r, CallPalette p) {
    final t = scene.time;
    final amp = 0.012 + scene.level * 0.07;
    final path = Path();
    const steps = 96;
    for (var i = 0; i <= steps; i++) {
      final a = i / steps * math.pi * 2;
      final k =
          1 +
          amp * (math.sin(2 * a + t * 0.9) * 0.55 + math.sin(3 * a - t * 1.3) * 0.3 + math.sin(5 * a + t * 1.7) * 0.15);
      final pt = center + Offset(math.cos(a), math.sin(a)) * r * k;
      i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
    }
    path.close();
    final appear = scene.appear;
    // The glow.
    final glowRect = Rect.fromCircle(center: center, radius: r * 2.1);
    canvas.drawCircle(
      center,
      r * 2.1,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Color.lerp(p.b, p.a, 0.5)!.withValues(alpha: (0.42 + scene.level * 0.35) * appear),
            Color.lerp(p.b, p.a, 0.5)!.withValues(alpha: 0.12 * appear),
            Colors.transparent,
          ],
          stops: const [0.35, 0.62, 1],
        ).createShader(glowRect),
    );
    final body = Rect.fromCircle(center: center, radius: r);
    canvas.save();
    canvas.clipPath(path);
    // Lit from the upper left; colour drifting across it.
    canvas.drawRect(
      body.inflate(r * 0.2),
      Paint()
        ..shader = RadialGradient(
          center: Alignment(-0.3 + math.sin(t * 0.4) * 0.15, -0.35 + math.cos(t * 0.33) * 0.15),
          radius: 1.15,
          colors: [Color.lerp(p.a, Colors.white, 0.3)!, p.a, p.b, p.c],
          stops: const [0, 0.32, 0.72, 1],
        ).createShader(body),
    );
    // The darker band inside the rim (glass).
    canvas.drawRect(
      body.inflate(r * 0.2),
      Paint()
        ..shader = const RadialGradient(
          colors: [Colors.transparent, Colors.transparent, Color(0x33000014), Colors.transparent],
          stops: [0, 0.66, 0.9, 1],
        ).createShader(body),
    );
    // A glint.
    canvas.drawCircle(
      center + Offset(-0.36 * r, -0.42 * r),
      r * 0.12,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.55 * appear)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.06),
    );
    canvas.restore();
    // The rim, its colour turning.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6 + scene.level * 1.4
        ..shader = SweepGradient(
          colors: [
            Color.lerp(p.a, Colors.white, 0.4)!,
            Color.lerp(p.c, Colors.white, 0.3)!,
            Color.lerp(p.a, Colors.white, 0.4)!,
          ],
          transform: GradientRotation(t * 0.9),
        ).createShader(body),
    );
    if (scene.think > 0.02) {
      final arc = Rect.fromCircle(center: center, radius: r * 1.1);
      canvas.drawArc(
        arc,
        t * 2.8,
        math.pi * 0.9,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 2.5
          ..shader = SweepGradient(
            colors: [
              Colors.transparent,
              Colors.white.withValues(alpha: 0.85 * scene.think),
            ],
            transform: GradientRotation(t * 2.8),
          ).createShader(arc),
      );
    }
  }

  @override
  bool shouldRepaint(_OrbPainter old) => old.shader != shader;
}

// ── Plankton ───────────────────────────────────────────────────────────────

/// Specks of light drifting up through the water, faster while someone speaks.
class Plankton extends StatefulWidget {
  const Plankton({super.key, required this.scene, this.count = 44});

  final CallScene scene;
  final int count;

  @override
  State<Plankton> createState() => _PlanktonState();
}

class _PlanktonState extends State<Plankton> {
  // Each speck's own progress, kept across rebuilds: a change of speed never makes them jump.
  final _drift = _Drift();

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(painter: _PlanktonPainter(widget.scene, widget.count, _drift), child: const SizedBox.expand()),
  );
}

class _Drift {
  final travel = <int, double>{};
  double last = 0;
}

class _PlanktonPainter extends CustomPainter {
  _PlanktonPainter(this.scene, this.count, this.drift) : super(repaint: scene);

  final CallScene scene;
  final int count;
  final _Drift drift;

  static double _rand(int i, int k) {
    final x = math.sin(i * 12.9898 + k * 78.233) * 43758.5453;
    return x - x.floorToDouble();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final dt = (scene.time - drift.last).clamp(0.0, 0.1);
    drift.last = scene.time;
    final speedUp = 1 + scene.energy * 2.2;
    final dot = Paint();
    for (var i = 0; i < count; i++) {
      final speed = 0.012 + _rand(i, 1) * 0.03;
      final travel = drift.travel[i] = (drift.travel[i] ?? _rand(i, 4)) + dt * speed * speedUp;
      final y = 1 - (travel % 1.0);
      final sway = math.sin(scene.time * (0.3 + _rand(i, 3) * 0.4) + i) * 14;
      final x = _rand(i, 2) * size.width + sway;
      final edge = math.min(1.0, math.min(y * 5, (1 - y) * 5));
      final twinkle = 0.5 + 0.5 * math.sin(scene.time * (1.2 + _rand(i, 5) * 2) + i * 1.7);
      final r = 0.6 + _rand(i, 6) * 1.6;
      final alpha = (0.12 + twinkle * 0.45) * edge * scene.appear;
      final color = Color.lerp(scene.palette.a, Colors.white, _rand(i, 7) * 0.6)!;
      final at = Offset(x, y * size.height);
      if (r > 1.6) {
        canvas.drawCircle(at, r * 3, dot..color = color.withValues(alpha: alpha * 0.18));
      }
      canvas.drawCircle(at, r, dot..color = color.withValues(alpha: alpha));
    }
  }

  @override
  bool shouldRepaint(_PlanktonPainter old) => old.count != count;
}

// ── The voice line ─────────────────────────────────────────────────────────

/// Three threads of light that swell with the voice, fading out at both ends.
class VoiceWave extends StatelessWidget {
  const VoiceWave({super.key, required this.scene, this.height = 64});

  final CallScene scene;
  final double height;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _WavePainter(scene)),
    ),
  );
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.scene) : super(repaint: scene);

  final CallScene scene;

  static const _threads = [(1.4, 1.3, 1.0, 2.2), (2.2, -1.7, 0.72, 1.6), (3.1, 2.3, 0.48, 1.2)];

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final mid = size.height / 2;
    final t = scene.time;
    final p = scene.palette;
    final colors = [p.a, p.c, Color.lerp(p.a, Colors.white, 0.5)!];
    final idle = 0.035 + scene.think * 0.05 * (0.5 + 0.5 * math.sin(t * 2.4));
    for (final (k, (freq, speed, scale, stroke)) in _threads.indexed) {
      final amp = mid * (idle + scene.level * 0.92) * scale * (0.85 + 0.15 * math.sin(t * 0.7 + k * 2));
      final path = Path();
      for (var x = 0.0; x <= w; x += 2) {
        final nx = x / w;
        final env = math.pow(math.sin(math.pi * nx), 2.2).toDouble();
        final y = mid + math.sin(nx * freq * math.pi * 2 + t * speed + k) * amp * env;
        x == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      final shader = LinearGradient(
        colors: [
          colors[k].withValues(alpha: 0),
          colors[k].withValues(alpha: (0.55 + scene.level * 0.4) * scene.appear),
          colors[k].withValues(alpha: 0),
        ],
      ).createShader(Offset.zero & size);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..blendMode = BlendMode.plus
          ..shader = shader,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => false;
}

/// Drives [scene] from a ticker for as long as it is mounted.
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
