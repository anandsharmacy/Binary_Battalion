import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:ner_logistics/core/offline/outbox_db.dart';
import 'package:ner_logistics/core/supabase/supabase_providers.dart';
import 'package:ner_logistics/features/field_officer/report/report_outbox.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ner_logistics/features/field_officer/alerts/alerts_screen.dart';
import 'package:ner_logistics/features/field_officer/report/report_screen.dart';
import 'package:ner_logistics/features/ml/presentation/ml_widgets.dart';
import 'package:ner_logistics/features/onboarding/splash_screen.dart';
import 'package:ner_logistics/features/profile/profile_sheet.dart';
import 'package:ner_logistics/features/rider/offline_nav/data/offline_packs.dart';
import 'package:ner_logistics/features/rider/offline_nav/presentation/offline_maps_screen.dart';
import 'package:ner_logistics/features/rider/offline_nav/presentation/offline_nav_page.dart';
import 'package:ner_logistics/features/tracking/application/live_riders_controller.dart';
import 'package:ner_logistics/features/tracking/presentation/live_riders_screen.dart';
import 'package:ner_logistics/mock_data/mock_officers.dart';
import 'package:ner_logistics/mock_data/models.dart';
import 'package:ner_logistics/shared/motion.dart';
import 'package:ner_logistics/shared/widgets/widgets.dart';
import 'package:ner_logistics/theme/app_theme.dart';
import 'package:shimmer/shimmer.dart';

import '../fixtures/sample_data.dart';

/// HIG checks (accessibility.md): 44pt targets, labelled controls, 4.5:1 text.
Future<void> _meetsHig(WidgetTester t, Widget child, {bool pumpApp = true}) async {
  final handle = t.ensureSemantics();
  if (pumpApp) await t.pumpWidget(_app(child));
  await t.pump(const Duration(milliseconds: 300));
  await expectLater(t, meetsGuideline(iOSTapTargetGuideline));
  await expectLater(t, meetsGuideline(labeledTapTargetGuideline));
  await expectLater(t, meetsGuideline(textContrastGuideline));
  handle.dispose();
}

Widget _app(Widget child, {bool reduceMotion = false}) => ProviderScope(
      // Signed-out client on an unreachable host and an in-memory outbox.
      overrides: [
        supabaseClientProvider.overrideWithValue(SupabaseClient(
          'http://127.0.0.1:9',
          'a11y-test-key',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        )),
        outboxDbProvider.overrideWith((ref) {
          final db = OutboxDb(NativeDatabase.memory());
          ref.onDispose(db.close);
          return db;
        }),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: Scaffold(body: child),
        ),
      ),
    );

Future<void> _tapText(WidgetTester t, String text) async {
  await t.ensureVisible(find.text(text));
  await t.tap(find.text(text));
  await t.pump(const Duration(milliseconds: 300));
}

/// Serves fixture riders instead of the live Supabase feed.
class _FixtureRiders extends LiveRidersController {
  @override
  Future<LiveRidersState> build() async => LiveRidersState(
        riders: {for (final r in sampleLiveRiders) r.userId: r},
        feed: LiveFeedStatus.live,
        now: DateTime.utc(2026, 1, 1, 10, 5),
      );
}

