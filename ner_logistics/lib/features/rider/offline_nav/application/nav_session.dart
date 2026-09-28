import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../../../services/geo/geo_math.dart';
import '../../../../services/routing/osrm_models.dart';

enum NavStatus { guiding, rerouting, arrived }

/// Finds a new route from the rider's position (offline A* in the app).
typedef Rerouter = Future<OsrmRoute> Function(LatLng from, double? headingDeg);

/// Something to say. [urgent] cues are the "turn now" ones.
typedef CueSink = void Function(String text, {bool urgent});

/// Turn-by-turn progress over an [OsrmRoute]: snaps each GPS fix to the
/// route, tracks the next manoeuvre, ETA and arrival, detects leaving the
/// route and reroutes, and emits voice cues once per distance band.
///
/// Pure logic plus one stream subscription, so tests drive it with
/// [onFix] and a fake clock.
class NavSession extends ChangeNotifier {
  NavSession({
    required this._route,
    required this.destination,
    required this.destinationName,
    required this.reroute,
    required this.onCue,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final LatLng destination;
  final String destinationName;
  final Rerouter reroute;
  final CueSink onCue;
  final DateTime Function() _now;

  static const offRouteMinM = 40.0;
  static const rerouteGap = Duration(seconds: 15);

  OsrmRoute _route;
  OsrmRoute get route => _route;

  /// The abandoned route, drawn grey while a new one is computed.
  OsrmRoute? previousRoute;
  NavStatus status = NavStatus.guiding;
  String? rerouteError;
  int reroutes = 0;

  LatLng? position;
  double? heading;
  double alongM = 0;
  double offsetM = 0;
  bool weakGps = false;

  StreamSubscription<Position>? _sub;
  DateTime? _lastGoodFix, _weakSince, _offSince, _lastReroute;
  int _offCount = 0;
  int? _lastStep;

  /// False until a fix lands on the route. The route starts at the nearest
  /// road, so a rider still walking to it isn't "off route".
  bool _joined = false;
  final Set<(int, int)> _spoken = {};

  ({OsrmStep step, double inM})? get next => _route.nextStepAfter(alongM);

  /// Road metres left (step distances are road metres; geometry may differ).
  double get remainingM => math.max(0, _route.geometryLengthM - alongM) * _route.roadScale;
  double get remainingS => _route.durationFromS(alongM);
  DateTime get eta => _now().add(Duration(seconds: remainingS.round()));

  /// Starts consuming GPS fixes and announces the first instruction.
  void listen(Stream<Position> fixes) {
    _sub = fixes.listen(
      (p) =>
          onFix(LatLng(p.latitude, p.longitude), accuracy: p.accuracy, speed: p.speed, headingDeg: p.heading),
    );
    if (_route.steps.isNotEmpty) onCue(_route.steps.first.instruction);
  }

  void onFix(LatLng p, {double accuracy = 10, double speed = 0, double headingDeg = -1}) {
    if (status == NavStatus.arrived) return;
    final t = _now();
    // A poor fix shortly after a good one is noise; keep the good one.
    if (accuracy > 50) {
      _weakSince ??= t;
      if (_lastGoodFix != null && t.difference(_lastGoodFix!) < const Duration(seconds: 10)) {
        _updateWeak(t);
        return;
      }
    } else {
      _lastGoodFix = t;
      _weakSince = null;
    }
    _updateWeak(t);
    position = p;
    if (speed > 1 && headingDeg >= 0) heading = headingDeg;
    if (status == NavStatus.rerouting) {
      notifyListeners();
      return;
    }

    // Project onto a window just behind/ahead of the last position, so hill
    // switchbacks (road passing close to itself) can't make progress jump.
    final from = math.max(0.0, alongM - 200);
    final window = _route.sliceM(from, alongM + 2000);
    final pr = GeoMath.project(window, p);
    offsetM = pr.offsetM;

    if (offsetM > math.max(offRouteMinM, 1.5 * accuracy)) {
      _offCount++;
      _offSince ??= t;
      if (_joined &&
          (_offCount >= 3 || t.difference(_offSince!) >= const Duration(seconds: 8)) &&
          (_lastReroute == null || t.difference(_lastReroute!) >= rerouteGap)) {
        unawaited(_reroute(p, speed > 3 && headingDeg >= 0 ? headingDeg : null));
      }
      notifyListeners();
      return;
    }
    _offCount = 0;
    _offSince = null;
    _joined = true;
    alongM = from + pr.alongM;

    if (_route.geometryLengthM - alongM < 30 || GeoMath.distanceM(p, destination) < 40) {
      _arrive();
      return;
    }
    _cues();
    notifyListeners();
  }

  void _updateWeak(DateTime t) {
    weakGps = _weakSince != null && t.difference(_weakSince!) >= const Duration(seconds: 20);
  }

  Future<void> _reroute(LatLng from, double? headingDeg) async {
    _lastReroute = _now();
    previousRoute = _route;
    status = NavStatus.rerouting;
    rerouteError = null;
    notifyListeners();
    try {
      final r = await reroute(from, headingDeg);
      if (status != NavStatus.rerouting) return; // ended meanwhile
      _route = r;
      reroutes++;
      alongM = 0;
      offsetM = 0;
      _offCount = 0;
      _offSince = null;
      _spoken.clear();
      _lastStep = null;
      _joined = false;
      if (r.steps.isNotEmpty) onCue('Route updated. ${r.steps.first.instruction}');
    } catch (e) {
      rerouteError = '$e';
    } finally {
      if (status == NavStatus.rerouting) status = NavStatus.guiding;
      previousRoute = null;
      notifyListeners();
    }
  }

  void _cues() {
    final n = next;
    if (n == null) return;
    final i = _route.steps.indexOf(n.step);
    if (i != _lastStep) {
      // Just passed a manoeuvre: on a long stretch, say how long it is.
      final road = _route.roadAtM(alongM);
      if (_lastStep != null && n.inM > 5000 && road.isNotEmpty) {
        onCue('Continue on $road for ${spokenDistance(n.inM)}');
      }
      _lastStep = i;
    }
    final band = n.inM <= 80
        ? 2
        : n.inM <= 450 && n.inM > 100
        ? 1
        : n.inM <= 2000 && n.inM > 1000
        ? 0
        : null;
    if (band == null || !_spoken.add((i, band))) return;
    final text = n.step.instruction;
    onCue(
      band == 2 ? text : 'In ${spokenDistance(n.inM)}, ${text[0].toLowerCase()}${text.substring(1)}',
      urgent: band == 2,
    );
  }

  void _arrive() {
    status = NavStatus.arrived;
    alongM = _route.geometryLengthM;
    onCue('You have arrived at $destinationName');
    unawaited(_sub?.cancel());
    _sub = null;
    notifyListeners();
  }

  /// Stops listening to GPS (End Route, or leaving the screen).
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }
}

/// "400 metres" below 1 km (to 100 m), "23 kilometres" above (to 1 km).
String spokenDistance(double m) {
  if (m < 950) {
    final r = math.max(100, (m / 100).round() * 100);
    return '$r metres';
  }
  final km = (m / 1000).round();
  return km == 1 ? '1 kilometre' : '$km kilometres';
}
