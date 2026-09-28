import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:ner_logistics/features/rider/offline_nav/data/places_index.dart';
import 'package:ner_logistics/features/rider/offline_nav/data/road_graph.dart';

void main() {
  late RoadGraph graph;
  setUpAll(() => graph = RoadGraph.fromBytes(
      File('assets/offline_nav/ner_roads.bin').readAsBytesSync()));

  test('Guwahati → Shillong on the bundled sample graph follows NH-6', () {
    final sw = Stopwatch()..start();
    final r = graph.route(const LatLng(26.1445, 91.7362), const LatLng(25.5788, 91.8933));
    sw.stop();
    // ignore: avoid_print
    print('route ${(r.distanceM / 1000).toStringAsFixed(1)} km, '
        '${(r.durationS / 60).round()} min, ${r.steps.length} steps, ${sw.elapsedMilliseconds} ms');
    for (final s in r.steps.take(40)) {
      // ignore: avoid_print
      print('  ${(s.distanceM / 1000).toStringAsFixed(2)} km  ${s.instruction}');
    }
    expect(r.distanceM / 1000, closeTo(97.2, 3));
    expect(r.steps.first.type, 'depart');
    expect(r.steps.last.type, 'arrive');
    expect(r.steps.any((s) => s.road == 'NH-6'), isTrue);
    expect(r.steps.fold<double>(0, (a, s) => a + s.distanceM), closeTo(r.distanceM, 1));
    expect(r.geometryLengthM, closeTo(r.distanceM, r.distanceM * 0.02));
    expect(sw.elapsedMilliseconds, lessThan(2000));
  });

  test('far from any road gives an honest error', () {
    expect(() => graph.route(const LatLng(27.5, 94.5), const LatLng(25.5788, 91.8933)),
        throwsA(isA<OfflineRouteException>()));
  });

  test('places search ranks prefix, then bigger places, then distance', () {
    final idx = PlacesIndex.parse(File('assets/offline_nav/ner_places.tsv').readAsStringSync());
    final r = idx.search('shillong');
    expect(r, isNotEmpty);
    expect(r.first.name.toLowerCase(), startsWith('shillong'));
    final p = PlacesIndex.parse('Big Town\ttown\t26\t91\nTownhall Clinic\tclinic\t26\t91\nA Town\tvillage\t26\t91\n');
    expect(p.search('town').map((e) => e.name), ['Townhall Clinic', 'Big Town', 'A Town']);
  });
}
