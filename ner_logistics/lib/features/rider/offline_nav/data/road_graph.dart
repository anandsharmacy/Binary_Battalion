import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

import '../../../../services/geo/geo_math.dart';
import '../../../../services/routing/osrm_models.dart';

/// Thrown when no offline route can be produced. [message] is shown as is.
class OfflineRouteException implements Exception {
  final String message;
  const OfflineRouteException(this.message);
  @override
  String toString() => message;
}

/// Routes from [from] to [to] on the NERG graph at [graphPath], off the UI
/// thread. Returns the app's usual [OsrmRoute] so the existing instruction,
/// ETA and next-step code works unchanged.
// ponytail: reloads the graph per route (~25 ms desktop for the full 100 MB
// graph); keep a long-lived isolate if reroutes feel slow on low-end phones.
Future<OsrmRoute> routeOffline(String graphPath, LatLng from, LatLng to, {double? headingDeg}) => Isolate.run(
  () => RoadGraph.fromBytes(File(graphPath).readAsBytesSync()).route(from, to, headingDeg: headingDeg),
);

/// Road class speeds live in the graph (time per edge); 60 km/h is the
/// fastest class, which keeps the A* heuristic admissible.
const _vmaxMs = 60 / 3.6;
const _noName = 0xFFFFFFFF;

/// Snap of a point onto one directed edge.
class _Snap {
  final int edge;
  final double t; // fraction along the edge in travel direction
  final double offsetM;
  const _Snap(this.edge, this.t, this.offsetM);
}

/// NERG v1 road graph (format in tool/build_nav_graph.py): zero-copy typed
/// views over the file bytes, CSR adjacency sorted by source node.
class RoadGraph {
  late final int n, m, g, k;
  late final Int32List _lat, _lon, _gLat, _gLon;
  late final Uint32List _first, _target, _distDm, _timeDs, _geomStart, _nameIdx, _nameOff;
  late final Uint16List _geomCount;
  late final Uint8List _flags, _nameBytes;

  RoadGraph.fromBytes(Uint8List b) {
    if (b.length < 24 || String.fromCharCodes(b.sublist(0, 4)) != 'NERG') {
      throw const FormatException('Not a NERG road graph');
    }
    final bd = ByteData.sublistView(b);
    if (bd.getUint32(4, Endian.little) != 1) {
      throw const FormatException('Unsupported NERG version');
    }
    n = bd.getUint32(8, Endian.little);
    m = bd.getUint32(12, Endian.little);
    g = bd.getUint32(16, Endian.little);
    k = bd.getUint32(20, Endian.little);
    // Views need 4-byte alignment; copy once if the buffer isn't aligned.
    final bytes = b.offsetInBytes % 4 == 0 ? b : Uint8List.fromList(b);
    var o = 24;
    Int32List i32(int c) => Int32List.sublistView(bytes, o, o += 4 * c);
    Uint32List u32(int c) => Uint32List.sublistView(bytes, o, o += 4 * c);
    _lat = i32(n);
    _lon = i32(n);
    _first = u32(n + 1);
    _target = u32(m);
    _distDm = u32(m);
    _timeDs = u32(m);
    _geomStart = u32(m);
    _geomCount = Uint16List.sublistView(bytes, o, o += 2 * m);
    _flags = Uint8List.sublistView(bytes, o, o += m);
    o += m; // pad
    _nameIdx = u32(m);
    _gLat = i32(g);
    _gLon = i32(g);
    _nameOff = u32(k + 1);
    _nameBytes = Uint8List.sublistView(bytes, o);
  }

  LatLng node(int i) => LatLng(_lat[i] / 1e6, _lon[i] / 1e6);

  /// Source node of edge [e]: binary search over the CSR offsets.
  int source(int e) {
    var lo = 0, hi = n - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_first[mid] <= e) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  int outDegree(int v) => _first[v + 1] - _first[v];
  int roadClass(int e) => _flags[e] & 0x0F;
  bool roundabout(int e) => _flags[e] & 0x10 != 0;
  double distM(int e) => _distDm[e] / 10;
  double timeS(int e) => _timeDs[e] / 10;

  /// `(ref, name)` for edge [e], split from the stored "ref|name".
  (String, String) names(int e) {
    final i = _nameIdx[e];
    if (i == _noName) return ('', '');
    final s = utf8.decode(_nameBytes.sublist(_nameOff[i], _nameOff[i + 1]));
    final bar = s.indexOf('|');
    return bar < 0 ? ('', s) : (s.substring(0, bar), s.substring(bar + 1));
  }

