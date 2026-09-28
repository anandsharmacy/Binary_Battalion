import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ner_logistics/features/field_officer/trip/route_screen.dart';
import 'package:ner_logistics/features/rider/rider_route_panel.dart';
import 'package:ner_logistics/mock_data/models.dart';
import 'package:ner_logistics/services/geo_providers.dart';
import 'package:ner_logistics/services/gis/spatial_analytics.dart';
import 'package:ner_logistics/shared/analytics/geo_analytics_widgets.dart';
import '../fixtures/sample_data.dart';
import '../fixtures/trip_fixtures.dart';

/// A trip is assigned, and routing is answered from the fixture — no network in tests.
final _offlineRouting = [
  fieldTripScenarioProvider.overrideWithValue(fieldTripScenario),
  riderTripScenarioProvider.overrideWithValue(riderTripScenario),
  fieldTripPlanProvider.overrideWith((ref) => TripFixtures.fieldPlan()),
  fieldTripDetourProvider.overrideWith((ref) => TripFixtures.fieldDetour()),
  riderTripPlanProvider.overrideWith((ref) => TripFixtures.riderPlan()),
  // Hazards from the sample zones (the app ships none).
  riderRouteHazardsProvider.overrideWith((ref) => const LocalSpatialAnalytics(
        floodZones: sampleFloodZones,
        landslideZones: sampleLandslideZones,
        safeZones: sampleSafeZones,
      ).hazardsAlong(TripFixtures.riderPlan().ahead)),
];

Widget _app(Widget child) => ProviderScope(
      overrides: _offlineRouting,
      child: MaterialApp(home: Scaffold(body: child)),
    );

Future<void> _phone(WidgetTester t) async {
  t.view.physicalSize = const Size(1170, 2532);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

void main() {
  RouteScreen screen(TripPhase phase, {bool post = false, ValueChanged<TripPhase>? onPhase}) =>
      RouteScreen(
        phase: phase,
        postReroute: post,
        riskUpgraded: false,
        isOffline: false,
        onPhaseChange: onPhase ?? (_) {},
        onRerouted: () {},
        onNotNow: () {},
        onReport: () {},
      );

  testWidgets('trip sheets show OSRM-derived hazard, detour and turns', (t) async {
    await _phone(t);
    await t.pumpWidget(_app(screen(TripPhase.interrupt)));
    await t.pump(const Duration(milliseconds: 50));
    expect(find.text('NH-6 Km 150–153 is now high risk'), findsOneWidget);
    expect(find.textContaining('78% confidence'), findsOneWidget);

    await t.pumpWidget(_app(screen(TripPhase.rerouted)));
    await t.pump(const Duration(milliseconds: 50));
    final via = TripFixtures.fieldDetour().result.via!;
    expect(find.text('Rerouted via $via'), findsOneWidget);
    expect(find.textContaining('vs. original'), findsOneWidget);
    expect(find.text('Follow new route'), findsOneWidget);

    await t.pumpWidget(_app(screen(TripPhase.active, post: true)));
    await t.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('Lumshnong'), findsNothing);
    expect(find.textContaining('Sonapur'), findsWidgets);

    await t.pumpWidget(const SizedBox()); // disposes timers
  });

  testWidgets('Compare opens a system sheet that Back closes, keeping the trip', (t) async {
    await _phone(t);
    await t.pumpWidget(_app(screen(TripPhase.rerouted)));
    await t.pump(const Duration(milliseconds: 50));
    await t.ensureVisible(find.text('Compare'));
    await t.tap(find.text('Compare'));
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('Compare routes'), findsOneWidget);

    await t.binding.handlePopRoute();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('Compare routes'), findsNothing);
    expect(find.byType(RouteScreen), findsOneWidget);

    await t.pumpWidget(const SizedBox()); // disposes timers
  });

  testWidgets('calculating phase advances once the detour is known', (t) async {
    await _phone(t);
    TripPhase? next;
    await t.pumpWidget(_app(screen(TripPhase.active, onPhase: (p) => next = p)));
    await t.pump(const Duration(milliseconds: 50));
    await t.pumpWidget(_app(screen(TripPhase.calculating, onPhase: (p) => next = p)));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Candidate route'), findsOneWidget);
    await t.pump(const Duration(seconds: 2));
    expect(next, TripPhase.rerouted);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('rider panel shows live route metrics and hazards', (t) async {
    await _phone(t);
    final assignment = sampleDeliveries.first;
    await t.pumpWidget(_app(SingleChildScrollView(
      child: Column(children: [
        RiderRoutePanel(assignment: assignment, isOffline: false, statusLabel: 'En route'),
        const RiderRouteHazards(),
      ]),
    )));
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('Next instruction'), findsOneWidget);
    expect(find.text(assignment.distanceRemaining), findsNothing); // replaced by routed value
    expect(find.text('Umling–Nongpoh slope'), findsOneWidget);
    expect(find.text('Find safe alternate'), findsWidgets);
  });

  testWidgets('analytics panel falls back to on-device estimates', (t) async {
    await _phone(t);
    await t.pumpWidget(_app(const SingleChildScrollView(child: SpatialAnalyticsPanel())));
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('ON-DEVICE ESTIMATE'), findsOneWidget);
    expect(find.text('Highway risk exposure'), findsOneWidget);
    expect(find.text('Incidents by area'), findsOneWidget);
  });
}
