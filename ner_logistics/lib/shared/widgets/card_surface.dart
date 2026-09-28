import 'package:flutter/material.dart';
import '../../theme/colors.dart';

/// CardSurface — flat white card with 1px hairline border.
/// No elevation, no shadow — matches the government-document visual register.
class CardSurface extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final Color? borderColor;
  final double radius;
  final Color? backgroundColor;
  // Optional left accent bar (used for escalated incidents)
  final Color? leftAccentColor;

  const CardSurface({
    super.key,
    required this.child,
    this.padding,
    this.onTap,
    this.borderColor,
    this.radius = 6,
    this.backgroundColor,
    this.leftAccentColor,
  });

  @override
  Widget build(BuildContext context) {
    final content = Stack(
        children: [
          if (leftAccentColor != null)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 3,
              child: ColoredBox(color: leftAccentColor!),
            ),
          if (padding != null)
            Padding(padding: padding!, child: child)
          else
            child,
        ],
      );

    if (onTap != null) {
      // Paint the card on the Material itself so the ink press state is
      // visible (an opaque Container above the ink would hide it).
      return Semantics(
        button: true,
        child: Material(
          color: backgroundColor ?? AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
            side: BorderSide(color: borderColor ?? AppColors.hairline),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            splashColor: AppColors.navy900.withOpacity(0.08),
            highlightColor: AppColors.navy900.withOpacity(0.06),
            child: content,
          ),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: backgroundColor ?? AppColors.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor ?? AppColors.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: content,
    );
  }
}
