import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ner_logistics/core/supabase/supabase_providers.dart';
import 'package:ner_logistics/features/auth/application/auth_controller.dart';
import 'package:ner_logistics/features/auth/domain/auth_models.dart';
import 'package:ner_logistics/features/field_officer/field_drawer.dart';
import 'package:ner_logistics/features/field_officer/field_officer_shell.dart';
import 'package:ner_logistics/features/rider/offline_nav/presentation/offline_nav_page.dart';
import 'package:ner_logistics/features/rider/rider_drawer.dart';
import 'package:ner_logistics/features/rider/rider_shell.dart';
import 'package:ner_logistics/mock_data/models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ner_logistics/core/offline/outbox_db.dart';
import 'package:ner_logistics/features/field_officer/report/report_outbox.dart';

/// The app ships no sample data, so every screen must render its empty state
/// without throwing. Walks each role's menu with an unreachable backend.
AuthUserProfile _profile(AppRole role) => AuthUserProfile(
      userId: '00000000-0000-0000-0000-00000000000${role.index}',
      email: '${role.name}@smoke.test',
      fullName: 'Smoke Test',
      role: role,
    );

Future<void> _walk<T extends Enum>(
  WidgetTester t,
  AppRole role,
  Widget shell,
  Type drawer,
  List<T> navs,
  String Function(T) label, {
  double textScale = 1.0,
}) async {
  // Wide viewport: the test font renders text far wider than real fonts, which
  // would report layout overflows that don't happen on devices.
  t.view.physicalSize = const Size(3600, 2532);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);

  await t.pumpWidget(ProviderScope(
    overrides: [
      currentProfileProvider.overrideWithValue(_profile(role)),
      supabaseClientProvider.overrideWithValue(SupabaseClient(
        'http://127.0.0.1:9',
        'smoke-test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      )),
    ],
    child: MaterialApp(
      home: shell,
      // Largest supported text size (the app clamps at 200%).
      builder: (c, w) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(textScale)),
        child: w!,
      ),
    ),
  ));
  await t.pump(const Duration(milliseconds: 300));

  final problems = <String>[];
  for (final nav in navs) {
    // A full-screen overlay (e.g. the expanded map) hides the header; close it like a user would.
    if (find.byIcon(Icons.menu).evaluate().isEmpty && find.byIcon(Icons.close).evaluate().isNotEmpty) {
      await t.tap(find.byIcon(Icons.close).first);
      await t.pump(const Duration(milliseconds: 300));
    }
    await t.tap(find.byIcon(Icons.menu).first);
    await t.pump(const Duration(milliseconds: 400));
    // Tap the drawer's own entry; the same text can appear on the page underneath.
    final item = find.descendant(of: find.byType(drawer), matching: find.text(label(nav)));
    // The drawer list is lazy: at large text sizes lower rows aren't built yet.
    await t.scrollUntilVisible(item, 80,
        scrollable: find.descendant(of: find.byType(drawer), matching: find.byType(Scrollable)).first);
    await t.tap(item, warnIfMissed: false);
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 250));
    }
    final e = t.takeException();
    if (e != null) problems.add('${role.name} · ${label(nav)}: ${e.toString().split('\n').first}');
  }
  // ignore: avoid_print
  for (final p in problems) {
    print('SMOKE $p');
  }
  expect(problems, isEmpty);

  // Let the shell's timers and pending requests wind down before teardown.
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 30));
}

