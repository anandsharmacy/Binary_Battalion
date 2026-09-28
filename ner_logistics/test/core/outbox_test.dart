import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ner_logistics/core/offline/outbox_db.dart';

void main() {
  late OutboxDb db;
  var now = DateTime(2026, 9, 27, 10);
  setUp(() {
    db = OutboxDb(NativeDatabase.memory());
    now = DateTime(2026, 9, 27, 10);
  });
  tearDown(() => db.close());

  Future<void> queue(String clientId, {String user = 'u1'}) => db.enqueue(
      kind: 'incident_report', clientId: clientId, userId: user,
      payload: {'incident_type': 'flood'}, filePaths: ['/tmp/a.jpg'], now: now);

  test('enqueue is idempotent on client_id', () async {
    await queue('c1');
    await queue('c1');
    final all = await db.entries('u1');
    expect(all, hasLength(1));
    expect(all.single.payload['incident_type'], 'flood');
    expect(all.single.filePaths, ['/tmp/a.jpg']);
  });

  test('success removes the entry; failure keeps it and backs off', () async {
    await queue('ok');
    await queue('bad');
    final sent = <String>[];
    final sync = OutboxSync(db, (e) async {
      if (e.clientId == 'bad') throw Exception('offline');
      sent.add(e.clientId);
    }, clock: () => now);

    expect(await sync.flush('u1'), 1);
    expect(sent, ['ok']);
    var left = await db.entries('u1');
    expect(left.single.clientId, 'bad');
    expect(left.single.attempts, 1);
    expect(left.single.lastError, contains('offline'));
    expect(left.single.nextAttemptAt, now.add(const Duration(seconds: 5)));

    // Not due yet: nothing is attempted.
    expect(await sync.flush('u1'), 0);
    expect((await db.entries('u1')).single.attempts, 1);

    // Second failure doubles the delay.
    now = now.add(const Duration(seconds: 5));
    await sync.flush('u1');
    left = await db.entries('u1');
    expect(left.single.attempts, 2);
    expect(left.single.nextAttemptAt, now.add(const Duration(seconds: 10)));
  });

  test('retry after a lost acknowledgement re-sends the same client_id', () async {
    // Upload reached the server but the delete never happened (crash): the
    // next flush sends the same client_id again, which the server ignores.
    await queue('c1');
    final seen = <String>[];
    var crash = true;
    final sync = OutboxSync(db, (e) async {
      seen.add(e.clientId);
      if (crash) {
        crash = false;
        throw Exception('connection reset after commit');
      }
    }, clock: () => now);
    await sync.flush('u1');
    now = now.add(const Duration(minutes: 1));
    await sync.flush('u1');
    expect(seen, ['c1', 'c1']);
    expect(await db.entries('u1'), isEmpty);
  });

  test('only the signed-in user\'s entries are sent', () async {
    await queue('mine');
    await queue('theirs', user: 'u2');
    final sent = <String>[];
    await OutboxSync(db, (e) async => sent.add(e.clientId), clock: () => now).flush('u1');
    expect(sent, ['mine']);
    expect(await db.entries('u2'), hasLength(1));
  });

  test('backoff is capped at 10 minutes', () {
    expect(outboxBackoff(1), const Duration(seconds: 5));
    expect(outboxBackoff(3), const Duration(seconds: 20));
    expect(outboxBackoff(30), const Duration(minutes: 10));
  });
}
