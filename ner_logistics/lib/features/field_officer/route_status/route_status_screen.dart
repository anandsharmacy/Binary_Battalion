import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../ml/application/ml_providers.dart';
import 'package:intl/intl.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../dashboard/field_dashboard.dart' show districtIncidentsProvider;
import '../../ml/presentation/ml_widgets.dart';
import '../../../mock_data/models.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/risk_badge.dart';
import '../../../theme/colors.dart';
import '../../../theme/text_styles.dart';

/// Corridor status for the officer's district from `get_corridor_accessibility`
/// (the same function the web District Map and Analytics use). Re-runs whenever
/// the live incident list changes, so a new field report updates it.
final corridorStatusProvider = FutureProvider.autoDispose<List<RouteInfo>>((ref) async {
  ref.watch(districtIncidentsProvider);
  final client = ref.watch(supabaseClientProvider);
  if (client.auth.currentUser == null) return const [];
  final res = await client.rpc('get_corridor_accessibility') as Map<String, dynamic>;
  final at = DateTime.tryParse('${res['generated_at']}')?.toLocal();
  final updated = at == null ? '' : DateFormat('d MMM, HH:mm').format(at);
  return [
    for (final r in (res['routes'] as List? ?? const []).cast<Map<String, dynamic>>())
      corridorFromJson(r, updated),
  ];
});

RouteInfo corridorFromJson(Map<String, dynamic> r, String updated) {
  final incidents = (r['incidents'] as List? ?? const []).cast<Map<String, dynamic>>();
  int count(String type) => incidents.where((i) => i['incident_type'] == type).length;
  String reported(int n) => n == 0 ? 'None reported' : '$n open report${n == 1 ? '' : 's'}';
  final status = '${r['status'] ?? 'open'}';
  final blocking = (r['blocking_incidents'] as num?)?.toInt() ?? 0;
  final ml = r['ml'] as Map<String, dynamic>?;
  return RouteInfo(
    id: '${r['route_id']}',
    name: [r['route_number'], r['name']].where((v) => v != null && '$v'.isNotEmpty).join(' · '),
    score: (r['accessibility_pct'] as num?)?.round() ?? 100,
    risk: switch (status) {
      'blocked' => RiskLevel.critical,
      'restricted' => RiskLevel.caution,
      _ => RiskLevel.clear,
    },
    condition: '${status[0].toUpperCase()}${status.substring(1)}',
    incidentCount: (r['open_incidents'] as num?)?.toInt() ?? 0,
    weather: 'No weather feed',
    updatedAt: updated,
    detail: RouteDetail(
      floodRisk: reported(count('flood')),
      landslideRisk: reported(count('landslide')),
      blockage: blocking == 0 ? 'None verified' : '$blocking verified blocking',
      history: ml == null || ml['max_percentile'] == null
          ? 'ML risk scores not published yet.'
          : 'ML risk: highest segment percentile ${ml['max_percentile']}, mean ${ml['mean_percentile']}.',
      recommendedAction: switch (status) {
        'blocked' => 'Do not use. Report conditions and follow District Officer instructions.',
        'restricted' => 'Travel with caution; check open reports on this corridor.',
        _ => 'No verified restrictions.',
      },
    ),
  );
}

class RouteStatusScreen extends ConsumerStatefulWidget {
  const RouteStatusScreen({super.key});

  @override
  ConsumerState<RouteStatusScreen> createState() => _RouteStatusScreenState();
}

class _RouteStatusScreenState extends ConsumerState<RouteStatusScreen> {
  String? _selectedId;
  bool _showToast = false;

  RouteInfo? get _selectedRoute =>
      _selectedId == null
          ? null
          : _routes.where((r) => r.id == _selectedId).firstOrNull;
  List<RouteInfo> _routes = const [];

  Color _scoreColor(int score) {
    if (score >= 80) return AppColors.deepGreen700;
    if (score >= 50) return AppColors.saffron600;
    return AppColors.signalRed700;
  }

  Color _scoreLabelColor(int score) {
    if (score >= 80) return AppColors.deepGreen700;
    if (score >= 50) return AppColors.saffronDark;
    return AppColors.signalRed700;
  }

