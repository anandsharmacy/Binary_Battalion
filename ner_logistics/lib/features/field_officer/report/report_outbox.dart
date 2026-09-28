import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/network/connectivity_provider.dart';
import '../../../core/offline/outbox_db.dart';
import '../../../core/supabase/supabase_providers.dart';

const incidentReportKind = 'incident_report';
const _bucket = 'incident-evidence';

final outboxDbProvider = Provider<OutboxDb>((ref) {
  final db = OutboxDb.open();
  ref.onDispose(db.close);
  return db;
});

/// Background sender for queued reports: runs at start, whenever the device
/// comes online, and every 30 s (entries back off individually on failure).
final reportSyncProvider = Provider<OutboxSync>((ref) {
  final sb = ref.watch(supabaseClientProvider);
  final sync = OutboxSync(ref.watch(outboxDbProvider), (e) => uploadIncidentReport(sb, e));
  void kick() {
    final uid = sb.auth.currentUser?.id;
    if (uid == null || ref.read(isOnlineProvider).valueOrNull == false) return;
    unawaited(sync.flush(uid));
  }

  ref.listen<AsyncValue<bool>>(isOnlineProvider, (_, next) {
    if (next.valueOrNull == true) kick();
  });
  final timer = Timer.periodic(const Duration(seconds: 30), (_) => kick());
  ref.onDispose(timer.cancel);
  Future.microtask(kick);
  return sync;
});

/// The signed-in user's unsent reports (live).
final myOutboxProvider = StreamProvider<List<OutboxEntry>>((ref) {
  final uid = ref.watch(supabaseClientProvider).auth.currentUser?.id;
  if (uid == null) return Stream.value(const []);
  return ref.watch(outboxDbProvider).watch(uid);
});

/// Uploads evidence, then inserts the incident. Both steps are idempotent:
/// files go to a fixed path per client_id (upsert), and the row insert is
/// `on conflict (client_id) do nothing`, so a retry never duplicates.
Future<void> uploadIncidentReport(SupabaseClient sb, OutboxEntry e) async {
  final uid = sb.auth.currentUser?.id;
  if (uid == null || uid != e.userId) throw StateError('Not signed in as the reporter');
  final paths = <String>[];
  for (var i = 0; i < e.filePaths.length; i++) {
    final file = File(e.filePaths[i]);
    if (!file.existsSync()) continue; // local copy lost; send the report without it
    final name = '$uid/${e.clientId}/$i-${file.uri.pathSegments.last}';
    await sb.storage.from(_bucket).upload(name, file,
        fileOptions: FileOptions(upsert: true, contentType: _mime(name)));
    paths.add(name);
  }
  await sb.from('road_incidents').upsert(
    {...e.payload, 'client_id': e.clientId, 'evidence_paths': paths},
    onConflict: 'client_id',
    ignoreDuplicates: true,
  );
  for (final p in e.filePaths) {
    try {
      await File(p).delete();
    } catch (_) {/* already gone */}
  }
}

String _mime(String path) {
  final ext = path.split('.').last.toLowerCase();
  return switch (ext) {
    'png' => 'image/png',
    'webp' => 'image/webp',
    'heic' => 'image/heic',
    'mp4' => 'video/mp4',
    'mov' => 'video/quicktime',
    _ => 'image/jpeg',
  };
}
