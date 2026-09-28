import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../theme/colors.dart';

/// Platform alert for a destructive choice (HIG alerts: "Cancel" plus a
/// destructive action, never a bare "OK"). Returns true when confirmed.
Future<bool> confirmDestructive(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
}) async {
  final platform = Theme.of(context).platform;
  final cupertino =
      platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
  Widget action(String label, bool result, {bool destructive = false}) =>
      Builder(
        builder: (ctx) => cupertino
            ? CupertinoDialogAction(
                isDestructiveAction: destructive,
                onPressed: () => Navigator.of(ctx).pop(result),
                child: Text(label),
              )
            : TextButton(
                style: destructive
                    ? TextButton.styleFrom(
                        foregroundColor: AppColors.signalRed700)
                    : null,
                onPressed: () => Navigator.of(ctx).pop(result),
                child: Text(label),
              ),
      );

  final ok = await showAdaptiveDialog<bool>(
    context: context,
    builder: (_) => AlertDialog.adaptive(
      title: Text(title),
      content: Text(message),
      actions: [
        action(cancelLabel, false),
        action(confirmLabel, true, destructive: true),
      ],
    ),
  );
  return ok ?? false;
}

/// Asks before signing out only when something would be left unsent
/// (HIG feedback: warn only when people could lose data).
Future<bool> confirmSignOut(BuildContext context, int unsent) async {
  if (unsent == 0) return true;
  return confirmDestructive(
    context,
    title: 'Sign out with unsent data?',
    message: unsent == 1
        ? "1 item hasn't been sent yet. If you sign out now it may not be sent."
        : "$unsent items haven't been sent yet. If you sign out now they may not be sent.",
    confirmLabel: 'Sign Out',
  );
}