  /// What the rider sees on signs: the ref if any, else the name.
  String _roadKey(int e) {
    final (ref, name) = names(e);
    return ref.split(';').first.trim().isNotEmpty ? ref.split(';').first.trim() : name;
  }

  /// Edge shape in travel direction: source, interior points, target.
  List<LatLng> edgeLine(int e, [int? src]) {
    final s = _geomStart[e], c = _geomCount[e];
    final rev = _flags[e] & 0x20 != 0;
    return [
      node(src ?? source(e)),
      for (var j = 0; j < c; j++)
        LatLng(_gLat[s + (rev ? c - 1 - j : j)] / 1e6, _gLon[s + (rev ? c - 1 - j : j)] / 1e6),
      node(_target[e]),
    ];
  }

  /// Every edge within 1 m of the best snap (a two-way road gives both
  /// directions). With [headingDeg], edges pointing >90° away are skipped so
  /// a reroute never starts the rider backwards.
  // ponytail: O(E) scan per snap (~1.4M segments on the full graph); add a
  // 0.01° grid index if this passes ~300 ms on device.
  List<_Snap> _snap(LatLng p, {double? headingDeg, double maxM = 2000}) {
    final kx = math.cos(p.latitude * math.pi / 180) * GeoMath.earthRadiusM * math.pi / 180;
    const ky = GeoMath.earthRadiusM * math.pi / 180;
    final pLat = p.latitude * 1e6, pLon = p.longitude * 1e6;
    final reject = maxM / ky * 1e6; // µdeg latitude beyond which a segment can't match
    final hits = <_Snap>[];
    var best = double.infinity;
    for (var v = 0; v < n; v++) {
      for (var e = _first[v]; e < _first[v + 1]; e++) {
        final s = _geomStart[e], c = _geomCount[e];
        final rev = _flags[e] & 0x20 != 0;
        // Walk the shape without allocating LatLngs.
        var aLat = _lat[v].toDouble(), aLon = _lon[v].toDouble();
        var along = 0.0, bestHere = double.infinity, bestAlong = 0.0;
        double segBearing = 0;
        for (var j = 0; j <= c; j++) {
          final double bLat, bLon;
          if (j == c) {
            bLat = _lat[_target[e]].toDouble();
            bLon = _lon[_target[e]].toDouble();
          } else {
            final gi = s + (rev ? c - 1 - j : j);
            bLat = _gLat[gi].toDouble();
            bLon = _gLon[gi].toDouble();
          }
          final ax = (aLon - pLon) / 1e6 * kx, ay = (aLat - pLat) / 1e6 * ky;
          final bx = (bLon - pLon) / 1e6 * kx, by = (bLat - pLat) / 1e6 * ky;
          final dx = bx - ax, dy = by - ay;
          final len = math.sqrt(dx * dx + dy * dy);
          final near =
              (aLat - pLat).abs() < reject ||
              (bLat - pLat).abs() < reject ||
              (aLat - pLat).sign != (bLat - pLat).sign;
          if (near && len > 0) {
            final t = (-(ax * dx + ay * dy) / (len * len)).clamp(0.0, 1.0);
            final px = ax + dx * t, py = ay + dy * t;
            final d = math.sqrt(px * px + py * py);
            if (d < bestHere) {
              bestHere = d;
              bestAlong = along + len * t;
              segBearing = math.atan2(dx, dy) * 180 / math.pi;
            }
          }
          along += len;
          aLat = bLat;
          aLon = bLon;
        }
        if (bestHere > maxM || bestHere > best + 1) continue;
        if (headingDeg != null && _angle(segBearing - headingDeg).abs() > 90) continue;
        if (bestHere < best - 1) hits.removeWhere((h) => h.offsetM > bestHere + 1);
        best = math.min(best, bestHere);
        hits.add(_Snap(e, along == 0 ? 0 : bestAlong / along, bestHere));
      }
    }
    hits.removeWhere((h) => h.offsetM > best + 1);
    return hits;
  }

