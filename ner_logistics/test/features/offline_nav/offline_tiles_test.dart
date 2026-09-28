import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:ner_logistics/features/rider/offline_nav/data/offline_packs.dart';
import 'package:ner_logistics/shared/map/offline_tiles.dart';
import 'package:sqlite3/sqlite3.dart';

Database _pack() {
  final db = sqlite3.openInMemory()
    ..execute('CREATE TABLE metadata (name TEXT, value TEXT)')
    ..execute('CREATE TABLE tiles (zoom_level INT, tile_column INT, tile_row INT, tile_data BLOB)');
  db.execute("INSERT INTO metadata VALUES ('name','Test pack'),('minzoom','10'),('maxzoom','14'),"
      "('bounds','91.5,25.5,92.0,26.3')");
  // XYZ (z=10, x=5, y=3) is TMS row 2^10-1-3 = 1020.
  db.execute('INSERT INTO tiles VALUES (10, 5, 1020, ?)', [Uint8List.fromList([1, 2, 3])]);
  return db;
}

void main() {
  test('MBTiles provider flips TMS rows and returns a transparent tile on a miss', () {
    final pack = MbtilesPack(_pack());
    expect(pack.name, 'Test pack');
    expect(pack.maxZoom, 14);
    expect(pack.covers(const LatLng(26.14, 91.74)), isTrue);
    expect(pack.covers(const LatLng(27.3, 88.6)), isFalse);
    final provider = MbtilesTileProvider([pack]);
    expect(provider.bytesFor(const TileCoordinates(5, 3, 10)), [1, 2, 3]);
    final miss = provider.bytesFor(const TileCoordinates(6, 3, 10));
    expect(miss.sublist(1, 4), 'PNG'.codeUnits);
    pack.db.dispose();
  });

  test('first run installs the bundled sample graph and places', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final tmp = await Directory.systemTemp.createTemp('offline_nav');
    addTearDown(() => tmp.delete(recursive: true));
    final packs = OfflinePacks(root: () async => tmp, bundle: _DiskBundle(), baseUrl: '');
    await packs.init();
    expect(packs.error, isNull);
    expect(packs.ready, isTrue);
    expect(packs.graphPath, endsWith('sample/ner_roads.bin'));
    expect(packs.installed.single.bundled, isTrue);
    expect(packs.installed.single.bytes, greaterThan(5000000));
    expect(packs.places!.search('Shillong'), isNotEmpty);
    // The bundled raster pack opens and has a real Guwahati tile at z13.
    final tiles = OfflineTiles.instance;
    expect(tiles.nameAt(const LatLng(26.1445, 91.7362)), 'Sample: Guwahati–Shillong');
    expect(tiles.maxZoom, 15);
    final bytes = MbtilesTileProvider(tiles.packs).bytesFor(const TileCoordinates(6183, 3479, 13));
    expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WEBP');
    tiles.open(const []);
  });

  test('manifest parses packs and files', () {
    final packs = RemotePack.parseManifest(
        '{"packs":[{"id":"ne","name":"North East roads","files":[{"path":"ner_roads.bin.gz","bytes":10,"sha256":"ab"}]}]}');
    expect(packs.single.name, 'North East roads');
    expect(packs.single.bytes, 10);
  });
}

/// Reads assets straight from the project folder.
class _DiskBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    final f = File(key);
    if (!f.existsSync()) throw StateError('missing $key');
    return ByteData.sublistView(f.readAsBytesSync());
  }
}
