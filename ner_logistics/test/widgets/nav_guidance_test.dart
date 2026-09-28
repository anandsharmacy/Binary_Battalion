import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:ner_logistics/core/supabase/supabase_providers.dart';
import 'package:ner_logistics/features/rider/offline_nav/presentation/nav_guidance_screen.dart';
import 'package:ner_logistics/features/rider/offline_nav/presentation/offline_nav_page.dart';
import 'package:ner_logistics/services/geo/geo_math.dart';
import 'package:ner_logistics/services/routing/osrm_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Position _fix(LatLng p) => Position(
      latitude: p.latitude,
      longitude: p.longitude,
      timestamp: DateTime(2026, 9, 27),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 10,
      speedAccuracy: 0,
    );

void main() {
  testWidgets('guidance shows the next manoeuvre, a compact bottom bar and an End action sheet', (t) async {
    t.view.physicalSize = const Size(1290, 2796);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    const a = LatLng(26.0, 91.8);
    final b = GeoMath.offsetM(a, 0, 1500), c = GeoMath.offsetM(b, 90, 500);
    final route = OsrmRoute(geometry: [a, b, c], distanceM: 2000, durationS: 240, steps: [
      OsrmStep(type: 'depart', distanceM: 1500, durationS: 180, location: a, ref: 'NH6'),
      OsrmStep(type: 'turn', modifier: 'right', distanceM: 500, durationS: 60, location: b, name: 'Dispur Road'),
      OsrmStep(type: 'arrive', distanceM: 0, durationS: 0, location: c),
    ]);
    final fixes = StreamController<Position>();
    await t.pumpWidget(ProviderScope(
      overrides: [
        supabaseClientProvider.overrideWithValue(SupabaseClient('http://127.0.0.1:9', 'test-key',
            authOptions: const AuthClientOptions(autoRefreshToken: false))),
      ],
      child: MaterialApp(
        home: NavGuidanceScreen(
          route: route,
          destination: NavDestination('Test depot', 'Place', c),
          graphPath: '/nonexistent',
          positions: fixes.stream,
        ),
      ),
    ));
    fixes.add(_fix(GeoMath.offsetM(a, 0, 1100)));
    await t.pump(const Duration(milliseconds: 300));

    expect(find.bySemanticsLabel(RegExp('400 m, Turn right onto Dispur Road')), findsOneWidget);
    // The bottom bar hugs its content instead of covering the map.
    expect(t.getSize(find.ancestor(of: find.byTooltip('Mute voice guidance'), matching: find.byType(SafeArea)).first).height,
        lessThan(200));

    await t.tap(find.text('End'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    expect(find.text('End Route'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 600));
    expect(find.byType(NavGuidanceScreen), findsOneWidget);

    fixes.add(_fix(GeoMath.offsetM(c, 270, 10)));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('You’ve arrived at Test depot'), findsOneWidget);
    unawaited(fixes.close());
    await t.pumpWidget(const SizedBox());
    // Let provider timers and pending requests wind down (as in the smoke tests).
    await t.pump(const Duration(seconds: 30));
  });
}
