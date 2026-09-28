import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:sqlite3/sqlite3.dart';

/// Attribution every OpenMapTiles-rendered pack must show.
const offlineTilesAttribution = '© OpenMapTiles © OpenStreetMap contributors';

/// One opened `.mbtiles` pack and its metadata.
class MbtilesPack {
  final Database db;
  final String name;
  final int minZoom, maxZoom;

  /// (west, south, east, north), or null when the pack doesn't say.
  final List<double>? bounds;

  MbtilesPack._(this.db, this.name, this.minZoom, this.maxZoom, this.bounds);

  factory MbtilesPack(Database db, {String fallbackName = 'Offline map'}) {
    final meta = {
      for (final r in db.select('SELECT name, value FROM metadata'))
        r['name'] as String: r['value'] as String,
    };
    final b = meta['bounds']?.split(',').map(double.tryParse).toList();
    return MbtilesPack._(
      db,
      meta['name'] ?? fallbackName,
      int.tryParse(meta['minzoom'] ?? '') ?? 0,
      int.tryParse(meta['maxzoom'] ?? '') ?? 14,
      b != null && b.length == 4 && !b.contains(null) ? b.cast<double>() : null,
    );
  }

  bool covers(LatLng p) {
    final b = bounds;
    return b != null &&
        p.longitude >= b[0] &&
        p.latitude >= b[1] &&
        p.longitude <= b[2] &&
        p.latitude <= b[3];
  }

  Uint8List? tile(int z, int x, int y) {
    final r = db.select(
      'SELECT tile_data FROM tiles WHERE zoom_level = ? AND tile_column = ? AND tile_row = ?',
      [z, x, (1 << z) - 1 - y],
    ); // MBTiles rows are TMS (south-up)
    return r.isEmpty ? null : r.first['tile_data'] as Uint8List;
  }
}

/// Reads raster tiles out of MBTiles packs. Misses return a transparent
/// pixel so uncovered areas show the map background, not error tiles.
class MbtilesTileProvider extends TileProvider {
  MbtilesTileProvider(this.packs);
  final List<MbtilesPack> packs;

  static final _transparent = Uint8List.fromList(const [
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x01,
    0x08,
    0x06,
    0x00,
    0x00,
    0x00,
    0x1F,
    0x15,
    0xC4,
    0x89,
    0x00,
    0x00,
    0x00,
    0x0B,
    0x49,
    0x44,
    0x41,
    0x54,
    0x78,
    0xDA,
    0x63,
    0x60,
    0x00,
    0x02,
    0x00,
    0x00,
    0x05,
    0x00,
    0x01,
    0xE9,
    0xFA,
    0xDC,
    0xD8,
    0x00,
    0x00,
    0x00,
    0x00,
    0x49,
    0x45,
    0x4E,
    0x44,
    0xAE,
    0x42,
    0x60,
    0x82,
  ]);

  Uint8List bytesFor(TileCoordinates c) {
    for (final p in packs) {
      if (c.z < p.minZoom || c.z > p.maxZoom) continue;
      final t = p.tile(c.z, c.x, c.y);
      if (t != null) return t;
    }
    return _transparent;
  }

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(bytesFor(coordinates));
}

/// The installed MBTiles packs, shared by every offline map in the app.
class OfflineTiles extends ChangeNotifier {
  OfflineTiles._();
  static final instance = OfflineTiles._();

  List<MbtilesPack> _packs = const [];
  List<MbtilesPack> get packs => _packs;
  bool get isEmpty => _packs.isEmpty;

  /// Opens [paths] read-only, replacing whatever was open. Unreadable files
  /// are skipped (and logged) rather than breaking the map.
  void open(List<String> paths) {
    final next = <MbtilesPack>[];
    for (final path in paths) {
      try {
        next.add(MbtilesPack(sqlite3.open(path, mode: OpenMode.readOnly)));
      } catch (e) {
        debugPrint('Skipping map pack $path: $e');
      }
    }
    // Highest detail first so it wins where packs overlap.
    next.sort((a, b) => b.maxZoom.compareTo(a.maxZoom));
    for (final p in _packs) {
      p.db.dispose();
    }
    _packs = next;
    notifyListeners();
  }

  /// Name of the pack covering [p], for the "Offline map · …" badge.
  String? nameAt(LatLng p) {
    for (final pack in _packs) {
      if (pack.covers(p)) return pack.name;
    }
    return null;
  }

  int get maxZoom => _packs.fold(0, (m, p) => p.maxZoom > m ? p.maxZoom : m);

  TileLayer layer() => TileLayer(
    key: ValueKey(_packs.length),
    tileProvider: MbtilesTileProvider(_packs),
    maxNativeZoom: maxZoom,
    userAgentPackageName: 'in.gov.ner.ner_logistics',
  );
}
