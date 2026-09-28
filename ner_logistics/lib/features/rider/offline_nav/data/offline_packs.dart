import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../../../core/platform/device_channel.dart';
import '../../../../shared/map/offline_tiles.dart';
import 'places_index.dart';

/// A pack on this device: the bundled sample or a downloaded region.
class InstalledPack {
  final String id;
  final String name;
  final int bytes;
  final bool bundled;
  final Directory dir;
  const InstalledPack(this.id, this.name, this.bytes, this.bundled, this.dir);
}

/// One file of a downloadable pack, relative to the manifest's base URL.
class RemoteFile {
  final String path;
  final int bytes;
  final String? sha256;
  const RemoteFile(this.path, this.bytes, this.sha256);
}

/// A pack listed in `<NAV_PACK_BASE_URL>/manifest.json`.
class RemotePack {
  final String id;
  final String name;
  final List<RemoteFile> files;
  const RemotePack(this.id, this.name, this.files);
  int get bytes => files.fold(0, (a, f) => a + f.bytes);

  static List<RemotePack> parseManifest(String body) {
    final j = jsonDecode(body) as Map<String, dynamic>;
    return [
      for (final p in (j['packs'] as List? ?? const []).cast<Map<String, dynamic>>())
        RemotePack(p['id'] as String, p['name'] as String? ?? p['id'] as String, [
          for (final f in (p['files'] as List? ?? const []).cast<Map<String, dynamic>>())
            RemoteFile(f['path'] as String, (f['bytes'] as num?)?.toInt() ?? 0, f['sha256'] as String?),
        ]),
    ];
  }
}

/// Offline map packs on disk: installs the bundled Guwahati–Shillong sample
/// on first use, lists what's installed, and downloads / deletes region
/// packs. The installed list *is* the directory listing; no extra database.
///
/// Layout under the app-support `offline_nav/` folder:
///   sample/              bundled sample (ner_roads.bin, ner_places.tsv, sample.mbtiles if bundled)
///   packs/ID/pack.json  downloaded packs; pack.json is written last, so a
///                        folder without it is an unfinished download
class OfflinePacks extends ChangeNotifier {
  OfflinePacks({
    Future<Directory> Function()? root,
    this.bundle,
    http.Client Function()? client,
    this.baseUrl = const String.fromEnvironment('NAV_PACK_BASE_URL'),
  }) : _rootFn = root ?? getApplicationSupportDirectory,
       _client = client ?? http.Client.new;

  static final instance = OfflinePacks();

  static const sampleName = 'Sample: Guwahati–Shillong';
  static const _assets = 'assets/offline_nav';
  static const _sampleFiles = ['ner_roads.bin', 'ner_places.tsv', 'sample.mbtiles'];

  /// Where full-region packs are hosted (e.g. a GitHub release). Empty means
  /// no hosting is configured yet, and the UI says so.
  final String baseUrl;
  final Future<Directory> Function() _rootFn;
  final AssetBundle? bundle;
  final http.Client Function() _client;

  Directory? _dir;
  Future<void>? _init;

  List<InstalledPack> installed = const [];
  String? graphPath;
  PlacesIndex? places;
  String? error;
  bool get ready => graphPath != null;

  /// Download progress per pack id, 0..1. Absent = not downloading.
  final Map<String, double> progress = {};
  final Map<String, String> downloadErrors = {};
  final Set<String> _cancel = {};

  Future<void> init() => _init ??= _load().catchError((Object e) {
    error = 'Offline maps could not be prepared: $e';
    _init = null; // allow a retry
    notifyListeners();
  });

  Future<void> _load() async {
    final dir = Directory('${(await _rootFn()).path}/offline_nav');
    final sample = Directory('${dir.path}/sample');
    await sample.create(recursive: true);
    await Directory('${dir.path}/packs').create();
    _dir = dir;
    unawaited(DeviceChannel.excludeFromBackup(dir.path));
    final assets = bundle ?? rootBundle;
    for (final name in _sampleFiles) {
      final ByteData data;
      try {
        data = await assets.load('$_assets/$name');
      } catch (_) {
        continue; // sample.mbtiles is optional
      }
      final f = File('${sample.path}/$name');
      // Re-copy when an app update ships a different sample.
      if (!f.existsSync() || f.lengthSync() != data.lengthInBytes) {
        await f.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      }
    }
    await refresh();
  }

