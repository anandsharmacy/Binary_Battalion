import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase/supabase_providers.dart';
import '../../mock_data/models.dart';

/// Live `public.alerts` (RLS: officers only), newest first. Realtime via
/// `.stream()`, so inserts from ML promotion, field reports and officers
/// arrive without a refresh.
/// autoDispose: re-created per signed-in shell; nothing is opened while signed out.
final alertsStreamProvider = StreamProvider.autoDispose<List<AppAlert>>((ref) {
  final client = ref.watch(supabaseClientProvider);
  if (client.auth.currentUser == null) return Stream.value(const []);
  return client
      .from('alerts')
      .stream(primaryKey: ['id'])
      .order('created_at')
      .limit(200)
      .map((rows) => rows.map(alertFromRow).toList(growable: false));
});

/// Alerts not yet acknowledged, for header/drawer badges. 0 while loading or offline.
final activeAlertCountProvider = Provider.autoDispose<int>((ref) =>
    ref.watch(alertsStreamProvider).valueOrNull?.where((a) => a.status == 'active').length ?? 0);

/// Acknowledge or resolve. The server records the signed-in user as the actor.
Future<void> setAlertStatus(SupabaseClient client, String id, String status) =>
    client.rpc('set_alert_status', params: {'p_alert_id': id, 'p_status': status});

const _sources = {'human': 'Officer', 'rule': 'Field report', 'feed': 'Feed', 'ml': 'ML model'};

AppAlert alertFromRow(Map<String, dynamic> r) {
  final created = DateTime.tryParse('${r['created_at']}')?.toLocal();
  return AppAlert(
    id: '${r['id']}',
    severity: AlertSeverity.values.firstWhere((s) => s.name == r['severity'],
        orElse: () => AlertSeverity.info),
    title: '${r['title'] ?? ''}',
    description: '${r['description'] ?? ''}',
    distance: 'Source: ${_sources[r['source']] ?? r['source']}',
    time: created == null ? '' : DateFormat('d MMM, HH:mm').format(created),
    recommendedAction: '',
    incidentId: r['incident_id'] as String?,
    status: '${r['status'] ?? 'active'}',
  );
}
