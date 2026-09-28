import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:ner_logistics/features/rider/offline_nav/application/nav_session.dart';
import 'package:ner_logistics/services/geo/geo_math.dart';
import 'package:ner_logistics/services/routing/osrm_models.dart';

/// Straight 2 km road heading north, with a right turn at 1.5 km.
OsrmRoute _route() {
  const a = LatLng(26.0, 91.8);
  final b = GeoMath.offsetM(a, 0, 1500);
  final c = GeoMath.offsetM(b, 90, 500);
  return OsrmRoute(
    geometry: [a, b, c],
    distanceM: 2000,
    durationS: 200,
    steps: [
      OsrmStep(type: 'depart', distanceM: 1500, durationS: 150, location: a, ref: 'NH6'),
      OsrmStep(type: 'turn', modifier: 'right', distanceM: 500, durationS: 50, location: b, name: 'Dispur Road'),
      OsrmStep(type: 'arrive', distanceM: 0, durationS: 0, location: c),
    ],
  );
}

void main() {
  late DateTime now;
  late List<String> cues;
  late int reroutes;

  NavSession session(OsrmRoute r) => NavSession(
        route: r,
        destination: r.geometry.last,
        destinationName: 'Test depot',
        reroute: (from, heading) async {
          reroutes++;
          return OsrmRoute(geometry: [from, r.geometry.last], distanceM: 1000, durationS: 100);
        },
        onCue: (t, {urgent = false}) => cues.add(t),
        now: () => now,
      );

  setUp(() {
    now = DateTime(2026, 9, 27, 10);
    cues = [];
    reroutes = 0;
  });

  test('progress, remaining time and next step follow the fixes', () {
    final r = _route();
    final s = session(r);
    var lastRemaining = double.infinity;
    for (var m = 0.0; m <= 1400; m += 100) {
      now = now.add(const Duration(seconds: 10));
      s.onFix(GeoMath.offsetM(r.geometry.first, 0, m));
      expect(s.alongM, closeTo(m, 2));
      expect(s.remainingS, lessThan(lastRemaining));
      lastRemaining = s.remainingS;
    }
    expect(s.next!.step.type, 'turn');
    expect(s.next!.inM, closeTo(100, 3));
    expect(s.status, NavStatus.guiding);
    // Voice bands fire once each: 2 km band skipped (started inside it? no: at 1.5 km away → band 0),
    // then "In 400 metres…" and each only once.
    expect(cues.where((c) => c.startsWith('In 400 metres, turn right')).length, 1);
    expect(cues.where((c) => c.startsWith('In 2 kilometres') || c.startsWith('In 1 kilometre')).length, lessThanOrEqualTo(1));
  });

  test('three fixes 60 m off the route trigger exactly one reroute', () async {
    final r = _route();
    final s = session(r);
    s.onFix(r.geometry.first); // joins the route
    for (var i = 0; i < 3; i++) {
      now = now.add(const Duration(seconds: 1));
      s.onFix(GeoMath.offsetM(GeoMath.offsetM(r.geometry.first, 0, 300), 90, 60));
    }
    await Future<void>.delayed(Duration.zero);
    expect(reroutes, 1);
    expect(s.reroutes, 1);
    // Still off the (old) line right after: the 15 s gap holds.
    for (var i = 0; i < 3; i++) {
      now = now.add(const Duration(seconds: 1));
      s.onFix(const LatLng(26.02, 91.83));
    }
    await Future<void>.delayed(Duration.zero);
    expect(reroutes, 1);
  });

  test('a single inaccurate outlier does not reroute', () async {
    final r = _route();
    final s = session(r);
    s.onFix(r.geometry.first);
    now = now.add(const Duration(seconds: 1));
    s.onFix(GeoMath.offsetM(r.geometry.first, 90, 60), accuracy: 80);
    now = now.add(const Duration(seconds: 1));
    s.onFix(GeoMath.offsetM(r.geometry.first, 0, 20));
    await Future<void>.delayed(Duration.zero);
    expect(reroutes, 0);
  });

  test('a rider walking to the route start is not off-route', () async {
    final r = _route();
    final s = session(r);
    for (var i = 0; i < 5; i++) {
      now = now.add(const Duration(seconds: 3));
      s.onFix(GeoMath.offsetM(r.geometry.first, 270, 300));
    }
    await Future<void>.delayed(Duration.zero);
    expect(reroutes, 0);
  });

  test('arrives within 30 m of the end and says so', () {
    final r = _route();
    final s = session(r);
    s.onFix(r.geometry.first);
    s.onFix(GeoMath.offsetM(r.geometry[1], 0, 0));
    s.onFix(GeoMath.offsetM(r.geometry.last, 270, 20));
    expect(s.status, NavStatus.arrived);
    expect(cues.last, 'You have arrived at Test depot');
  });

  test('spoken distances round sensibly', () {
    expect(spokenDistance(430), '400 metres');
    expect(spokenDistance(40), '100 metres');
    expect(spokenDistance(1400), '1 kilometre');
    expect(spokenDistance(23400), '23 kilometres');
  });
}