  /// Fastest route by A* on travel time. Starts and ends part-way along the
  /// nearest edges, so the line begins and ends at the snapped points.
  OsrmRoute route(LatLng from, LatLng to, {double? headingDeg}) {
    var starts = _snap(from, headingDeg: headingDeg);
    if (starts.isEmpty && headingDeg != null) starts = _snap(from);
    final ends = _snap(to);
    if (starts.isEmpty) {
      throw const OfflineRouteException('You are more than 2 km from any road in the downloaded map area.');
    }
    if (ends.isEmpty) {
      throw const OfflineRouteException(
        'No offline road data near this destination. Download the region or drop a pin closer to a road.',
      );
    }

    final gScore = Float64List(n)..fillRange(0, n, double.infinity);
    final prevEdge = Int32List(n)..fillRange(0, n, -1);
    final startEdgeOf = Int32List(n)..fillRange(0, n, -1);
    final goalExtra = <int, _Snap>{}; // node -> destination snap reached from it
    for (final s in ends) {
      final u = source(s.edge);
      final cur = goalExtra[u];
      if (cur == null || s.t * timeS(s.edge) < cur.t * timeS(cur.edge)) goalExtra[u] = s;
    }
    final goal = to;
    double h(int v) => GeoMath.distanceM(LatLng(_lat[v] / 1e6, _lon[v] / 1e6), goal) / _vmaxMs;

    final heap = _Heap();
    // Same-edge trip: start and end on one edge, destination ahead.
    var bestTotal = double.infinity;
    _Snap? directStart, directEnd;
    for (final s in starts) {
      for (final d in ends) {
        if (s.edge == d.edge && d.t >= s.t) {
          final c = (d.t - s.t) * timeS(s.edge);
          if (c < bestTotal) {
            bestTotal = c;
            directStart = s;
            directEnd = d;
          }
        }
      }
      final v = _target[s.edge];
      final c = (1 - s.t) * timeS(s.edge);
      if (c < gScore[v]) {
        gScore[v] = c;
        startEdgeOf[v] = starts.indexOf(s);
        prevEdge[v] = -1;
        heap.push(c + h(v), v);
      }
    }

    int bestGoal = -1;
    final closed = Uint8List(n);
    while (heap.isNotEmpty) {
      if (heap.minF >= bestTotal) break;
      final u = heap.pop();
      if (closed[u] == 1) continue;
      closed[u] = 1;
      final extra = goalExtra[u];
      if (extra != null) {
        final total = gScore[u] + extra.t * timeS(extra.edge);
        if (total < bestTotal) {
          bestTotal = total;
          bestGoal = u;
          directStart = null;
        }
      }
      for (var e = _first[u]; e < _first[u + 1]; e++) {
        final v = _target[e];
        final ng = gScore[u] + timeS(e);
        if (ng < gScore[v]) {
          gScore[v] = ng;
          prevEdge[v] = e;
          startEdgeOf[v] = startEdgeOf[u];
          heap.push(ng + h(v), v);
        }
      }
    }

    if (directStart != null && directEnd != null) {
      return _build([(directStart.edge, directStart.t, directEnd.t)]);
    }
    if (bestGoal < 0) {
      throw const OfflineRouteException(
        'No road connection found in the offline map between here and the destination.',
      );
    }
    // Walk back from the goal node to the node the start edge led into.
    final middle = <int>[];
    var v = bestGoal;
    while (prevEdge[v] >= 0) {
      middle.add(prevEdge[v]);
      v = source(prevEdge[v]);
    }
    final start = starts[startEdgeOf[v]];
    final end = goalExtra[bestGoal]!;
    return _build([
      (start.edge, start.t, 1.0),
      for (final e in middle.reversed) (e, 0.0, 1.0),
      (end.edge, 0.0, end.t),
    ]);
  }

