import 'package:flutter/material.dart';

/// NerToggle — platform switch (Cupertino look on iOS, Material elsewhere).
/// Colours come from `switchTheme` in AppTheme; the adaptive switch brings
/// switch semantics, a 48px hit area and the platform haptic.
class NerToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const NerToggle({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) =>
      Switch.adaptive(value: value, onChanged: onChanged);
}
