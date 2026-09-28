import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../alerts/alerts_repository.dart';
import 'package:intl/intl.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../../../mock_data/mock_officers.dart';
import '../../../mock_data/models.dart';
import '../tasks/field_tasks_repository.dart';
import '../../../shared/map/ner_map.dart' show IncidentTypeUi;
import '../../../shared/widgets/widgets.dart';
import '../../../theme/colors.dart';
import '../../../theme/text_styles.dart';

/// Open incidents the officer may see (RLS: their district, plus their own reports), live.
final districtIncidentsProvider = StreamProvider.autoDispose<List<NearbyIncident>>((ref) {
  final client = ref.watch(supabaseClientProvider);
  if (client.auth.currentUser == null) return Stream.value(const []);
  final fmt = DateFormat('d MMM, HH:mm');
  return client
      .from('road_incidents')
      .stream(primaryKey: ['id'])
      .order('created_at')
      .limit(100)
      .map((rows) => rows
          .where((r) => r['status'] != 'resolved' && r['status'] != 'rejected')
          .map((r) {
            final type = '${r['incident_type']}'.replaceAll('_', ' ');
            final created = DateTime.tryParse('${r['created_at']}')?.toLocal();
            return NearbyIncident(
              title: '${type[0].toUpperCase()}${type.substring(1)} · ${r['severity']}',
              place: '${r['location_text'] ?? r['route_text'] ?? 'Location not provided'}',
              distance: created == null ? '' : fmt.format(created),
              level: switch (r['severity']) {
                'critical' || 'high' => RiskLevel.critical,
                'moderate' => RiskLevel.caution,
                _ => RiskLevel.clear,
              },
            );
          })
          .toList(growable: false));
});

/// FieldDashboard — matches React FieldDashboard exactly.
/// KPI 2×2 grid · area situation card · priority tasks · nearby incidents
/// · quick-action grid.
class FieldDashboard extends ConsumerWidget {
  final Officer? officer;
  final VoidCallback onStartTask;
  final VoidCallback onOpenTasks;
  final VoidCallback onViewIncidents;
  final ValueChanged<IncidentType> onReportType;

  const FieldDashboard({
    super.key,
    this.officer,
    required this.onStartTask,
    required this.onOpenTasks,
    required this.onViewIncidents,
    required this.onReportType,
  });

