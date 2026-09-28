import 'package:flutter/material.dart';
import '../../theme/colors.dart';
import '../motion.dart';
import '../../theme/text_styles.dart';

/// OfflineBanner — persistent top strip shown when connectivity drops.
/// Never blocks interaction — informational only. Grows with text size and
/// is a live region, so screen readers announce the change.
class OfflineBanner extends StatelessWidget {
  final bool isOffline;

  const OfflineBanner({super.key, required this.isOffline});

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: motion(context, const Duration(milliseconds: 250)),
      alignment: Alignment.topCenter,
      child: isOffline
          ? Semantics(
              liveRegion: true,
              child: Container(
                width: double.infinity,
                color: AppColors.saffron600.withOpacity(0.15),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.wifi_off_outlined,
                      size: 14,
                      color: AppColors.saffronDark,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        "You're offline. Reports will send when you're back online.",
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.saffronDark,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : const SizedBox(width: double.infinity),
    );
  }
}
