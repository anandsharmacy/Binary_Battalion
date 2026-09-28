import 'package:flutter/widgets.dart';

/// [d], or zero when the person has turned on Reduce Motion (HIG motion.md:
/// "Make motion optional").
Duration motion(BuildContext c, Duration d) =>
    MediaQuery.disableAnimationsOf(c) ? Duration.zero : d;

/// Short cross-fade between top-level screens, keyed by [id]; instant with
/// Reduce Motion (HIG motion.md: brief, precise feedback).
Widget screenFade(BuildContext c, Object id, Widget child) => AnimatedSwitcher(
      duration: motion(c, const Duration(milliseconds: 200)),
      layoutBuilder: (current, previous) => Stack(
        fit: StackFit.expand,
        children: [...previous, ?current],
      ),
      child: KeyedSubtree(key: ValueKey(id), child: child),
    );
