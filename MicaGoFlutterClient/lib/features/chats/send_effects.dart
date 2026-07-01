import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'message_render.dart';

/// Drives full-screen ("screen") send effects — fireworks, balloons, love,
/// lasers, celebration, spotlight, echo — played over the whole thread, the way
/// BlueBubbles / Messages do. Confetti stays on the `confetti` package; the rest
/// are self-contained CustomPainter particle systems here.
///
/// A thread owns one [SendEffectController] and hosts one [SendEffectOverlay] at
/// the top of its stack; tapping a message's "Sent with …" label calls [play].
class SendEffectController extends ChangeNotifier {
  MessageSendEffect _effect = MessageSendEffect.none;
  int _token = 0;

  MessageSendEffect get effect => _effect;
  int get token => _token;

  void play(MessageSendEffect effect) {
    if (!isScreenSendEffect(effect) || effect == MessageSendEffect.confetti) {
      return;
    }
    _effect = effect;
    _token++;
    notifyListeners();
  }
}

class SendEffectOverlay extends StatefulWidget {
  final SendEffectController controller;
  const SendEffectOverlay({super.key, required this.controller});

  @override
  State<SendEffectOverlay> createState() => _SendEffectOverlayState();
}

class _SendEffectOverlayState extends State<SendEffectOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        setState(() => _effect = MessageSendEffect.none);
      }
    });
  MessageSendEffect _effect = MessageSendEffect.none;
  int _seenToken = 0;
  List<_Fx> _particles = const [];

  static const _durations = {
    MessageSendEffect.fireworks: Duration(milliseconds: 1900),
    MessageSendEffect.balloons: Duration(milliseconds: 2700),
    MessageSendEffect.love: Duration(milliseconds: 1700),
    MessageSendEffect.lasers: Duration(milliseconds: 1700),
    MessageSendEffect.celebration: Duration(milliseconds: 2100),
    MessageSendEffect.spotlight: Duration(milliseconds: 1800),
    MessageSendEffect.echo: Duration(milliseconds: 1500),
  };

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onController);
  }

  void _onController() {
    final c = widget.controller;
    if (c.token == _seenToken) return;
    _seenToken = c.token;
    final duration = _durations[c.effect];
    if (duration == null) return;
    setState(() {
      _effect = c.effect;
      _particles = _buildParticles(c.effect, math.Random(c.token * 7919 + 13));
    });
    _anim
      ..duration = duration
      ..forward(from: 0);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_effect == MessageSendEffect.none) return const SizedBox.shrink();
    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _anim,
          builder: (context, _) => CustomPaint(
            painter: _ScreenEffectPainter(
              effect: _effect,
              t: _anim.value,
              particles: _particles,
            ),
            size: Size.infinite,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Particle model + per-effect generation
// ---------------------------------------------------------------------------

class _Fx {
  final double x; // normalized start 0..1
  final double y;
  final double angle; // radians (radial effects) / sway factor
  final double speed; // normalized
  final double size;
  final double phase; // 0..1 stagger/delay or twinkle offset
  final Color color;
  const _Fx({
    required this.x,
    required this.y,
    required this.angle,
    required this.speed,
    required this.size,
    required this.phase,
    required this.color,
  });
}

const _brightPalette = [
  Color(0xFFFF3B30),
  Color(0xFFFF9500),
  Color(0xFFFFCC00),
  Color(0xFF34C759),
  Color(0xFF00C7BE),
  Color(0xFF0A84FF),
  Color(0xFFBF5AF2),
  Color(0xFFFF2D55),
];
const _laserPalette = [
  Color(0xFFFF2D55),
  Color(0xFF0A84FF),
  Color(0xFF34C759),
  Color(0xFFFFCC00),
  Color(0xFFBF5AF2),
];

List<_Fx> _buildParticles(MessageSendEffect effect, math.Random r) {
  Color pick(List<Color> p) => p[r.nextInt(p.length)];
  switch (effect) {
    case MessageSendEffect.fireworks:
      final out = <_Fx>[];
      const bursts = 5;
      for (var b = 0; b < bursts; b++) {
        final ox = 0.15 + r.nextDouble() * 0.7;
        final oy = 0.12 + r.nextDouble() * 0.45;
        final delay = (b / bursts) * 0.55;
        final color = pick(_brightPalette);
        final count = 32 + r.nextInt(12);
        for (var i = 0; i < count; i++) {
          final ang = (i / count) * math.pi * 2 + r.nextDouble() * 0.2;
          out.add(_Fx(
            x: ox,
            y: oy,
            angle: ang,
            speed: 0.09 + r.nextDouble() * 0.09,
            size: 2 + r.nextDouble() * 2.2,
            phase: delay,
            color: color,
          ));
        }
      }
      return out;
    case MessageSendEffect.balloons:
      return List.generate(16, (_) {
        return _Fx(
          x: r.nextDouble(),
          y: 0,
          angle: (r.nextDouble() - 0.5) * 2, // sway direction/strength
          speed: 0.7 + r.nextDouble() * 0.55,
          size: 26 + r.nextDouble() * 22,
          phase: r.nextDouble() * 0.5,
          color: pick(_brightPalette),
        );
      });
    case MessageSendEffect.love:
      return List.generate(11, (i) {
        final big = i == 0;
        return _Fx(
          x: big ? 0.5 : 0.15 + r.nextDouble() * 0.7,
          y: big ? 0.5 : 0,
          angle: (r.nextDouble() - 0.5) * 2,
          speed: 0.55 + r.nextDouble() * 0.5,
          size: big ? 150 : 18 + r.nextDouble() * 22,
          phase: big ? 0 : 0.1 + r.nextDouble() * 0.5,
          color: big ? const Color(0xFFFF2D55) : const Color(0xFFFF375F),
        );
      });
    case MessageSendEffect.celebration:
      return List.generate(64, (_) {
        return _Fx(
          x: r.nextDouble(),
          y: r.nextDouble(),
          angle: r.nextDouble() * math.pi,
          speed: 0.15 + r.nextDouble() * 0.3,
          size: 3 + r.nextDouble() * 5,
          phase: r.nextDouble(),
          color: pick(_brightPalette),
        );
      });
    case MessageSendEffect.lasers:
      return List.generate(10, (_) {
        return _Fx(
          x: 0,
          y: 0.12 + r.nextDouble() * 0.76,
          angle: (r.nextDouble() - 0.5) * 0.12, // slight slope
          speed: 0.8 + r.nextDouble() * 0.7,
          size: 2 + r.nextDouble() * 3,
          phase: r.nextDouble() * 0.45,
          color: pick(_laserPalette),
        );
      });
    case MessageSendEffect.spotlight:
      return [
        _Fx(
          x: 0.28 + r.nextDouble() * 0.44,
          y: 0.24 + r.nextDouble() * 0.4,
          angle: 0,
          speed: 1,
          size: 150 + r.nextDouble() * 40,
          phase: 0,
          color: Colors.black,
        ),
      ];
    case MessageSendEffect.echo:
      return List.generate(6, (i) {
        return _Fx(
          x: 0.5,
          y: 0.5,
          angle: 0,
          speed: 1,
          size: 1,
          phase: i / 6 * 0.6,
          color: const Color(0xFFFFFFFF),
        );
      });
    default:
      return const [];
  }
}

// ---------------------------------------------------------------------------
// Painter
// ---------------------------------------------------------------------------

class _ScreenEffectPainter extends CustomPainter {
  final MessageSendEffect effect;
  final double t;
  final List<_Fx> particles;

  _ScreenEffectPainter({
    required this.effect,
    required this.t,
    required this.particles,
  });

  @override
  void paint(Canvas canvas, Size size) {
    switch (effect) {
      case MessageSendEffect.fireworks:
        _fireworks(canvas, size);
      case MessageSendEffect.balloons:
        _balloons(canvas, size);
      case MessageSendEffect.love:
        _love(canvas, size);
      case MessageSendEffect.celebration:
        _celebration(canvas, size);
      case MessageSendEffect.lasers:
        _lasers(canvas, size);
      case MessageSendEffect.spotlight:
        _spotlight(canvas, size);
      case MessageSendEffect.echo:
        _echo(canvas, size);
      default:
        break;
    }
  }

  double _local(double phase) {
    if (phase >= 1) return 0;
    return ((t - phase) / (1 - phase)).clamp(0.0, 1.0);
  }

  void _fireworks(Canvas canvas, Size size) {
    final reach = size.shortestSide * 1.4;
    final paint = Paint();
    for (final p in particles) {
      final lt = _local(p.phase);
      if (lt <= 0) continue;
      final dist = p.speed * lt * reach;
      final gravity = 0.6 * lt * lt * size.height * 0.35;
      final cx = p.x * size.width + math.cos(p.angle) * dist;
      final cy = p.y * size.height + math.sin(p.angle) * dist + gravity;
      final op = (1 - lt) * (1 - lt);
      paint.color = p.color.withValues(alpha: op);
      canvas.drawCircle(Offset(cx, cy), p.size * (1 - 0.4 * lt), paint);
    }
  }

  void _balloons(Canvas canvas, Size size) {
    for (final p in particles) {
      final lt = _local(p.phase);
      if (lt <= 0) continue;
      final travel = size.height * 1.25 * p.speed;
      final cy = size.height + p.size - lt * travel;
      final cx = p.x * size.width + math.sin(lt * math.pi * 2 + p.phase * 6) * 16 * p.angle;
      final fade = lt > 0.85 ? (1 - (lt - 0.85) / 0.15) : 1.0;
      final w = p.size, h = p.size * 1.25;
      final body = Paint()..color = p.color.withValues(alpha: 0.92 * fade);
      // String.
      canvas.drawLine(
        Offset(cx, cy + h * 0.5),
        Offset(cx, cy + h * 0.5 + p.size * 0.9),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.4 * fade)
          ..strokeWidth = 1,
      );
      canvas.drawOval(
        Rect.fromCenter(center: Offset(cx, cy), width: w, height: h),
        body,
      );
      // Highlight.
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(cx - w * 0.2, cy - h * 0.22),
          width: w * 0.28,
          height: h * 0.34,
        ),
        Paint()..color = Colors.white.withValues(alpha: 0.35 * fade),
      );
    }
  }

  void _love(Canvas canvas, Size size) {
    for (final p in particles) {
      final lt = _local(p.phase);
      if (lt <= 0) continue;
      final paint = Paint()..color = p.color;
      if (p.size > 100) {
        // The hero heart: pops in with an overshoot, holds, then fades.
        final grow = Curves.easeOutBack.transform((lt / 0.4).clamp(0.0, 1.0));
        final fade = lt > 0.7 ? (1 - (lt - 0.7) / 0.3) : 1.0;
        final s = p.size * (0.2 + 0.8 * grow);
        paint.color = p.color.withValues(alpha: fade);
        _drawHeart(canvas, Offset(size.width * 0.5, size.height * 0.42), s, paint);
      } else {
        // Small hearts drift up and fade.
        final cy = size.height * 0.9 - lt * size.height * 0.8 * p.speed;
        final cx = p.x * size.width + math.sin(lt * math.pi * 2 + p.phase * 6) * 18 * p.angle;
        paint.color = p.color.withValues(alpha: (1 - lt) * 0.9);
        _drawHeart(canvas, Offset(cx, cy), p.size, paint);
      }
    }
  }

  void _celebration(Canvas canvas, Size size) {
    for (final p in particles) {
      // Continuous twinkle, gated by a per-particle appearance window.
      final appear = ((t - p.phase * 0.5) / 0.2).clamp(0.0, 1.0);
      final disappear = t > 0.8 ? (1 - (t - 0.8) / 0.2) : 1.0;
      final twinkle = 0.4 + 0.6 * (0.5 + 0.5 * math.sin(t * math.pi * 6 * p.speed + p.phase * 6));
      final op = (appear * disappear * twinkle).clamp(0.0, 1.0);
      if (op <= 0) continue;
      final cx = p.x * size.width;
      final cy = p.y * size.height - t * 20;
      _drawSparkle(canvas, Offset(cx, cy), p.size * (0.6 + 0.4 * twinkle),
          p.color.withValues(alpha: op));
    }
  }

  void _lasers(Canvas canvas, Size size) {
    // Retro neon: a faint dark wash + sweeping colored beams with glow.
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Colors.black.withValues(alpha: 0.12 * _pulse(t)),
    );
    for (final p in particles) {
      final lt = _local(p.phase);
      if (lt <= 0) continue;
      final leftToRight = p.color.toARGB32().isEven;
      final headX = (leftToRight ? lt : 1 - lt) * size.width;
      final y = p.y * size.height + math.sin(t * math.pi * 4) * 4;
      final y2 = y + p.angle * size.width;
      final glow = Paint()
        ..color = p.color.withValues(alpha: 0.85 * (1 - lt * 0.3))
        ..strokeWidth = p.size
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
      final tailX = headX - (leftToRight ? 1 : -1) * size.width * 0.5;
      canvas.drawLine(Offset(tailX, y2), Offset(headX, y), glow);
      canvas.drawLine(
        Offset(tailX, y2),
        Offset(headX, y),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.9 * (1 - lt * 0.3))
          ..strokeWidth = p.size * 0.4
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  void _spotlight(Canvas canvas, Size size) {
    final dim = math.sin(t * math.pi); // 0→1→0
    final p = particles.first;
    // Spotlight sweeps in from the side to the target, then back out.
    final targetX = p.x * size.width;
    final targetY = p.y * size.height;
    final sweep = Curves.easeInOut.transform((t * 1.6).clamp(0.0, 1.0));
    final cx = size.width * (0.5 - 0.5 * (1 - sweep)) + targetX * sweep - size.width * 0.5 * (1 - sweep);
    final center = Offset(cx.clamp(0.0, size.width), targetY);
    final radius = p.size + 40;
    final shader = RadialGradient(
      colors: [Colors.transparent, Colors.black.withValues(alpha: 0.6 * dim)],
      stops: const [0.62, 1.0],
    ).createShader(Rect.fromCircle(center: center, radius: radius * 2.2));
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  void _echo(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.5, size.height * 0.5);
    for (final p in particles) {
      final lt = _local(p.phase);
      if (lt <= 0) continue;
      final radius = lt * size.shortestSide * 0.7;
      final op = (1 - lt) * 0.5;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = p.color.withValues(alpha: op),
      );
    }
  }

  double _pulse(double v) => 0.5 + 0.5 * math.sin(v * math.pi * 8);

  void _drawHeart(Canvas canvas, Offset c, double s, Paint paint) {
    final path = Path();
    final w = s, h = s;
    path.moveTo(c.dx, c.dy + h * 0.35);
    path.cubicTo(
      c.dx + w * 0.5, c.dy - h * 0.05, //
      c.dx + w * 0.42, c.dy - h * 0.5,
      c.dx, c.dy - h * 0.18,
    );
    path.cubicTo(
      c.dx - w * 0.42, c.dy - h * 0.5, //
      c.dx - w * 0.5, c.dy - h * 0.05,
      c.dx, c.dy + h * 0.35,
    );
    canvas.drawPath(path, paint);
  }

  void _drawSparkle(Canvas canvas, Offset c, double s, Color color) {
    final paint = Paint()..color = color;
    final path = Path();
    // 4-point sparkle.
    path.moveTo(c.dx, c.dy - s);
    path.quadraticBezierTo(c.dx, c.dy, c.dx + s, c.dy);
    path.quadraticBezierTo(c.dx, c.dy, c.dx, c.dy + s);
    path.quadraticBezierTo(c.dx, c.dy, c.dx - s, c.dy);
    path.quadraticBezierTo(c.dx, c.dy, c.dx, c.dy - s);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _ScreenEffectPainter old) =>
      old.t != t || old.effect != effect || old.particles != particles;
}
