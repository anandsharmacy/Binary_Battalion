import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/connectivity_provider.dart';
import '../../../../shared/map/offline_tiles.dart';
import '../../../../theme/colors.dart';
import '../../../../theme/text_styles.dart';
import '../data/offline_packs.dart';
import 'offline_nav_page.dart';

/// Offline maps manager: what's on this phone, and region packs to
/// download from `NAV_PACK_BASE_URL` when one is configured.
class OfflineMapsScreen extends ConsumerStatefulWidget {
  final OfflinePacks packs;
  const OfflineMapsScreen({super.key, required this.packs});

  @override
  ConsumerState<OfflineMapsScreen> createState() => _OfflineMapsScreenState();
}

class _OfflineMapsScreenState extends ConsumerState<OfflineMapsScreen> {
  Future<List<RemotePack>>? _catalog;

  OfflinePacks get _packs => widget.packs;

  @override
  void initState() {
    super.initState();
    unawaited(_packs.init());
  }

  void _loadCatalog() {
    if (_packs.baseUrl.isEmpty) return;
    setState(() => _catalog = _packs.fetchCatalog());
  }

  @override
  Widget build(BuildContext context) {
    final online = ref.watch(isOnlineProvider).valueOrNull ?? true;
    if (online && _catalog == null && _packs.baseUrl.isNotEmpty) {
      _catalog = _packs.fetchCatalog();
    }
    return Scaffold(
      backgroundColor: AppColors.paper,
      appBar: AppBar(title: const Text('Offline Maps')),
      body: ListenableBuilder(
        listenable: _packs,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _header('Downloaded'),
            if (!_packs.ready && _packs.error == null) const ListTile(title: Text('Preparing offline data…')),
            if (_packs.error != null) ListTile(title: Text(_packs.error!)),
            for (final p in _packs.installed) _installedRow(p),
            _header('Available'),
            ..._available(online),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Map data $offlineTilesAttribution. Road data is from OpenStreetMap '
                '(ODbL) and does not include closures or landslides.',
                style: AppTextStyles.caption,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Semantics(header: true, child: Text(text.toUpperCase(), style: AppTextStyles.eyebrow)),
  );

  Widget _installedRow(InstalledPack p) {
    final tile = ListTile(
      tileColor: Colors.white,
      leading: Icon(
        p.bundled ? Icons.inventory_2_outlined : Icons.download_done,
        color: AppColors.deepGreen700,
      ),
      title: Text(p.name, style: AppTextStyles.bodySmallMedium),
      subtitle: Text(
        p.bundled
            ? '${formatBytes(p.bytes)} · included with the app · map, roads, places'
            : formatBytes(p.bytes),
        style: AppTextStyles.caption,
      ),
      trailing: p.bundled
          ? null
          : IconButton(
              tooltip: 'Delete ${p.name}',
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              icon: const Icon(Icons.delete_outline, color: AppColors.signalRed700),
              onPressed: () => _packs.delete(p),
            ),
    );
    if (p.bundled) return tile;
    // Re-downloadable, so no confirmation alert (HIG Alerts).
    return Dismissible(
      key: ValueKey(p.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: AppColors.signalRed700,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      onDismissed: (_) => _packs.delete(p),
      child: tile,
    );
  }

  List<Widget> _available(bool online) {
    if (_packs.baseUrl.isEmpty) {
      return const [
        ListTile(
          tileColor: Colors.white,
          leading: Icon(Icons.cloud_off_outlined, color: AppColors.slate500),
          title: Text('Full-region pack not available yet'),
          subtitle: Text(
            'Region downloads appear here once the map host is set up. '
            'Until then, offline routing covers the sample area only.',
          ),
        ),
      ];
    }
    if (!online) {
      return const [
        ListTile(
          tileColor: Colors.white,
          leading: Icon(Icons.wifi_off_outlined, color: AppColors.slate500),
          title: Text('Connect to the internet to download maps'),
          subtitle: Text('Downloaded maps keep working offline.'),
        ),
      ];
    }
    return [
      FutureBuilder<List<RemotePack>>(
        future: _catalog,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const ListTile(
              leading: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
              title: Text('Checking available regions'),
            );
          }
          if (snap.hasError) {
            return ListTile(
              tileColor: Colors.white,
              title: const Text('Couldn’t reach the map host'),
              subtitle: Text('${snap.error}'),
              trailing: TextButton(onPressed: _loadCatalog, child: const Text('Retry')),
            );
          }
          final installedIds = {for (final p in _packs.installed) p.id};
          final packs = [
            for (final p in snap.data!)
              if (!installedIds.contains(p.id)) p,
          ];
          if (packs.isEmpty) {
            return const ListTile(title: Text('Every available region is downloaded.'));
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('Region packs are large. Use Wi-Fi if you can.', style: AppTextStyles.caption),
              ),
              for (final p in packs) _remoteRow(p),
            ],
          );
        },
      ),
    ];
  }

  Widget _remoteRow(RemotePack p) {
    final progress = _packs.progress[p.id];
    final error = _packs.downloadErrors[p.id];
    return ListTile(
      tileColor: Colors.white,
      title: Text(p.name, style: AppTextStyles.bodySmallMedium),
      subtitle: Text(
        error ?? formatBytes(p.bytes),
        style: AppTextStyles.caption.copyWith(color: error == null ? null : AppColors.signalRed700),
      ),
      trailing: progress == null
          ? TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
              onPressed: () => _packs.download(p),
              child: Text(error == null ? 'Download' : 'Retry'),
            )
          : Semantics(
              label: 'Downloading ${p.name}, ${(progress * 100).round()} percent. Stop',
              button: true,
              excludeSemantics: true,
              onTap: () => _packs.cancel(p.id),
              child: InkResponse(
                onTap: () => _packs.cancel(p.id),
                radius: 24,
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CircularProgressIndicator(value: progress, strokeWidth: 3),
                      const Icon(Icons.stop, size: 18, color: AppColors.navy900),
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
