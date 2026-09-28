import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/offline/outbox_db.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../../../mock_data/models.dart';
import '../../../shared/widgets/widgets.dart';
import '../../../theme/colors.dart';
import '../../../theme/text_styles.dart';
import '../report/report_outbox.dart';

/// The officer's own incident reports from `road_incidents` (RLS: reporter
/// sees own rows). Refetches whenever the outbox shrinks, i.e. after a sync.
final myReportsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final sb = ref.watch(supabaseClientProvider);
  ref.watch(myOutboxProvider.select((v) => v.valueOrNull?.length));
  final uid = sb.auth.currentUser?.id;
  if (uid == null) return const [];
  return sb
      .from('road_incidents')
      .select('id, incident_type, severity, status, verification, location_text, lat, lng, created_at, evidence_paths')
      .eq('reporter_id', uid)
      .order('created_at', ascending: false)
      .limit(100);
});

/// My Reports: queued (unsent) reports first, then the ones the server has.
class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queued = ref.watch(myOutboxProvider).valueOrNull ?? const <OutboxEntry>[];
    final sent = ref.watch(myReportsProvider);
    final rows = sent.valueOrNull ?? const [];
    final sb = ref.watch(supabaseClientProvider);

    Future<void> retry() async {
      final uid = sb.auth.currentUser?.id;
      if (uid == null) return;
      await ref.read(outboxDbProvider).retryAllNow(uid);
      await ref.read(reportSyncProvider).flush(uid);
    }

    return Scaffold(
      backgroundColor: AppColors.paper,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            await retry();
            ref.invalidate(myReportsProvider);
          },
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Semantics(header: true, child: Text('My reports', style: AppTextStyles.pageHeading)),
              const SizedBox(height: 4),
              Text('Incidents you reported · pull down to refresh', style: AppTextStyles.footnote),
              const SizedBox(height: 16),
              if (queued.isNotEmpty) ...[
                Row(children: [
                  Expanded(child: Text('Waiting to send (${queued.length})', style: AppTextStyles.sectionHeading)),
                  TextButton(onPressed: retry, child: const Text('Retry now')),
                ]),
                for (final e in queued)
                  _ReportTile(
                    title: _typeLabel(e.payload['incident_type'] as String?),
                    subtitle: [
                      (e.payload['location_text'] as String?) ?? _coords(e.payload['lat'], e.payload['lng']),
                      _when(e.createdAt),
                      if (e.lastError != null) 'Last try failed: ${e.lastError}',
                    ].join(' · '),
                    sync: SyncStatus.pending,
                  ),
                const SizedBox(height: 16),
              ],
              if (sent.hasError)
                EmptyState(
                  icon: Icons.cloud_off_outlined,
                  title: "Couldn't load sent reports",
                  message: 'Check the connection and pull down to try again.',
                  actionLabel: 'Try again',
                  onAction: () => ref.invalidate(myReportsProvider),
                )
              else if (sent.isLoading && rows.isEmpty)
                const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
              else if (rows.isEmpty && queued.isEmpty)
                const EmptyState(
                  icon: Icons.description_outlined,
                  title: 'No reports yet',
                  message: 'Incidents you report appear here with their status.',
                )
              else
                for (final r in rows)
                  _ReportTile(
                    title: _typeLabel(r['incident_type'] as String?),
                    subtitle: [
                      (r['location_text'] as String?) ?? _coords(r['lat'], r['lng']),
                      _when(DateTime.tryParse(r['created_at'] as String? ?? '')?.toLocal()),
                      'Status: ${_status(r['status'] as String?, r['verification'] as String?)}',
                      if ((r['evidence_paths'] as List?)?.isNotEmpty ?? false)
                        '${(r['evidence_paths'] as List).length} photo(s)',
                    ].join(' · '),
                    sync: r['verification'] == 'rejected' ? SyncStatus.rejected : SyncStatus.synced,
                  ),
            ],
          ),
        ),
      ),
    );
  }

  static String _typeLabel(String? t) =>
      (t ?? 'other').split('_').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ');

  static String _coords(Object? lat, Object? lng) => lat is num && lng is num
      ? '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}'
      : 'No location';

  static String _when(DateTime? t) => t == null ? '' : DateFormat('d MMM, HH:mm').format(t);

  static String _status(String? status, String? verification) {
    if (verification == 'rejected') return 'rejected by officer';
    return switch (status) {
      'reported' => 'awaiting verification',
      'under_review' => 'under review',
      'resolved' => 'resolved',
      'escalated' => 'escalated',
      _ => verification == 'verified' ? 'verified, response under way' : (status ?? 'reported'),
    };
  }
}

class _ReportTile extends StatelessWidget {
  final String title, subtitle;
  final SyncStatus sync;
  const _ReportTile({required this.title, required this.subtitle, required this.sync});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: CardSurface(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppTextStyles.cardTitle),
                  const SizedBox(height: 2),
                  Text(subtitle, style: AppTextStyles.caption),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SyncChip(status: sync),
          ],
        ),
      ),
    );
  }
}
