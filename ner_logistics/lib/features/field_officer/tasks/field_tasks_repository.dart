import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase/supabase_providers.dart';
import '../../../mock_data/models.dart';

/// Tasks assigned to the signed-in field officer, live from `public.field_tasks`
/// (the same rows the web District Officer creates and reviews).
final myFieldTasksProvider = StreamProvider.autoDispose<List<FieldTask>>((ref) {
  final client = ref.watch(supabaseClientProvider);
  final uid = client.auth.currentUser?.id;
  if (uid == null) return Stream.value(const []);
  return client
      .from('field_tasks')
      .stream(primaryKey: ['id'])
      .eq('assigned_to', uid)
      .order('created_at')
      .map((rows) => rows.map(fieldTaskFromRow).toList(growable: false));
});

final _fmt = DateFormat('d MMM, HH:mm');
String _time(Object? iso) {
  final t = DateTime.tryParse('${iso ?? ''}')?.toLocal();
  return t == null ? '' : _fmt.format(t);
}

FieldTask fieldTaskFromRow(Map<String, dynamic> r) {
  final db = '${r['status'] ?? 'new'}';
  final deadline = DateTime.tryParse('${r['deadline'] ?? ''}');
  final open = db == 'new' || db == 'in_progress' || db == 'escalated';
  final status = switch (db) {
    'in_progress' || 'completed' => TaskStatus.inProgress,
    'awaiting_verification' => TaskStatus.awaitingVerification,
    'verified' => TaskStatus.completed,
    'rejected' => TaskStatus.rejected,
    _ => open && deadline != null && deadline.isBefore(DateTime.now())
        ? TaskStatus.overdue
        : TaskStatus.pending,
  };
  return FieldTask(
    id: '${r['id']}',
    title: '${r['title'] ?? ''}',
    location: '${r['location_text'] ?? ''}',
    priority: switch (r['priority']) {
      'critical' => Priority.critical,
      'high' => Priority.high,
      'info' => Priority.low,
      _ => Priority.medium,
    },
    dueTime: deadline == null ? 'Not set' : _time(r['deadline']),
    createdTime: _time(r['created_at']),
    status: status,
    acceptedAt: r['started_at'] == null ? null : _time(r['started_at']),
    dbStatus: db,
    verificationNote: r['verification_note'] as String?,
  );
}

/// Start a new/overdue/rejected task.
Future<void> startTask(SupabaseClient client, FieldTask t) =>
    client.from('field_tasks').update({'status': 'in_progress'}).eq('id', t.id);

/// Complete and send for District Officer verification (web: Complete, then Awaiting Verification).
Future<void> completeTask(SupabaseClient client, FieldTask t) async {
  if (t.dbStatus != 'completed') {
    await client.from('field_tasks').update({'status': 'completed'}).eq('id', t.id);
  }
  await client.from('field_tasks').update({'status': 'awaiting_verification'}).eq('id', t.id);
}