void main() {
  testWidgets('AppHeader meets HIG target, label and contrast rules', (t) async {
    await _meetsHig(
      t,
      AppHeader(
        title: 'Dashboard',
        subtitle: 'Officer · Region',
        roleInitials: 'FO',
        alertCount: 2,
        onMenu: () {},
        onBell: () {},
        onAvatar: () {},
      ),
    );
    expect(find.bySemanticsLabel('Alerts, 2 new'), findsOneWidget);
    expect(find.bySemanticsLabel('Menu'), findsOneWidget);
  });

  testWidgets('toggle row and scroll tabs meet HIG rules', (t) async {
    await _meetsHig(
      t,
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          MergeSemantics(
            child: Row(children: [
              const Expanded(child: Text('Critical alerts')),
              NerToggle(value: true, onChanged: (_) {}),
            ]),
          ),
          ScrollTabs<int>(
            tabs: const [
              ScrollTab(id: 0, label: 'All', count: 3),
              ScrollTab(id: 1, label: 'Open'),
            ],
            active: 0,
            onChange: (_) {},
          ),
        ]),
      ),
    );
  });

  testWidgets('report wizard step 1 meets HIG rules', (t) async {
    await _meetsHig(t, const ReportScreen());
    expect(find.bySemanticsLabel('Flood incident'), findsOneWidget);
  });

  testWidgets('splash chakra stays still with Reduce Motion on', (t) async {
    await t.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: SplashScreen(onLogIn: () {}, onCreateAccount: () {}),
      ),
    ));
    expect(
      find.descendant(
        of: find.byType(SpinningAshokaChakra),
        matching: find.byType(RotationTransition),
      ),
      findsNothing,
    );
  });

  testWidgets('sign-out asks only when data is unsent', (t) async {
    late BuildContext ctx;
    await t.pumpWidget(MaterialApp(
      home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      }),
    ));
    expect(await confirmSignOut(ctx, 0), isTrue);

    final pending = confirmSignOut(ctx, 1);
    await t.pumpAndSettle();
    expect(find.text('Sign out with unsent data?'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(await pending, isFalse);
  });

  testWidgets('report without a session is refused, never claimed as sent', (t) async {
    await t.pumpWidget(_app(const ReportScreen(initialType: IncidentType.flood)));
    await t.enterText(find.byType(TextField).first, 'NH-6 Km 26');
    await t.pump();
    await _tapText(t, 'Continue to Evidence');
    await _tapText(t, 'Continue without photos');
    await _tapText(t, 'Review report');
    await _tapText(t, 'Submit report');

    expect(find.textContaining('Sign in again'), findsOneWidget);
    expect(find.text('Report sent'), findsNothing);
    expect(find.textContaining('officer has been notified'), findsNothing);
  });

  testWidgets('evidence step offers labelled camera and gallery buttons (step 3)', (t) async {
    await t.pumpWidget(_app(const ReportScreen(initialType: IncidentType.flood)));
    await t.enterText(find.byType(TextField).first, 'NH-6 Km 26');
    await t.pump();
    await _tapText(t, 'Continue to Evidence');
    expect(find.text('Take photo'), findsOneWidget);
    expect(find.text('Upload from gallery'), findsOneWidget);
    await _meetsHig(t, const SizedBox(), pumpApp: false);
    expect(find.textContaining('09:41'), findsNothing);
  });

  testWidgets('alert card meets HIG rules; acknowledge is local and honest', (t) async {
    await _meetsHig(t, const AlertsScreen(alerts: sampleAlerts));
    await t.tap(find.text('Acknowledge'));
    await t.pump();
    expect(find.text('Acknowledged on this device'), findsOneWidget);
  });

  testWidgets('alerts tab ink paints on the visible white surface', (t) async {
    await t.pumpWidget(_app(const AlertsScreen(alerts: sampleAlerts)));
    final tab = find.ancestor(of: find.text('High'), matching: find.byType(InkWell)).first;
    final surface = t.widget<Material>(
        find.ancestor(of: tab, matching: find.byType(Material)).first);
    expect(surface.color, Colors.white);
  });

  testWidgets('profile header photo badge meets the 44pt target rule', (t) async {
    final handle = t.ensureSemantics();
    await t.pumpWidget(_app(ProfileSheet(
      role: AppRole.field,
      officer: fieldOfficer,
      onClose: () {},
      onSignOut: () {},
    )));
    await t.pump(const Duration(milliseconds: 500));
    final badge = find.bySemanticsLabel('Change profile photo');
    expect(t.getSize(badge).shortestSide, greaterThanOrEqualTo(44));
    handle.dispose();
  });

  testWidgets('loading shows placeholder rows; no shimmer with Reduce Motion', (t) async {
    const loading = MlAsync<int>(value: AsyncValue.loading(), builder: _never);
    await t.pumpWidget(_app(loading));
    expect(find.byType(PlaceholderRows), findsOneWidget);
    expect(find.byType(Shimmer), findsOneWidget);

    await t.pumpWidget(_app(loading, reduceMotion: true));
    expect(find.byType(PlaceholderRows), findsOneWidget);
    expect(find.byType(Shimmer), findsNothing);
  });

  testWidgets('screen change settles in one pump with Reduce Motion', (t) async {
    var id = 0;
    await t.pumpWidget(_app(
      StatefulBuilder(
        builder: (c, set) => GestureDetector(
          onTap: () => set(() => id++),
          child: screenFade(c, id, Text('screen $id')),
        ),
      ),
      reduceMotion: true,
    ));
    await t.tap(find.text('screen 0'));
    await t.pump();
    await t.pump();
    expect(find.text('screen 0'), findsNothing);
    expect(find.text('screen 1'), findsOneWidget);
  });

  testWidgets('app header title is a heading', (t) async {
    final handle = t.ensureSemantics();
    await t.pumpWidget(_app(AppHeader(
      title: 'Dashboard',
      subtitle: 'Officer · Region',
      roleInitials: 'FO',
      onMenu: () {},
      onBell: () {},
      onAvatar: () {},
    )));
    expect(t.getSemantics(find.text('Dashboard')), isSemantics(isHeader: true));
    handle.dispose();
  });

  testWidgets('rider search filters the list and clear restores it', (t) async {
    t.view.physicalSize = const Size(1170, 2532);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(ProviderScope(
      overrides: [liveRidersProvider.overrideWith(_FixtureRiders.new)],
      child: MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(body: LiveRidersScreen()),
      ),
    ));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Asha Devi'), findsOneWidget);
    expect(find.text('Bikram Singh'), findsOneWidget);

    await t.enterText(find.byType(TextField), 'ml05');
    await t.pump();
    expect(find.text('Asha Devi'), findsNothing);
    expect(find.text('Bikram Singh'), findsOneWidget);

    await t.enterText(find.byType(TextField), 'zzz');
    await t.pump();
    expect(find.text('No riders match'), findsOneWidget);
    await _tapText(t, 'Clear search');
    expect(find.text('Asha Devi'), findsOneWidget);
    expect(find.text('Bikram Singh'), findsOneWidget);

    await t.pumpWidget(const SizedBox());
  });

  testWidgets('Offline Navigation screens meet HIG target, label and contrast rules', (t) async {
    t.view.physicalSize = const Size(1290, 2796);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    // No plugins in tests: packs report an honest error with a retry.
    await _meetsHig(t, OfflineNavPage(packs: OfflinePacks(root: () async => throw 'no disk')));
    expect(find.text('Search places'), findsOneWidget);
    expect(find.bySemanticsLabel('Resize sheet'), findsOneWidget);
    expect(find.byTooltip('Show my location'), findsOneWidget);

    await _meetsHig(t, OfflineMapsScreen(packs: OfflinePacks(root: () async => throw 'no disk', baseUrl: '')));
    expect(find.text('Full-region pack not available yet'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
}

Widget _never(int _) => const SizedBox();
