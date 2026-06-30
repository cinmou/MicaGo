import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:provider/provider.dart';

import '../theme_controller.dart';

bool isGlassTheme(BuildContext context) =>
    context.watch<ThemeController>().useLiquidGlass;

const Color liquidGlassBlue = Color(0xFF007AFF);

LiquidGlassSettings micaGlassSettings(Color color, {double blur = 9}) =>
    LiquidGlassSettings(
      glassColor: color,
      backerColor: color.withValues(alpha: 0.42),
      blur: blur,
      thickness: 28,
      refractiveIndex: 1.18,
      chromaticAberration: 0.012,
      saturation: 1.35,
      lightIntensity: 0.58,
      standardOpacityMultiplier: 1.0,
    );

class MicaGlassIconButton extends StatelessWidget {
  final String? tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final Color? color;
  final Color? iconColor;
  final double size;

  const MicaGlassIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.color,
    this.iconColor,
    this.size = 44,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!isGlassTheme(context)) {
      return IconButton(
        tooltip: tooltip,
        icon: Icon(icon),
        onPressed: onPressed,
      );
    }
    final bg = color ?? Colors.white.withValues(alpha: 0.58);
    return SizedBox(
      width: size,
      height: size,
      child: GlassContainer(
        useOwnLayer: true,
        quality: GlassQuality.standard,
        settings: micaGlassSettings(bg, blur: 10),
        shape: const LiquidOval(),
        child: IconButton(
          tooltip: tooltip,
          icon: Icon(icon),
          color: iconColor ?? scheme.onSurface,
          onPressed: onPressed,
        ),
      ),
    );
  }
}

class MicaGlassShell extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double radius;
  final Color? color;
  final bool enabled;

  const MicaGlassShell({
    super.key,
    required this.child,
    this.padding,
    this.radius = 24,
    this.color,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    if (!enabled || !isGlassTheme(context)) return child;
    final bg = color ?? Colors.white.withValues(alpha: 0.56);
    return GlassContainer(
      useOwnLayer: true,
      quality: GlassQuality.standard,
      settings: micaGlassSettings(bg, blur: 10),
      shape: LiquidRoundedSuperellipse(borderRadius: radius),
      padding: padding,
      child: child,
    );
  }
}
