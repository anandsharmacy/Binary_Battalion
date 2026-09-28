import 'package:latlong2/latlong.dart';

import '../../../../services/geo/geo_math.dart';

/// A searchable OSM place or POI from `ner_places.tsv`.
class Place {
  final String name;
  final String kind; // city, town, village, … hospital, fuel, police, …
  final LatLng point;
  const Place(this.name, this.kind, this.point);

  String get kindLabel => switch (kind) {
    'neighbourhood' => 'Neighbourhood',
    'fuel' => 'Fuel station',
    _ => kind.isEmpty ? 'Place' : '${kind[0].toUpperCase()}${kind.substring(1)}',
  };
}

/// Offline gazetteer: `name \t kind \t lat \t lon` rows, searched in memory.
class PlacesIndex {
  final List<Place> places;
  final List<String> _keys;

  PlacesIndex(this.places) : _keys = [for (final p in places) p.name.toLowerCase()];

  factory PlacesIndex.parse(String tsv) => PlacesIndex([
    for (final line in tsv.split('\n'))
      if (line.split('\t') case [final name, final kind, final lat, final lon])
        if (double.tryParse(lat) != null && double.tryParse(lon) != null)
          Place(name, kind, LatLng(double.parse(lat), double.parse(lon))),
  ]);

  static const _kindRank = {
    'city': 0,
    'town': 1,
    'suburb': 2,
    'village': 3,
    'neighbourhood': 4,
    'locality': 4,
    'hamlet': 5,
  };

  /// Prefix matches beat word-prefix matches beat substrings; then bigger
  /// places first, then nearer to [near].
  // ponytail: lowercase only, no diacritic folding; NE OSM names here are
  // plain ASCII. Add folding if Assamese/Bengali-script names get indexed.
  List<Place> search(String query, {LatLng? near, int limit = 20}) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final hits = <(int, int, double, Place)>[];
    for (var i = 0; i < places.length; i++) {
      final k = _keys[i];
      final int match;
      if (k.startsWith(q)) {
        match = 0;
      } else if (k.contains(' $q') || k.contains('-$q') || k.contains('($q')) {
        match = 1;
      } else if (k.contains(q)) {
        match = 2;
      } else {
        continue;
      }
      final p = places[i];
      hits.add((match, _kindRank[p.kind] ?? 6, near == null ? 0 : GeoMath.distanceM(near, p.point), p));
    }
    hits.sort(
      (a, b) => a.$1 != b.$1
          ? a.$1 - b.$1
          : a.$2 != b.$2
          ? a.$2 - b.$2
          : a.$3.compareTo(b.$3),
    );
    return [for (final h in hits.take(limit)) h.$4];
  }
}