void main() {
  testWidgets('field officer screens render with no data', (t) async {
    await _walk(t, AppRole.field, FieldOfficerShell(onSignOut: () {}), FieldDrawer, FieldNav.values, (n) => n.label);
  });

  testWidgets('rider screens render with no data', (t) async {
    await _walk(t, AppRole.rider, RiderShell(onSignOut: () {}), RiderDrawer, RiderNav.values, (n) => n.label);
  });

  testWidgets('field officer screens fit at 200% text size', (t) async {
    await _walk(t, AppRole.field, FieldOfficerShell(onSignOut: () {}), FieldDrawer, FieldNav.values, (n) => n.label,
        textScale: 2.0);
  });

  testWidgets('rider screens fit at 200% text size', (t) async {
    await _walk(t, AppRole.rider, RiderShell(onSignOut: () {}), RiderDrawer, RiderNav.values, (n) => n.label,
        textScale: 2.0);
  });

  testWidgets('Offline Navigation drawer entry opens the offline map section', (t) async {
    t.view.physicalSize = const Size(1290, 2796);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(ProviderScope(
      overrides: [
        currentProfileProvider.overrideWithValue(_profile(AppRole.rider)),
        supabaseClientProvider.overrideWithValue(SupabaseClient(
          'http://127.0.0.1:9',
          'smoke-test-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        )),
      ],
      child: MaterialApp(home: RiderShell(onSignOut: () {})),
    ));
    await t.pump(const Duration(milliseconds: 300));
    // The dashboard no longer shows the fake "Ready offline" coverage card.
    expect(find.text('Ready offline'), findsNothing);
    expect(find.text('MAPOG offline coverage'), findsNothing);

    await t.tap(find.byIcon(Icons.menu).first);
    await t.pump(const Duration(milliseconds: 400));
    final entry = find.descendant(of: find.byType(RiderDrawer), matching: find.text('Offline Navigation'));
    expect(entry, findsOneWidget);
    await t.tap(entry);
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 250));
    }
    expect(find.byType(RiderDrawer), findsNothing);
    expect(find.byType(OfflineNavPage), findsOneWidget);
    expect(find.text('Search places'), findsOneWidget);
    expect(find.text('Manage offline maps'), findsOneWidget);

    await _teardown(t);
  });

  testWidgets('Back closes the drawer instead of leaving the app', (t) async {
    await _pumpFo(t);
    await t.tap(find.byIcon(Icons.menu).first);
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byType(FieldDrawer), findsOneWidget);

    await t.binding.handlePopRoute();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byType(FieldDrawer), findsNothing);
    expect(find.byType(FieldOfficerShell), findsOneWidget);

    await _teardown(t);
  });

  testWidgets('FO sign-out warns while a report waits in the outbox', (t) async {
    await _pumpFo(t, overrides: [
      myOutboxProvider.overrideWith((ref) => Stream.value([
            OutboxEntry(
              id: 1, kind: incidentReportKind, clientId: 'c1', userId: 'u1',
              payload: const {'incident_type': 'flood'}, filePaths: const [], attempts: 0,
              lastError: null, createdAt: DateTime(2026, 9, 27), nextAttemptAt: DateTime(2026, 9, 27),
            ),
          ])),
    ]);

    await t.tap(find.byIcon(Icons.menu).first);
    await t.pump(const Duration(milliseconds: 400));
    final signOut = find.descendant(of: find.byType(FieldDrawer), matching: find.text('Sign out'));
    await t.scrollUntilVisible(signOut, 80,
        scrollable: find.descendant(of: find.byType(FieldDrawer), matching: find.byType(Scrollable)).first);
    await t.tap(signOut);
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('Sign out with unsent data?'), findsOneWidget);

    await _teardown(t);
  });

  testWidgets('empty My Tasks offers "Report an incident", which opens the wizard', (t) async {
    await _pumpFo(t);
    await _openFromDrawer(t, 'My Tasks');
    await _tapText(t, 'Report an incident');
    expect(find.text('What happened?'), findsOneWidget);

    await _teardown(t);
  });
}

Future<void> _pumpFo(WidgetTester t, {List<Override> overrides = const []}) async {
  t.view.physicalSize = const Size(3600, 2532);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(ProviderScope(
    overrides: [
      currentProfileProvider.overrideWithValue(_profile(AppRole.field)),
      supabaseClientProvider.overrideWithValue(SupabaseClient(
        'http://127.0.0.1:9',
        'smoke-test-key',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      )),
      ...overrides,
    ],
    child: MaterialApp(home: FieldOfficerShell(onSignOut: () {})),
  ));
  await t.pump(const Duration(milliseconds: 300));
}

Future<void> _openFromDrawer(WidgetTester t, String label) async {
  await t.tap(find.byIcon(Icons.menu).first);
  await t.pump(const Duration(milliseconds: 400));
  await t.tap(find.descendant(of: find.byType(FieldDrawer), matching: find.text(label)));
  await t.pump(const Duration(milliseconds: 400));
}

Future<void> _tapText(WidgetTester t, String text) async {
  final f = find.text(text);
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pump(const Duration(milliseconds: 400));
}

Future<void> _teardown(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 30));
}
