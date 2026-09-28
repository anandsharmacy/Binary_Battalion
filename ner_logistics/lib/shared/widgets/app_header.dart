import 'package:flutter/material.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';

/// AppHeader — navy chrome top bar used across all three role tracks.
/// Mirrors the React FieldHeader / DistrictOfficerApp / ControlRoomApp top bar.
///
/// Layout: menu button · title + subtitle · bell (with badge) · role avatar.
/// The real OS status bar sits above it (SafeArea); no drawn status row.
class AppHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final String roleInitials;
  final Color roleAccent;
  final int alertCount;
  final VoidCallback onMenu;
  final VoidCallback onBell;
  final VoidCallback onAvatar;

  const AppHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.roleInitials,
    this.roleAccent = AppColors.gold,
    this.alertCount = 0,
    required this.onMenu,
    required this.onBell,
    required this.onAvatar,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.navy900,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Row(
            children: [
              _HeaderButton(
                label: 'Menu',
                onTap: onMenu,
                child: const Icon(Icons.menu, size: 24),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // A heading, so VoiceOver's heading rotor lands on it.
                    Semantics(
                      header: true,
                      child: Text(
                        title,
                        style: AppTextStyles.screenTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: AppTextStyles.caption.copyWith(
                        color: Colors.white70,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              _HeaderButton(
                label: alertCount > 0 ? 'Alerts, $alertCount new' : 'Alerts',
                onTap: onBell,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Icon(Icons.notifications_outlined, size: 21),
                    if (alertCount > 0)
                      Positioned(
                        right: -4,
                        top: -4,
                        child: Container(
                          height: 17,
                          constraints: const BoxConstraints(minWidth: 17),
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          decoration: BoxDecoration(
                            color: AppColors.gold,
                            borderRadius: BorderRadius.circular(9),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '$alertCount',
                            style: AppTextStyles.eyebrow.copyWith(
                              color: AppColors.navy900,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // Role avatar: 36px visual inside a 48px hit target.
              _HeaderButton(
                label: 'Profile and settings',
                onTap: onAvatar,
                circle: true,
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: roleAccent,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    roleInitials,
                    style: AppTextStyles.eyebrowMd.copyWith(
                      color: AppColors.navy900,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final Widget child;
  final bool circle;
  const _HeaderButton({
    required this.label,
    required this.onTap,
    required this.child,
    this.circle = false,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            customBorder: circle
                ? const CircleBorder()
                : RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            splashColor: Colors.white24,
            highlightColor: Colors.white12,
            child: SizedBox.square(
              dimension: kMinInteractiveDimension,
              child: Center(
                child: IconTheme(
                  data: const IconThemeData(color: Colors.white, size: 22),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