  void _showIncidentToast() {
    setState(() => _showToast = true);
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _showToast = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    _routes = ref.watch(corridorStatusProvider).valueOrNull ?? const [];
    return Stack(
      children: [
        _selectedRoute == null
            ? _buildListView()
            : RouteDetailView(
                route: _selectedRoute!,
                onBack: () => setState(() => _selectedId = null),
                onViewIncidents: _showIncidentToast,
              ),
        if (_showToast)
          Positioned(
            left: 16,
            right: 16,
            bottom: 32,
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: AppColors.navy900,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: Colors.white.withOpacity(0.8)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Incident history is available when connected to network.',
                        style: AppTextStyles.caption.copyWith(color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildListView() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: AppColors.slate500.withOpacity(0.10), width: 1),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${_routes.length} reported route${_routes.length == 1 ? '' : 's'}',
                  style: AppTextStyles.footnote,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => ref.refresh(allRoutesMlRiskProvider.future),
            child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Road disruption risk (model)', style: AppTextStyles.bodySmallMedium),
                const SizedBox(height: 8),
                const MlRoutesBoard(),
                const SizedBox(height: 16),
                Text('Reported route status', style: AppTextStyles.bodySmallMedium),
                const SizedBox(height: 8),
                if (_routes.isEmpty)
                  const EmptyState(
                    icon: Icons.route_outlined,
                    title: 'No route reports yet',
                    message: 'Route status reported from the field will appear here.',
                  ),
                ..._routes.asMap().entries.map((entry) {
                  final route = entry.value;
                  final isLast = entry.key == _routes.length - 1;
                  return Padding(
                    padding: EdgeInsets.only(bottom: isLast ? 0 : 12),
                    child: _RouteCard(
                      route: route,
                      onTap: () => setState(() => _selectedId = route.id),
                      scoreColor: _scoreColor(route.score),
                      scoreLabelColor: _scoreLabelColor(route.score),
                    ),
                  );
                }),
              ],
            ),
          ),
          ),
        ),
      ],
    );
  }
}

class _RouteCard extends StatelessWidget {
  final RouteInfo route;
  final VoidCallback onTap;
  final Color scoreColor;
  final Color scoreLabelColor;