  /// Re-reads the directory: installed packs, active graph, places, tiles.
  Future<void> refresh() async {
    final dir = _dir;
    if (dir == null) return;
    final packs = <InstalledPack>[
      InstalledPack(
        'sample',
        sampleName,
        _size(Directory('${dir.path}/sample')),
        true,
        Directory('${dir.path}/sample'),
      ),
    ];
    for (final d in Directory('${dir.path}/packs').listSync().whereType<Directory>()) {
      final meta = File('${d.path}/pack.json');
      if (!meta.existsSync()) continue;
      final name = (jsonDecode(meta.readAsStringSync()) as Map)['name'] as String? ?? d.uri.pathSegments.last;
      packs.add(InstalledPack(d.uri.pathSegments.where((s) => s.isNotEmpty).last, name, _size(d), false, d));
    }
    // A downloaded graph (full region) beats the sample.
    String? find(String file) {
      for (final p in packs.reversed) {
        final f = File('${p.dir.path}/$file');
        if (f.existsSync()) return f.path;
      }
      return null;
    }

    graphPath = find('ner_roads.bin');
    final placesPath = find('ner_places.tsv');
    places = placesPath == null ? null : PlacesIndex.parse(await File(placesPath).readAsString());
    OfflineTiles.instance.open([
      for (final p in packs)
        for (final f in p.dir.listSync().whereType<File>())
          if (f.path.endsWith('.mbtiles')) f.path,
    ]);
    installed = packs;
    error = null;
    notifyListeners();
  }

  static int _size(Directory d) => d.existsSync()
      ? d.listSync(recursive: true).whereType<File>().fold(0, (a, f) => a + f.lengthSync())
      : 0;

  // ── Downloads ─────────────────────────────────────────────────────────────

  Future<List<RemotePack>> fetchCatalog() async {
    final client = _client();
    try {
      final res = await client.get(Uri.parse('$baseUrl/manifest.json')).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw HttpException('manifest HTTP ${res.statusCode}');
      return RemotePack.parseManifest(res.body);
    } finally {
      client.close();
    }
  }

  void cancel(String id) => _cancel.add(id);

  /// Downloads every file of [pack] into `packs/<id>/`, resuming `.part`
  /// files with an HTTP Range request, checking sha256, and gunzipping
  /// `.gz` files. Progress is real bytes received / bytes listed.
  Future<void> download(RemotePack pack) async {
    final dir = Directory('${_dir!.path}/packs/${pack.id}');
    await dir.create(recursive: true);
    _cancel.remove(pack.id);
    downloadErrors.remove(pack.id);
    progress[pack.id] = 0;
    notifyListeners();
    final client = _client();
    var done = 0;
    try {
      for (final f in pack.files) {
        final name = f.path.split('/').last;
        final finalName = name.endsWith('.gz') ? name.substring(0, name.length - 3) : name;
        if (File('${dir.path}/$finalName').existsSync()) {
          done += f.bytes;
          continue;
        }
        final part = File('${dir.path}/$name.part');
        final have = part.existsSync() ? part.lengthSync() : 0;
        final req = http.Request('GET', Uri.parse('$baseUrl/${f.path}'));
        if (have > 0) req.headers['Range'] = 'bytes=$have-';
        final res = await client.send(req);
        if (res.statusCode != 200 && res.statusCode != 206) {
          throw HttpException('HTTP ${res.statusCode} for ${f.path}');
        }
        final append = res.statusCode == 206;
        final sink = part.openWrite(mode: append ? FileMode.append : FileMode.write);
        var got = append ? have : 0;
        var lastShown = -1;
        try {
          await for (final chunk in res.stream) {
            if (_cancel.contains(pack.id)) throw const _Cancelled();
            sink.add(chunk);
            got += chunk.length;
            final total = pack.bytes == 0 ? 1 : pack.bytes;
            final pct = ((done + got) * 100 / total).floor();
            if (pct != lastShown) {
              lastShown = pct;
              progress[pack.id] = ((done + got) / total).clamp(0.0, 1.0);
              notifyListeners();
            }
          }
        } finally {
          await sink.close();
        }
        if (f.sha256 != null) {
          final digest = await sha256.bind(part.openRead()).first;
          if (digest.toString() != f.sha256!.toLowerCase()) {
            await part.delete();
            throw FormatException('${f.path} is corrupted (checksum mismatch). Try again.');
          }
        }
        if (name.endsWith('.gz')) {
          await part.openRead().transform(gzip.decoder).pipe(File('${dir.path}/$finalName').openWrite());
          await part.delete();
        } else {
          await part.rename('${dir.path}/$finalName');
        }
        done += f.bytes;
      }
      await File('${dir.path}/pack.json').writeAsString(jsonEncode({'id': pack.id, 'name': pack.name}));
      await refresh();
    } on _Cancelled {
      // Keep the .part files so the next attempt resumes.
    } catch (e) {
      downloadErrors[pack.id] = e is HttpException || e is SocketException
          ? 'Download failed. Check the connection and try again.'
          : '$e';
    } finally {
      client.close();
      progress.remove(pack.id);
      _cancel.remove(pack.id);
      notifyListeners();
    }
  }

  /// Deletes a downloaded pack. The bundled sample can't be deleted.
  Future<void> delete(InstalledPack pack) async {
    if (pack.bundled) return;
    await pack.dir.delete(recursive: true);
    await refresh();
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}
