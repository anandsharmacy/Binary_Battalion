// ignore_for_file: avoid_print, curly_braces_in_flow_control_structures
// Dev tool: reference A* + timing for a NERG graph. The app router is
// lib/features/rider/offline_nav/data/road_graph.dart.
// Benchmark: load NERG v1 graph and run A* between two coordinates.
// dart run astar_bench.dart out_ne/ner_roads.bin 26.1445 91.7362 25.5788 91.8933
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

class Graph {
  late final int n, m, g;
  late final Int32List lat, lon, gLat, gLon;
  late final Uint32List first, target, distDm, timeDs, geomStart, nameIdx;
  late final Uint16List geomCount;
  late final Uint8List flags;
  Graph(Uint8List b) {
    final bd = ByteData.sublistView(b);
    if (String.fromCharCodes(b.sublist(0, 4)) != 'NERG') throw 'bad magic';
    n = bd.getUint32(8, Endian.little);
    m = bd.getUint32(12, Endian.little);
    g = bd.getUint32(16, Endian.little);
    var o = 24;
    Int32List i32(int c) { final v = Int32List.sublistView(b, o, o + 4 * c); o += 4 * c; return v; }
    Uint32List u32(int c) { final v = Uint32List.sublistView(b, o, o + 4 * c); o += 4 * c; return v; }
    lat = i32(n); lon = i32(n); first = u32(n + 1);
    target = u32(m); distDm = u32(m); timeDs = u32(m); geomStart = u32(m);
    // u16 array may be misaligned only if m is odd *after* it; it starts 4-aligned here.
    geomCount = Uint16List.sublistView(b, o, o + 2 * m); o += 2 * m;
    flags = Uint8List.sublistView(b, o, o + m); o += m;
    o += m; // pad
    nameIdx = Uint32List.view(Uint8List.fromList(b.sublist(o, o + 4 * m)).buffer); o += 4 * m; // copy: may be unaligned
    gLat = Int32List.view(Uint8List.fromList(b.sublist(o, o + 4 * g)).buffer); o += 4 * g;
    gLon = Int32List.view(Uint8List.fromList(b.sublist(o, o + 4 * g)).buffer); o += 4 * g;
  }

  int nearestNode(double la, double lo) {
    var best = -1; var bd = double.infinity;
    final k = math.cos(la * math.pi / 180);
    for (var i = 0; i < n; i++) {
      final dy = lat[i] / 1e6 - la, dx = (lon[i] / 1e6 - lo) * k;
      final d = dx * dx + dy * dy;
      if (d < bd) { bd = d; best = i; }
    }
    return best;
  }
}

double hav(double la1, double lo1, double la2, double lo2) {
  const r = 6371008.8, d = math.pi / 180;
  final h = math.pow(math.sin((la2 - la1) * d / 2), 2) +
      math.cos(la1 * d) * math.cos(la2 * d) * math.pow(math.sin((lo2 - lo1) * d / 2), 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(h)));
}

void main(List<String> a) {
  var sw = Stopwatch()..start();
  final gr = Graph(File(a[0]).readAsBytesSync());
  print('load ${sw.elapsedMilliseconds} ms  n=${gr.n} m=${gr.m}');
  final s = gr.nearestNode(double.parse(a[1]), double.parse(a[2]));
  final t = gr.nearestNode(double.parse(a[3]), double.parse(a[4]));
  sw.reset();
  final tla = gr.lat[t] / 1e6, tlo = gr.lon[t] / 1e6;
  const vmax = 60 / 3.6; // fastest class speed, keeps the heuristic admissible
  final gScore = Float64List(gr.n)..fillRange(0, gr.n, double.infinity);
  final prevEdge = Int32List(gr.n)..fillRange(0, gr.n, -1);
  final closed = Uint8List(gr.n);
  // binary heap of (f, node)
  var hf = Float64List(1024), hn = Int32List(1024); var hs = 0;
  void push(double f, int v) {
    if (hs == hf.length) { hf = Float64List(hs * 2)..setAll(0, hf); hn = Int32List(hs * 2)..setAll(0, hn); }
    var i = hs++;
    while (i > 0) { final p = (i - 1) >> 1; if (hf[p] <= f) break; hf[i] = hf[p]; hn[i] = hn[p]; i = p; }
    hf[i] = f; hn[i] = v;
  }
  int pop() {
    final top = hn[0]; final lf = hf[--hs], ln = hn[hs]; var i = 0;
    while (true) { var c = 2 * i + 1; if (c >= hs) break; if (c + 1 < hs && hf[c + 1] < hf[c]) c++; if (hf[c] >= lf) break; hf[i] = hf[c]; hn[i] = hn[c]; i = c; }
    hf[i] = lf; hn[i] = ln; return top;
  }
  gScore[s] = 0; push(0, s);
  var expanded = 0;
  while (hs > 0) {
    final u = pop();
    if (closed[u] == 1) continue;
    closed[u] = 1; expanded++;
    if (u == t) break;
    for (var e = gr.first[u]; e < gr.first[u + 1]; e++) {
      final v = gr.target[e];
      final ng = gScore[u] + gr.timeDs[e] / 10;
      if (ng < gScore[v]) {
        gScore[v] = ng; prevEdge[v] = e;
        push(ng + hav(gr.lat[v] / 1e6, gr.lon[v] / 1e6, tla, tlo) / vmax, v);
      }
    }
  }
  var dist = 0.0, edges = 0;
  // walk back: need source of edge; recover via node sequence
  var v = t;
  final path = <int>[t];
  while (v != s) {
    final e = prevEdge[v];
    if (e < 0) { print('no route'); return; }
    dist += gr.distDm[e] / 10; edges++;
    // find u: search the CSR (binary search on first[])
    var lo = 0, hi = gr.n - 1;
    while (lo < hi) { final mid = (lo + hi + 1) >> 1; if (gr.first[mid] <= e) lo = mid; else hi = mid - 1; }
    v = lo; path.add(v);
  }
  print('A* ${sw.elapsedMilliseconds} ms expanded=$expanded edges=$edges '
      'dist=${(dist / 1000).toStringAsFixed(1)} km time=${(gScore[t] / 60).toStringAsFixed(0)} min');
}
