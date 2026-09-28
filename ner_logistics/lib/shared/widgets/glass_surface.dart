import 'dart:ui';

import 'package:flutter/material.dart';

import '../../theme/colors.dart';

/// Apple-style Liquid Glass material: `ClipRRect` → `BackdropFilter(blur)` →
/// tinted fill → [child] (HIG materials.md: Liquid Glass "allow[s] you to
/// present controls and navigation without obscuring underlying content").
///
/// Reserved for floating chrome over scrollable/map content — sheets,
/// drawers, overlay badges/controls — never static cards or content.
///
/// Falls back to a fully opaque fill with no `BackdropFilter` in the tree
/// when the person has Increase Contrast on (`MediaQuery.highContrastOf`),
/// mirroring the Reduce Motion gate in `shared/motion.dart`.
class GlassSurface extends StatelessWidget {
  final Widget child;
  final Color tint;
  final double alpha;
  final double blurSigma;
  final BorderRadius borderRadius;

  const GlassSurface({
    super.key,
    required this.child,
    this.tint = AppColors.cardSurface,
    this.alpha = AppColors.glassAlpha,
    this.blurSigma = AppColors.glassBlurSigma,
    this.borderRadius = BorderRadius.zero,
  });

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.highContrastOf(context)) {
      return ClipRRect(
        borderRadius: borderRadius,
        child: ColoredBox(color: tint, child: child),
      );
    }
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: ColoredBox(
          color: tint.withValues(alpha: alpha),
          child: child,
        ),
      ),
    );
  }
}