  static const _quickActions = [
    (type: IncidentType.flood, label: 'Flood'),
    (type: IncidentType.roadBlockage, label: 'Road Blockage'),
    (type: IncidentType.landslide, label: 'Landslide'),
    (type: IncidentType.accident, label: 'Accident'),
    (type: IncidentType.infraDamage, label: 'Infrastructure Damage'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allTasks = ref.watch(myFieldTasksProvider).valueOrNull ?? const <FieldTask>[];
    final nearby = ref.watch(districtIncidentsProvider).valueOrNull ?? const <NearbyIncident>[];
    final tasks = allTasks
        .where((t) =>
            t.priority == Priority.critical ||
            t.priority == Priority.high)
        .take(3)
        .toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── KPI grid ─────────────────────────────────────────
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 1.6,
            children: [
              KpiTile(
                label: 'Assigned Tasks',
                value: '${allTasks.length}',
                tone: KpiTone.navy,
                onTap: onOpenTasks,
              ),
              KpiTile(
                label: 'Pending Tasks',
                value: '${allTasks.where((t) => t.status == TaskStatus.pending).length}',
                tone: KpiTone.saffron,
                onTap: onOpenTasks,
              ),
              KpiTile(
                label: 'Active Incidents',
                value: '${nearby.length}',
                tone: KpiTone.navy,
                onTap: onViewIncidents,
              ),
              Consumer(
                builder: (context, ref, _) => KpiTile(
                  label: 'Critical Alerts',
                  value: '${ref.watch(alertsStreamProvider).valueOrNull?.where((a) => a.severity == AlertSeverity.critical && a.status == 'active').length ?? 0}',
                  tone: KpiTone.critical,
                  onTap: onViewIncidents,
                ),
              ),
            ],
          ),

          // ── Current Area Situation ────────────────────────────
          SectionTitle(title: 'Current Area Situation'),
          CardSurface(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.location_on_outlined,
                                  size: 15,
                                  color: AppColors.slate500),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  (officer ?? fieldOfficer).region,
                                  style: AppTextStyles.cardTitle,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Monitored sector · ${(officer ?? fieldOfficer).officerId}',
                            style: AppTextStyles.caption,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Area accessibility and risk metrics are not available yet.',
                  style: AppTextStyles.disclaimer,
                ),
              ],
            ),
          ),

          // ── My Priority Tasks ─────────────────────────────────
          SectionTitle(
            title: 'My Priority Tasks',
            action: TextButton(
              onPressed: onOpenTasks,
              child: const Text('View all'),
            ),
          ),
          if (tasks.isEmpty)
            const CardSurface(
              child: EmptyState(
                icon: Icons.assignment_outlined,
                title: 'No priority tasks',
                message: 'Critical and high-priority tasks assigned to you will appear here.',
              ),
            ),
          Column(
            children: tasks.map((t) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: CardSurface(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Text(t.id,
                                    style: AppTextStyles.caption
                                        .copyWith(
                                            color: AppColors.slate500
                                                .withOpacity(0.7))),
                                const SizedBox(height: 2),
                                Text(t.title,
                                    style: AppTextStyles.cardTitle
                                        .copyWith(
                                            fontWeight:
                                                FontWeight.w700)),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          PriorityBadge(level: t.priority),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(Icons.location_on_outlined,
                              size: 14,
                              color: AppColors.slate500
                                  .withOpacity(0.7)),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(t.location,
                                style: AppTextStyles.bodySmall),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          StatusChip(
                            tone: ChipTone.muted,
                            label: 'Due ${t.dueTime}',
                          ),
                          const Spacer(),
                          ElevatedButton(
                            onPressed: onStartTask,
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 8),
                              minimumSize: Size.zero,
                              textStyle: AppTextStyles.buttonSmall,
                            ),
                            child: const Text('Start Task'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),

          // ── Nearby Incidents ──────────────────────────────────
          SectionTitle(
            title: 'Nearby Incidents',
            action: TextButton(
              onPressed: onViewIncidents,
              child: const Text('View All Incidents'),
            ),
          ),
          if (nearby.isEmpty)
            const CardSurface(
              child: EmptyState(
                icon: Icons.report_outlined,
                title: 'No nearby incidents',
                message: 'Incidents reported near your area will appear here.',
              ),
            )
          else
          CardSurface(
            child: Column(
              children: nearby
                  .asMap()
                  .entries
                  .map((e) {
                final n = e.value;
                final isFirst = e.key == 0;
                return Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    border: isFirst
                        ? null
                        : Border(
                            top: BorderSide(
                                color: AppColors.hairline)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        n.level == RiskLevel.clear
                            ? Icons.check_circle_outline
                            : Icons.warning_outlined,
                        size: 18,
                        color: n.level == RiskLevel.clear
                            ? AppColors.deepGreen700
                            : n.level == RiskLevel.caution
                                ? AppColors.saffron600
                                : AppColors.signalRed700,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Text(n.title,
                                style:
                                    AppTextStyles.cardTitle),
                            const SizedBox(height: 2),
                            Text(n.place,
                                style:
                                    AppTextStyles.bodySmall),
                          ],
                        ),
                      ),
                      Text(
                        n.distance,
                        style: AppTextStyles.captionSemibold
                            .copyWith(
                                color: AppColors.slate500
                                    .withOpacity(0.7),
                                fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),

          // ── Quick Actions ─────────────────────────────────────
          const SectionTitle(title: 'Quick Actions'),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 2.8,
            children: _quickActions.asMap().entries.map((e) {
              final q = e.value;
              return CardSurface(
                onTap: () => onReportType(q.type),
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Icon(q.type.icon, size: 20, color: AppColors.navy900),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Report ${q.label}',
                        style: AppTextStyles.captionSemibold
                            .copyWith(
                                color: AppColors.navy900,
                                fontWeight: FontWeight.w600),
                      ),
                    ),
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color:
                            AppColors.gold.withOpacity(0.13),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.add,
                          size: 14, color: AppColors.gold),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}