  /// Geometry, totals and OSRM-style steps for a list of (edge, from, to)
  /// fractions in travel order.
  OsrmRoute _build(List<(int, double, double)> legs) {
    final geometry = <LatLng>[];
    var distance = 0.0, duration = 0.0;
    final lines = <List<LatLng>>[];
    for (final (e, a, b) in legs) {
      final line = edgeLine(e);
      lines.add(line);
      final cum = GeoMath.cumulativeM(line);
      final part = GeoMath.sliceM(line, a * cum.last, b * cum.last, cum);
      geometry.addAll(geometry.isEmpty ? part : part.skip(1));
      distance += (b - a) * distM(e);
      duration += (b - a) * timeS(e);
    }

    // Manoeuvres at junctions, positioned by distance along the route.
    final raw = <({String type, String? modifier, int edge, LatLng at, double m, double s, int? exit})>[];
    var m = 0.0, s = 0.0;
    raw.add((
      type: 'depart',
      modifier: null,
      edge: legs.first.$1,
      at: geometry.first,
      m: 0,
      s: 0,
      exit: null,
    ));
    for (var i = 0; i < legs.length; i++) {
      final (e, a, b) = legs[i];
      m += (b - a) * distM(e);
      s += (b - a) * timeS(e);
      if (i == legs.length - 1) break;
      final next = legs[i + 1].$1;
      final junction = _target[e];
      final at = node(junction);
      final inLine = lines[i], outLine = lines[i + 1];
      final delta = _angle(
        GeoMath.bearingDeg(outLine[0], outLine[1]) -
            GeoMath.bearingDeg(inLine[inLine.length - 2], inLine.last),
      );
      final sameName = _roadKey(e) == _roadKey(next);
      if (roundabout(next) && !roundabout(e)) {
        // Count exits passed until the route leaves the roundabout.
        var exit = 0;
        for (var j = i + 1; j < legs.length && roundabout(legs[j].$1); j++) {
          if (outDegree(_target[legs[j].$1]) > 1) exit++;
          if (j + 1 < legs.length && !roundabout(legs[j + 1].$1)) break;
        }
        final leave = legs.indexWhere((l) => !roundabout(l.$1), i + 1);
        raw.add((
          type: 'roundabout',
          modifier: null,
          edge: leave < 0 ? next : legs[leave].$1,
          at: at,
          m: m,
          s: s,
          exit: math.max(1, exit),
        ));
        continue;
      }
      if (roundabout(e) || roundabout(next)) continue;
      final abs = delta.abs();
      final isJunction = outDegree(junction) > 2;
      if (abs >= 20 && isJunction && (!sameName || abs >= 45)) {
        raw.add((type: 'turn', modifier: _modifier(delta), edge: next, at: at, m: m, s: s, exit: null));
      } else if (!sameName && _roadKey(next).isNotEmpty) {
        raw.add((type: 'new name', modifier: 'straight', edge: next, at: at, m: m, s: s, exit: null));
      }
    }
    raw.add((type: 'arrive', modifier: null, edge: legs.last.$1, at: geometry.last, m: m, s: s, exit: null));

    final steps = <OsrmStep>[];
    for (var i = 0; i < raw.length; i++) {
      final r = raw[i];
      final end = i + 1 < raw.length ? raw[i + 1] : r;
      final (ref, name) = r.type == 'arrive' ? ('', '') : names(r.edge);
      steps.add(
        OsrmStep(
          type: r.type,
          modifier: r.modifier,
          ref: ref,
          name: name,
          distanceM: end.m - r.m,
          durationS: end.s - r.s,
          location: r.at,
          exit: r.exit,
        ),
      );
    }
    return OsrmRoute(geometry: geometry, distanceM: distance, durationS: duration, steps: steps);
  }

  static String _modifier(double delta) {
    final a = delta.abs();
    final side = delta > 0 ? 'right' : 'left';
    if (a < 20) return 'straight';
    if (a < 60) return 'slight $side';
    if (a < 130) return side;
    if (a < 170) return 'sharp $side';
    return 'uturn';
  }
}

/// Normalises an angle difference to (-180, 180].
double _angle(double d) {
  var x = d % 360;
  if (x > 180) x -= 360;
  if (x <= -180) x += 360;
  return x;
}

/// Binary min-heap of (f, node) on typed arrays.
class _Heap {
  var _f = Float64List(1024);
  var _v = Int32List(1024);
  var _size = 0;

  bool get isNotEmpty => _size > 0;
  double get minF => _f[0];

  void push(double f, int v) {
    if (_size == _f.length) {
      _f = Float64List(_size * 2)..setAll(0, _f);
      _v = Int32List(_size * 2)..setAll(0, _v);
    }
    var i = _size++;
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (_f[p] <= f) break;
      _f[i] = _f[p];
      _v[i] = _v[p];
      i = p;
    }
    _f[i] = f;
    _v[i] = v;
  }

  int pop() {
    final top = _v[0];
    final lf = _f[--_size], lv = _v[_size];
    var i = 0;
    while (true) {
      var c = 2 * i + 1;
      if (c >= _size) break;
      if (c + 1 < _size && _f[c + 1] < _f[c]) c++;
      if (_f[c] >= lf) break;
      _f[i] = _f[c];
      _v[i] = _v[c];
      i = c;
    }
    _f[i] = lf;
    _v[i] = lv;
    return top;
  }
}
