import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

/// One queued write waiting for the network (today: incident reports).
class OutboxEntry {
  final int id;
  final String kind;
  final String clientId;
  final String userId;
  final Map<String, dynamic> payload;
  final List<String> filePaths;
  final int attempts;
  final String? lastError;
  final DateTime createdAt;
  final DateTime nextAttemptAt;

  const OutboxEntry({
    required this.id,
    required this.kind,
    required this.clientId,
    required this.userId,
    required this.payload,
    required this.filePaths,
    required this.attempts,
    required this.lastError,
    required this.createdAt,
    required this.nextAttemptAt,
  });

  factory OutboxEntry._fromRow(QueryRow r) => OutboxEntry(
        id: r.read<int>('id'),
        kind: r.read<String>('kind'),
        clientId: r.read<String>('client_id'),
        userId: r.read<String>('user_id'),
        payload: jsonDecode(r.read<String>('payload_json')) as Map<String, dynamic>,
        filePaths: (jsonDecode(r.read<String>('file_paths')) as List).cast<String>(),
        attempts: r.read<int>('attempts'),
        lastError: r.readNullable<String>('last_error'),
        createdAt: DateTime.fromMillisecondsSinceEpoch(r.read<int>('created_at')),
        nextAttemptAt: DateTime.fromMillisecondsSinceEpoch(r.read<int>('next_attempt_at')),
      );
}

/// Durable outbox on SQLite via drift. Plain SQL instead of generated table
/// classes, so there is no build_runner step for one table.
// ponytail: hand-written SQL; switch to drift table classes + codegen if more offline tables appear.
class OutboxDb extends GeneratedDatabase {
  OutboxDb(super.executor);

  /// On-device database file `ner_outbox`.
  factory OutboxDb.open() => OutboxDb(driftDatabase(name: 'ner_outbox'));

  final _changes = StreamController<void>.broadcast();

  @override
  int get schemaVersion => 1;

  @override
  Iterable<TableInfo> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => customStatement('''
          create table outbox (
            id integer primary key autoincrement,
            kind text not null,
            client_id text not null unique,
            user_id text not null,
            payload_json text not null,
            file_paths text not null default '[]',
            attempts integer not null default 0,
            last_error text,
            created_at integer not null,
            next_attempt_at integer not null
          )'''),
      );

  /// Queues a write. Re-queuing the same [clientId] is a no-op, so a double
  /// tap cannot create two reports.
  Future<void> enqueue({
    required String kind,
    required String clientId,
    required String userId,
    required Map<String, dynamic> payload,
    List<String> filePaths = const [],
    DateTime? now,
  }) async {
    final t = (now ?? DateTime.now()).millisecondsSinceEpoch;
    await customStatement(
      'insert or ignore into outbox (kind, client_id, user_id, payload_json, file_paths, created_at, next_attempt_at) '
      'values (?, ?, ?, ?, ?, ?, ?)',
      [kind, clientId, userId, jsonEncode(payload), jsonEncode(filePaths), t, t],
    );
    _changes.add(null);
  }

  /// Entries of [userId], oldest first.
  Future<List<OutboxEntry>> entries(String userId) async {
    final rows = await customSelect(
      'select * from outbox where user_id = ? order by created_at',
      variables: [Variable.withString(userId)],
    ).get();
    return rows.map(OutboxEntry._fromRow).toList();
  }

  /// Entries of [userId] that are ready to retry at [now].
  Future<List<OutboxEntry>> due(String userId, DateTime now) async =>
      (await entries(userId)).where((e) => !e.nextAttemptAt.isAfter(now)).toList();

  /// Live list for the UI: re-reads after every change.
  Stream<List<OutboxEntry>> watch(String userId) async* {
    yield await entries(userId);
    await for (final _ in _changes.stream) {
      yield await entries(userId);
    }
  }

  Future<void> remove(int id) async {
    await customStatement('delete from outbox where id = ?', [id]);
    _changes.add(null);
  }

  Future<void> markFailed(int id, String error, DateTime nextAttemptAt) async {
    await customStatement(
      'update outbox set attempts = attempts + 1, last_error = ?, next_attempt_at = ? where id = ?',
      [error, nextAttemptAt.millisecondsSinceEpoch, id],
    );
    _changes.add(null);
  }

  /// Makes every entry of [userId] due now (user pressed "retry").
  Future<void> retryAllNow(String userId, [DateTime? now]) async {
    await customStatement('update outbox set next_attempt_at = ? where user_id = ?',
        [(now ?? DateTime.now()).millisecondsSinceEpoch, userId]);
    _changes.add(null);
  }

  @override
  Future<void> close() async {
    await _changes.close();
    await super.close();
  }
}

/// Retry delay after [attempts] failures: 5 s, 10 s, 20 s … capped at 10 min.
Duration outboxBackoff(int attempts) => Duration(
    seconds: math.min(600, 5 * math.pow(2, math.max(0, attempts - 1)).toInt()));

typedef OutboxUpload = Future<void> Function(OutboxEntry entry);

/// Sends due outbox entries one by one. An entry is deleted only after the
/// upload succeeded; a failure records the error and backs off. Uploads must
/// be idempotent on `client_id`, because a crash between upload and delete
/// sends the same entry again.
class OutboxSync {
  final OutboxDb db;
  final OutboxUpload upload;
  final DateTime Function() clock;
  bool _running = false;

  OutboxSync(this.db, this.upload, {DateTime Function()? clock})
      : clock = clock ?? DateTime.now;

  /// Returns how many entries were sent. Overlapping calls are skipped.
  Future<int> flush(String userId) async {
    if (_running) return 0;
    _running = true;
    var sent = 0;
    try {
      for (final e in await db.due(userId, clock())) {
        try {
          await upload(e);
          await db.remove(e.id);
          sent++;
        } catch (err) {
          await db.markFailed(e.id, _short(err), clock().add(outboxBackoff(e.attempts + 1)));
        }
      }
    } finally {
      _running = false;
    }
    return sent;
  }

  static String _short(Object e) {
    final s = e.toString();
    return s.length > 200 ? '${s.substring(0, 200)}…' : s;
  }
}
