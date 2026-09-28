import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../../../mock_data/models.dart';
import '../../alerts/alerts_repository.dart';
import '../../../shared/widgets/widgets.dart';
import '../../../theme/colors.dart';
import '../../../theme/text_styles.dart';

class AlertsScreen extends ConsumerStatefulWidget {
  final VoidCallback? onCriticalTap;
  final VoidCallback? onAlertsCleared;
  /// Fixture alerts for tests (acknowledged locally). Null = live public.alerts.
  final List<AppAlert>? alerts;

  const AlertsScreen({
    super.key,
    this.onCriticalTap,
    this.onAlertsCleared,
    this.alerts,
  });

  @override
  ConsumerState<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends ConsumerState<AlertsScreen> {
  AlertSeverity _tab = AlertSeverity.critical;
  /// Fixture alerts acknowledged in this session (tests only; live alerts use the RPC).
  final Set<String> _acked = {};
  List<AppAlert> _live = const [];
  final Set<String> _busy = {};

  List<AppAlert> get _alerts =>
      (widget.alerts ?? _live).where((a) => a.status != 'resolved').toList();

  bool _isAcked(AppAlert a) => _acked.contains(a.id) || a.status == 'acknowledged';

  List<AppAlert> get _filtered =>
      _alerts.where((a) => a.severity == _tab).toList();

  Future<void> _acknowledge(String id) async {
    HapticFeedback.lightImpact();
    if (widget.alerts != null) {
      setState(() => _acked.add(id));
      return;
    }
    setState(() => _busy.add(id));
    try {
      await setAlertStatus(ref.read(supabaseClientProvider), id, 'acknowledged');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text('Could not acknowledge: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  static const _tabs = [
    (AlertSeverity.critical,  'Critical'),
    (AlertSeverity.high,      'High'),
    (AlertSeverity.moderate,  'Moderate'),
    (AlertSeverity.info,      'Info'),
  ];

  int _tabCount(AlertSeverity s) =>
      _alerts.where((a) => a.severity == s).length;

  Color _tabBadgeColor(AlertSeverity s) {
    switch (s) {
      case AlertSeverity.critical: return AppColors.signalRed700;
      case AlertSeverity.high:     return AppColors.saffron600;
      case AlertSeverity.moderate: return AppColors.navy900;
      case AlertSeverity.info:     return AppColors.slate500;
    }
  }

  @override
  Widget build(BuildContext context) {
    final live = widget.alerts == null ? ref.watch(alertsStreamProvider) : null;
    _live = live?.valueOrNull ?? const [];
    return Column(
      children: [
        // Tab bar. A white Material (not a Container) so tab ink shows.
        Material(
          color: Colors.white,
          child: Column(
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: _tabs.map((t) {
                    final active = _tab == t.$1;
                    final count = _tabCount(t.$1);
                    return Semantics(
                      button: true,
                      selected: active,
                      label: count > 0 ? '${t.$2}, $count' : t.$2,
                      excludeSemantics: true,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _tab = t.$1);
                      },
                      child: InkWell(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          setState(() => _tab = t.$1);
                        },
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 44),
                          child: Container(
                        padding: const EdgeInsets.fromLTRB(
                            12, 10, 12, 10),
                        margin: const EdgeInsets.only(right: 4),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: active
                                  ? AppColors.navy900
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Text(
                              t.$2,
                              style: AppTextStyles.tabLabel.copyWith(
                                color: active
                                    ? AppColors.navy900
                                    : AppColors.slate500,
                                fontWeight: active
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                            if (count > 0) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: _tabBadgeColor(t.$1)
                                      .withOpacity(
                                          active ? 1 : 0.15),
                                  borderRadius:
                                      BorderRadius.circular(8),
                                ),
                                child: Text(
                                  '$count',
                                  style: AppTextStyles.eyebrow
                                      .copyWith(
                                    color: active
                                        ? Colors.white
                                        : _tabBadgeColor(t.$1),
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              Divider(color: AppColors.hairline, height: 1),
            ],
          ),
        ),
        // Alert list
        Expanded(
          child: live != null && live.isLoading && !live.hasValue
              ? const Center(child: CircularProgressIndicator())
              : _filtered.isEmpty
              ? EmptyState(
                  icon: Icons.notifications_outlined,
                  title: live?.hasError == true && !live!.hasValue
                      ? 'Alerts unavailable'
                      : 'No ${_tabs.firstWhere((t) => t.$1 == _tab).$2} alerts',
                  message: live?.hasError == true && !live!.hasValue
                      ? 'Could not reach the alert service. Check your connection.'
                      : 'All clear in this category',
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _filtered.length + 1,
                  separatorBuilder: (_, __) =>
                      const SizedBox(height: 12),
                  itemBuilder: (_, i) {
                    if (i == _filtered.length) {
                      return Padding(
                        padding:
                            const EdgeInsets.only(top: 4, bottom: 8),
                        child: Text(
                          '${_tabCount(AlertSeverity.critical)} critical · ${_tabCount(AlertSeverity.high)} high',
                          style: AppTextStyles.caption,
                          textAlign: TextAlign.center,
                        ),
                      );
                    }
                    return _AlertCard(
                      alert: _filtered[i],
                      acked: _isAcked(_filtered[i]),
                      local: widget.alerts != null,
                      busy: _busy.contains(_filtered[i].id),
                      onAcknowledge: () =>
                          _acknowledge(_filtered[i].id),
                      onViewIncident:
                          _filtered[i].severity ==
                                  AlertSeverity.critical
                              ? widget.onCriticalTap
                              : null,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _AlertCard extends StatelessWidget {
  final AppAlert alert;
  final bool acked;
  final bool local;
  final bool busy;
  final VoidCallback onAcknowledge;
  final VoidCallback? onViewIncident;

  const _AlertCard({
    required this.alert,
    required this.acked,
    required this.local,
    required this.busy,
    required this.onAcknowledge,
    this.onViewIncident,
  });

  Color get _borderColor {
    switch (alert.severity) {
      case AlertSeverity.critical: return AppColors.signalRed700.withOpacity(0.4);
      case AlertSeverity.high:     return AppColors.saffron600.withOpacity(0.4);
      case AlertSeverity.moderate: return AppColors.navy900.withOpacity(0.2);
      case AlertSeverity.info:     return AppColors.hairline;
    }
  }

  Color get _bgColor {
    switch (alert.severity) {
      case AlertSeverity.critical: return AppColors.signalRed700.withOpacity(0.05);
      case AlertSeverity.high:     return AppColors.saffron600.withOpacity(0.05);
      case AlertSeverity.moderate: return AppColors.navy900.withOpacity(0.03);
      case AlertSeverity.info:     return const Color(0xFFF0F1EC);
    }
  }

  Color get _iconColor {
    switch (alert.severity) {
      case AlertSeverity.critical: return AppColors.signalRed700;
      case AlertSeverity.high:     return AppColors.saffron600;
      case AlertSeverity.moderate: return AppColors.navy900;
      case AlertSeverity.info:     return AppColors.slate500;
    }
  }

  String get _severityLabel {
    switch (alert.severity) {
      case AlertSeverity.critical: return 'CRITICAL';
      case AlertSeverity.high:     return 'HIGH';
      case AlertSeverity.moderate: return 'MODERATE';
      case AlertSeverity.info:     return 'INFO';
    }
  }

  Color get _badgeBg {
    switch (alert.severity) {
      case AlertSeverity.critical: return AppColors.signalRed700;
      case AlertSeverity.high:     return AppColors.saffron600;
      case AlertSeverity.moderate: return AppColors.navy900.withOpacity(0.1);
      case AlertSeverity.info:     return AppColors.slate500.withOpacity(0.1);
    }
  }

  Color get _badgeFg {
    switch (alert.severity) {
      case AlertSeverity.critical: return Colors.white;
      case AlertSeverity.high:     return Colors.white;
      case AlertSeverity.moderate: return AppColors.navy900;
      case AlertSeverity.info:     return AppColors.slate500;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_outlined,
                    size: 18, color: _iconColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: _badgeBg,
                              borderRadius:
                                  BorderRadius.circular(4),
                            ),
                            child: Text(_severityLabel,
                                style: AppTextStyles.eyebrow
                                    .copyWith(
                                  color: _badgeFg,
                                  fontSize: 11,
                                )),
                          ),
                          const Spacer(),
                          Text(alert.time,
                              style: AppTextStyles.caption),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(alert.title,
                          style: AppTextStyles.cardTitle
                              .copyWith(
                                  fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Body
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(alert.description,
                    style: AppTextStyles.bodySmall),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.place_outlined,
                        size: 14, color: AppColors.slate500),
                    const SizedBox(width: 4),
                    Text(alert.distance, style: AppTextStyles.caption),
                  ],
                ),
              ],
            ),
          ),
          // Recommended action
          if (alert.recommendedAction.isNotEmpty)
          Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.7),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.hairline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('RECOMMENDED ACTION',
                    style: AppTextStyles.eyebrow.copyWith(
                        color: AppColors.slate500)),
                const SizedBox(height: 4),
                Text(alert.recommendedAction,
                    style: AppTextStyles.bodySmall.copyWith(
                        color: AppColors.navy900)),
              ],
            ),
          ),
          // Action buttons
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.hairline)),
            ),
            child: Row(
              children: [
                if (alert.incidentId != null) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onViewIncident,
                      icon: const Icon(Icons.arrow_forward, size: 13),
                      label: const Text('View incident'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            vertical: 8),
                        textStyle: AppTextStyles.buttonSmall,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: _AckButton(
                      acked: acked, local: local,
                      onTap: busy ? null : onAcknowledge),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AckButton extends StatelessWidget {
  final bool acked;
  final bool local;
  final VoidCallback? onTap;
  const _AckButton({required this.acked, required this.local, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (acked) {
      return Container(
        padding:
            const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        decoration: BoxDecoration(
          color: AppColors.deepGreen700.withOpacity(0.1),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
              color: AppColors.deepGreen700.withOpacity(0.4)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check, size: 14, color: AppColors.deepGreen700),
            const SizedBox(width: 4),
            Flexible(
              child: Text(local ? 'Acknowledged on this device' : 'Acknowledged',
                  textAlign: TextAlign.center,
                  style: AppTextStyles.buttonSmall.copyWith(
                      color: AppColors.deepGreen700)),
            ),
          ],
        ),
      );
    }
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 8),
        textStyle: AppTextStyles.buttonSmall,
      ),
      child: const Text('Acknowledge'),
    );
  }
}