  const _RouteCard({
    required this.route,
    required this.onTap,
    required this.scoreColor,
    required this.scoreLabelColor,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        splashColor: AppColors.navy900.withOpacity(0.06),
        highlightColor: AppColors.navy900.withOpacity(0.03),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: AppColors.slate500.withOpacity(0.20), width: 1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.navy900,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      route.id,
                      style: AppTextStyles.eyebrow
                          .copyWith(color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        route.name,
                        style: AppTextStyles.cardTitle,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  RiskBadge(level: route.risk),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: route.score / 100,
                        backgroundColor: AppColors.slate500.withOpacity(0.10),
                        valueColor: AlwaysStoppedAnimation<Color>(scoreColor),
                        minHeight: 1.5,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${route.score}/100',
                    style: AppTextStyles.tabLabel.copyWith(
                        fontWeight: FontWeight.w700, color: scoreLabelColor),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                route.condition,
                style: AppTextStyles.bodySmall,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (route.incidentCount > 0)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.warning, size: 13, color: AppColors.signalRed700),
                        const SizedBox(width: 4),
                        Text(
                          '${route.incidentCount} incident${route.incidentCount != 1 ? 's' : ''}',
                          style: AppTextStyles.caption.copyWith(color: AppColors.signalRed700),
                        ),
                      ],
                    ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.location_on_outlined, size: 13, color: AppColors.slate500),
                      const SizedBox(width: 4),
                      Text(
                        route.weather,
                        style: AppTextStyles.caption,
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.access_time_outlined, size: 13, color: AppColors.slate500),
                      const SizedBox(width: 4),
                      Text(
                        route.updatedAt,
                        style: AppTextStyles.caption,
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class RouteDetailView extends StatelessWidget {
  final RouteInfo route;
  final VoidCallback onBack;
  final VoidCallback onViewIncidents;

  const RouteDetailView({
    super.key,
    required this.route,
    required this.onBack,
    required this.onViewIncidents,
  });

  Color get _scoreColor {
    if (route.score >= 80) return AppColors.deepGreen700;
    if (route.score >= 50) return AppColors.saffron600;
    return AppColors.signalRed700;
  }

  Color get _scoreLabelColor {
    if (route.score >= 80) return AppColors.deepGreen700;
    if (route.score >= 50) return AppColors.saffronDark;
    return AppColors.signalRed700;
  }

  Color get _bannerBg {
    switch (route.risk) {
      case RiskLevel.clear:
        return AppColors.clearBg;
      case RiskLevel.caution:
        return AppColors.saffronBg;
      case RiskLevel.critical:
        return AppColors.criticalBg;
    }
  }

  Color get _bannerBorder {
    switch (route.risk) {
      case RiskLevel.clear:
        return AppColors.deepGreen700.withOpacity(0.30);
      case RiskLevel.caution:
        return AppColors.saffron600.withOpacity(0.30);
      case RiskLevel.critical:
        return AppColors.signalRed700.withOpacity(0.30);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onBack,
            borderRadius: BorderRadius.circular(6),
            splashColor: AppColors.navy900.withOpacity(0.06),
            highlightColor: AppColors.navy900.withOpacity(0.03),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.chevron_left, size: 20, color: AppColors.navy900),
                  const SizedBox(width: 2),
                  Text(
                    'Route Status',
                    style: AppTextStyles.buttonSmall.copyWith(color: AppColors.navy900),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            route.name,
            style: AppTextStyles.sectionHeading,
          ),
          const SizedBox(height: 2),
          Text(
            'Updated ${route.updatedAt}',
            style: AppTextStyles.footnote,
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${route.score}',
                style: TextStyle(
                  fontFamily: 'PublicSans',
                  fontSize: 36,
                  fontWeight: FontWeight.w700,
                  color: _scoreLabelColor,
                  height: 1.0,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '/100',
                  style: const TextStyle(
                    fontFamily: 'PublicSans',
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: AppColors.slate500,
                    height: 1.0,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ACCESSIBILITY',
                      style: AppTextStyles.eyebrow.copyWith(color: AppColors.slate500),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              Container(
                width: 1,
                height: 28,
                color: AppColors.slate500.withOpacity(0.15),
              ),
              const SizedBox(width: 12),
              RiskBadge(level: route.risk),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: route.score / 100,
              backgroundColor: AppColors.slate500.withOpacity(0.10),
              valueColor: AlwaysStoppedAnimation<Color>(_scoreColor),
              minHeight: 2,
            ),
          ),
          const SizedBox(height: 20),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.slate500.withOpacity(0.15)),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                Row(
                  children: [
                    _buildDetailCell('Flood Risk', route.detail.floodRisk, false, false),
                    Container(width: 1, height: 68, color: AppColors.slate500.withOpacity(0.15)),
                    _buildDetailCell('Landslide Risk', route.detail.landslideRisk, false, true),
                  ],
                ),
                Container(height: 1, width: double.infinity, color: AppColors.slate500.withOpacity(0.15)),
                Row(
                  children: [
                    _buildDetailCell('Blockage', route.detail.blockage, false, false),
                    Container(width: 1, height: 68, color: AppColors.slate500.withOpacity(0.15)),
                    _buildDetailCell('Condition', route.condition, false, true),
                  ],
                ),
                Container(height: 1, width: double.infinity, color: AppColors.slate500.withOpacity(0.15)),
                Row(
                  children: [
                    _buildDetailCell('Weather', route.weather, true, false),
                    Container(width: 1, height: 68, color: AppColors.slate500.withOpacity(0.15)),
                    _buildDetailCell('Incidents', '${route.incidentCount} active', true, true),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: AppColors.slate500.withOpacity(0.15)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Icon(Icons.access_time_outlined, size: 16, color: AppColors.slate500),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    route.detail.history,
                    style: AppTextStyles.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _bannerBg,
              border: Border.all(color: _bannerBorder, width: 1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'RECOMMENDED ACTION',
                  style: AppTextStyles.eyebrow
                      .copyWith(color: AppColors.slate500),
                ),
                const SizedBox(height: 6),
                Text(
                  route.detail.recommendedAction,
                  style: AppTextStyles.sectionTitle.copyWith(color: _scoreLabelColor, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onViewIncidents,
              icon: const Icon(Icons.history, size: 16),
              label: const Text('All incidents on this route'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                textStyle: AppTextStyles.buttonSmall,
                foregroundColor: AppColors.navy900,
                side: BorderSide(color: AppColors.slate500.withOpacity(0.25)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildDetailCell(String label, String value, bool isLastRow, bool isLastCol) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label.toUpperCase(),
              style: AppTextStyles.eyebrow.copyWith(color: AppColors.slate500),
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: AppTextStyles.bodySmallMedium,
            ),
          ],
        ),
      ),
    );
  }
}
