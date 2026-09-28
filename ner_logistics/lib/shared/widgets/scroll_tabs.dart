import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';

/// ScrollTabs — horizontal pill-style scroll tab bar.
/// Used in district officer incident/route screens.
class ScrollTabs<T> extends StatelessWidget {
  final List<ScrollTab<T>> tabs;
  final T active;
  final ValueChanged<T> onChange;

  const ScrollTabs({
    super.key,
    required this.tabs,
    required this.active,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    // No fixed height: chips grow with the text size, 44pt minimum target.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            _chip(tabs[i], tabs[i].id == active),
          ],
        ],
      ),
    );
  }

  Widget _chip(ScrollTab<T> tab, bool on) {
    void select() {
      HapticFeedback.selectionClick();
      onChange(tab.id);
    }

    return Semantics(
      button: true,
      selected: on,
      label: tab.count == null ? tab.label : '${tab.label}, ${tab.count}',
      onTap: select,
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            color: on ? AppColors.navy900 : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: on ? AppColors.navy900 : AppColors.hairline,
            ),
          ),
          child: InkWell(
            onTap: select,
            borderRadius: BorderRadius.circular(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tab.label,
                      style: AppTextStyles.tabLabel.copyWith(
                        color: on ? Colors.white : AppColors.slate500,
                      ),
                    ),
                    if (tab.count != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        '${tab.count}',
                        style: AppTextStyles.caption.copyWith(
                          color: on ? Colors.white70 : AppColors.slate500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ScrollTab<T> {
  final T id;
  final String label;
  final int? count;
  const ScrollTab({required this.id, required this.label, this.count});
}
