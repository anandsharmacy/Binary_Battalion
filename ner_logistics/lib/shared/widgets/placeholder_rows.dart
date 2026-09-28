import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';
import '../../theme/colors.dart';

/// Loading placeholder: [count] grey rows shaped like the list rows they stand
/// in for (HIG loading.md: "Show something as soon as possible"). The shimmer
/// is dropped when Reduce Motion is on.
class PlaceholderRows extends StatelessWidget {
  final int count;
  final double height;
  const PlaceholderRows({super.key, this.count = 3, this.height = 64});

  @override
  Widget build(BuildContext context) {
    final rows = Semantics(
      container: true,
      label: 'Loading',
      child: Column(children: [
        for (var i = 0; i < count; i++)
          Container(
            height: height,
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: AppColors.hairline,
              borderRadius: BorderRadius.circular(6),
            ),
          ),
      ]),
    );
    if (MediaQuery.disableAnimationsOf(context)) return rows;
    return Shimmer.fromColors(
      baseColor: AppColors.hairline,
      highlightColor: AppColors.surface,
      child: rows,
    );
  }
}
