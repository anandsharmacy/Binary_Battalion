import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../../../../mock_data/models.dart';
import '../../../../services/geo/geo_math.dart';
import '../../../../services/routing/osrm_models.dart';
import '../../../../services/routing/trip_plan.dart';
import '../../../../shared/map/ner_map.dart';
import '../../../../shared/map/offline_tiles.dart';
import '../../../../shared/motion.dart';
import '../../../../shared/widgets/glass_surface.dart';
import '../../../../theme/colors.dart';
import '../../../../theme/text_styles.dart';
import '../../domain/rider_context.dart';
import '../data/offline_packs.dart';
import '../data/places_index.dart';
import '../data/road_graph.dart';
import 'nav_guidance_screen.dart';
import 'offline_maps_screen.dart';

/// A chosen destination: search result, dropped pin or delivery.
class NavDestination {
  final String name;
  final String detail;
  final LatLng point;
  const NavDestination(this.name, this.detail, this.point);
}

/// Offline Navigation section: interactive offline map with a resizable
/// sheet for search → place card → route preview → Start.
class OfflineNavPage extends StatefulWidget {
  final RiderContext? riderContext;
  final OfflinePacks? packs;

  const OfflineNavPage({super.key, this.riderContext, this.packs});

  @override
  State<OfflineNavPage> createState() => _OfflineNavPageState();
}

enum _Stage { browse, place, routing, preview }

class _OfflineNavPageState extends State<OfflineNavPage> {
  static const _detents = [0.16, 0.42, 0.92];
  static const _sampleCentre = LatLng(
    25.87,
    91.80,
  ); // Guwahati–Shillong corridor

  late final OfflinePacks _packs = widget.packs ?? OfflinePacks.instance;
  final _sheet = DraggableScrollableController();
  final _search = TextEditingController();
  final _searchFocus = FocusNode();

  LatLng? _me;
  String? _locError;
  NavDestination? _dest;
  OsrmRoute? _route;
  String? _routeError;
  _Stage _stage = _Stage.browse;
  int _fit = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_packs.init());
    unawaited(_locate());
    _searchFocus.addListener(() {
      if (_searchFocus.hasFocus) _snapTo(_detents.last);
    });
  }

  @override
  void dispose() {
    _sheet.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _locate() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw 'Location Services are off.';
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        throw 'Location permission is off for NER Logistics.';
      }
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      ).timeout(const Duration(seconds: 20));
      if (!mounted) return;
      setState(() {
        _me = LatLng(p.latitude, p.longitude);
        _locError = null;
        _fit++;
      });
    } catch (e) {
      if (!mounted) return;
      setState(
        () =>
            _locError = e is String ? e : 'Your location isn’t available yet.',
      );
    }
  }

  void _snapTo(double size) {
    if (!_sheet.isAttached) return;
    final d = motion(context, const Duration(milliseconds: 250));
    if (d == Duration.zero) {
      _sheet.jumpTo(size);
    } else {
      unawaited(
        _sheet.animateTo(size, duration: d, curve: Curves.easeOutCubic),
      );
    }
  }

  void _choose(NavDestination d) {
    _searchFocus.unfocus();
    setState(() {
      _dest = d;
      _route = null;
      _routeError = null;
      _stage = _Stage.place;
      _fit++;
    });
    _snapTo(_detents[1]);
  }

  void _dropPin(LatLng p) => _choose(
    NavDestination(
      'Dropped pin',
      '${p.latitude.toStringAsFixed(4)}, ${p.longitude.toStringAsFixed(4)}',
      p,
    ),
  );

  void _cancel() => setState(() {
    _dest = null;
    _route = null;
    _routeError = null;
    _stage = _Stage.browse;
    _fit++;
  });

  Future<void> _directions() async {
    final dest = _dest, me = _me, graph = _packs.graphPath;
    if (dest == null) return;
    if (me == null) {
      setState(
        () => _routeError =
            'Your location isn’t available, so a route can’t start from here.',
      );
      return;
    }
    if (graph == null) {
      setState(
        () => _routeError =
            'Offline road data is still being prepared. Try again in a moment.',
      );
      return;
    }
    setState(() {
      _stage = _Stage.routing;
      _routeError = null;
    });
    try {
      final r = await routeOffline(graph, me, dest.point);
      if (!mounted || _dest != dest) return;
      setState(() {
        _route = r;
        _stage = _Stage.preview;
        _fit++;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.place;
        _routeError = e is OfflineRouteException
            ? e.message
            : 'Route failed: $e';
      });
    }
  }

  Future<void> _start() async {
    final r = _route, d = _dest, graph = _packs.graphPath;
    if (r == null || d == null || graph == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) =>
            NavGuidanceScreen(route: r, destination: d, graphPath: graph),
      ),
    );
    if (mounted) _cancel();
  }

  List<LatLng> get _fitPoints {
    final r = _route;
    if (r != null) return GeoMath.simplify(r.geometry, 200);
    return [?_dest?.point, ?_me];
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    final pts = _fitPoints;
    return ListenableBuilder(
      listenable: Listenable.merge([_packs, OfflineTiles.instance]),
      builder: (context, _) => Stack(
        children: [
          Positioned.fill(
            child: MergeSemantics(
              child: Semantics(
                label: 'Offline map. Touch and hold to drop a pin.',
                child: NerMap(
                  fitPoints: pts.isEmpty ? const [_sampleCentre] : pts,
                  fitKey: _fit,
                  maxFitZoom: pts.length <= 1 ? 14 : 16,
                  fitPadding: EdgeInsets.fromLTRB(
                    40,
                    70,
                    40,
                    height * _detents[1] + 24,
                  ),
                  offlineMode: true,
                  offlineRegionName: OfflineTiles.instance.nameAt(
                    _dest?.point ?? _me ?? _sampleCentre,
                  ),
                  attributionBottom: height * _detents.first + 10,
                  onLongPress: _stage == _Stage.routing ? null : _dropPin,
                  routes: [
                    if (_route != null)
                      MapRoute(
                        points: _route!.geometry,
                        tone: MapLineTone.clear,
                      ),
                  ],
                  vehicles: [
                    if (_me != null)
                      MapVehicle(
                        id: 'me',
                        point: _me!,
                        risk: Priority.low,
                        label: 'Your location',
                        self: true,
                      ),
                  ],
                  pois: [
                    if (_dest != null)
                      MapPoi(
                        point: _dest!.point,
                        kind: MapPoiKind.destination,
                        label: _dest!.name,
                      ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            right: 12,
            top: 12,
            child: _MapButton(
              icon: Icons.my_location,
              label: 'Show my location',
              onTap: _locate,
            ),
          ),
          DraggableScrollableSheet(
            controller: _sheet,
            initialChildSize: _detents[1],
            minChildSize: _detents.first,
            maxChildSize: _detents.last,
            snap: true,
            snapSizes: _detents,
            builder: (context, scroll) => _SheetFrame(
              onGrabberTap: () {
                final i = _detents.indexWhere((d) => d > _sheet.size + 0.01);
                _snapTo(i < 0 ? _detents.first : _detents[i]);
              },
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                children: switch (_stage) {
                  _Stage.browse => _browse(),
                  _Stage.place => _placeCard(),
                  _Stage.routing => _routing(),
                  _Stage.preview => _preview(),
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Sheet contents ─────────────────────────────────────────────────────────

  List<Widget> _browse() {
    final q = _search.text;
    final results = _packs.places?.search(q, near: _me) ?? const <Place>[];
    final deliveries = [
      for (final s in widget.riderContext?.shipments ?? const <RiderShipment>[])
        if (s.destinationLat != null && s.destinationLng != null) s,
    ];
    return [
      TextField(
        controller: _search,
        focusNode: _searchFocus,
        textInputAction: TextInputAction.search,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          hintText: 'Search places',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: q.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(_search.clear),
                ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 2),
        child: Text(
          'Or touch and hold the map to drop a pin.',
          style: AppTextStyles.caption,
        ),
      ),
      if (_packs.error != null)
        _Note(
          icon: Icons.error_outline,
          text: _packs.error!,
          action: ('Try again', _packs.init),
        )
      else if (!_packs.ready)
        const _Note(
          icon: Icons.hourglass_empty,
          text: 'Preparing offline road data…',
        ),
      if (_locError != null)
        _Note(
          icon: Icons.location_disabled_outlined,
          text: _locError!,
          action: ('Try again', _locate),
        ),
      if (q.isNotEmpty) ...[
        if (results.isEmpty && _packs.ready)
          _Note(
            icon: Icons.search_off,
            text:
                'No offline match for “$q”. Touch and hold the map to drop a pin instead.',
          ),
        for (final p in results)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(_placeIcon(p.kind), color: AppColors.navy900),
            title: Text(p.name, style: AppTextStyles.bodySmallMedium),
            subtitle: Text(
              _me == null
                  ? p.kindLabel
                  : '${p.kindLabel} · ${formatDistance(GeoMath.distanceM(_me!, p.point))}',
              style: AppTextStyles.caption,
            ),
            onTap: () => _choose(NavDestination(p.name, p.kindLabel, p.point)),
          ),
      ] else ...[
        if (deliveries.isNotEmpty) ...[
          Semantics(
            header: true,
            child: Text('YOUR DELIVERIES', style: AppTextStyles.eyebrow),
          ),
          for (final s in deliveries)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(
                Icons.local_shipping_outlined,
                color: AppColors.navy900,
              ),
              title: Text(
                s.destination ?? s.shipmentNumber,
                style: AppTextStyles.bodySmallMedium,
              ),
              subtitle: Text(
                'Delivery ${s.shipmentNumber}',
                style: AppTextStyles.caption,
              ),
              onTap: () => _choose(
                NavDestination(
                  s.destination ?? s.shipmentNumber,
                  'Delivery ${s.shipmentNumber}',
                  LatLng(s.destinationLat!, s.destinationLng!),
                ),
              ),
            ),
          const Divider(),
        ],
        Semantics(
          header: true,
          child: Text('OFFLINE MAPS', style: AppTextStyles.eyebrow),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(
            Icons.download_for_offline_outlined,
            color: AppColors.navy900,
          ),
          title: Text(
            'Manage offline maps',
            style: AppTextStyles.bodySmallMedium,
          ),
          subtitle: Text(_packsSummary(), style: AppTextStyles.caption),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => OfflineMapsScreen(packs: _packs),
            ),
          ),
        ),
        Text(
          'Routes are computed on this phone from OpenStreetMap road data. '
          'Road closures and landslides are not included.',
          style: AppTextStyles.caption,
        ),
      ],
    ];
  }

  String _packsSummary() {
    if (!_packs.ready) return 'Preparing…';
    final downloaded = _packs.installed.where((p) => !p.bundled).toList();
    if (downloaded.isEmpty) return 'Sample area only: Guwahati–Shillong';
    final bytes = downloaded.fold<int>(0, (a, p) => a + p.bytes);
    return '${downloaded.length} region${downloaded.length == 1 ? '' : 's'} · ${formatBytes(bytes)}';
  }

  List<Widget> _placeCard() {
    final d = _dest!;
    return [
      Semantics(
        header: true,
        child: Text(d.name, style: AppTextStyles.sectionHeading),
      ),
      const SizedBox(height: 4),
      Text(
        _me == null
            ? d.detail
            : '${d.detail} · ${formatDistance(GeoMath.distanceM(_me!, d.point))} away in a straight line',
        style: AppTextStyles.bodySmall,
      ),
      if (_routeError != null) ...[
        const SizedBox(height: 12),
        _Note(
          icon: Icons.wrong_location_outlined,
          text: _routeError!,
          tone: AppColors.signalRed700,
        ),
      ],
      const SizedBox(height: 16),
      _PrimaryButton(
        icon: Icons.directions,
        label: 'Directions',
        onPressed: _directions,
      ),
      const SizedBox(height: 8),
      _SecondaryButton(label: 'Cancel', onPressed: _cancel),
    ];
  }

  List<Widget> _routing() => [
    const SizedBox(height: 16),
    const Center(child: CircularProgressIndicator()),
    const SizedBox(height: 12),
    Center(
      child: Text(
        'Finding the fastest road offline',
        style: AppTextStyles.bodySmall,
      ),
    ),
    const SizedBox(height: 16),
    _SecondaryButton(label: 'Cancel', onPressed: _cancel),
  ];

  List<Widget> _preview() {
    final r = _route!, d = _dest!;
    final arrive = DateTime.now().add(Duration(seconds: r.durationS.round()));
    final via = _mainRoad(r);
    return [
      Text(d.name, style: AppTextStyles.bodySmallMedium),
      const SizedBox(height: 4),
      Semantics(
        header: true,
        child: Text(
          formatDuration(Duration(seconds: r.durationS.round())),
          style: AppTextStyles.pageHeading.copyWith(
            color: AppColors.deepGreen700,
          ),
        ),
      ),
      Text(
        '${formatDistance(r.distanceM)} · arrive about ${DateFormat.Hm().format(arrive)}'
        '${via.isEmpty ? '' : ' · via $via'}',
        style: AppTextStyles.bodySmallMedium,
      ),
      const SizedBox(height: 6),
      Text(
        'Offline route · OpenStreetMap road data · closures not included',
        style: AppTextStyles.caption,
      ),
      const SizedBox(height: 16),
      _PrimaryButton(icon: Icons.navigation, label: 'Start', onPressed: _start),
      const SizedBox(height: 8),
      _SecondaryButton(label: 'Cancel', onPressed: _cancel),
    ];
  }

  /// The road carrying the most distance, e.g. "NH-6".
  static String _mainRoad(OsrmRoute r) {
    final byRoad = <String, double>{};
    for (final s in r.steps) {
      if (s.road.isNotEmpty) {
        byRoad[s.road] = (byRoad[s.road] ?? 0) + s.distanceM;
      }
    }
    if (byRoad.isEmpty) return '';
    return byRoad.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  static IconData _placeIcon(String kind) => switch (kind) {
    'hospital' || 'clinic' => Icons.local_hospital_outlined,
    'pharmacy' => Icons.local_pharmacy_outlined,
    'fuel' => Icons.local_gas_station_outlined,
    'police' => Icons.local_police_outlined,
    _ => Icons.place_outlined,
  };
}

/// "5.2 MB".
String formatBytes(int b) => b >= 1 << 30
    ? '${(b / (1 << 30)).toStringAsFixed(1)} GB'
    : b >= 1 << 20
    ? '${(b / (1 << 20)).toStringAsFixed(1)} MB'
    : '${(b / 1024).ceil()} KB';

// ── Small building blocks ────────────────────────────────────────────────────

/// Sheet surface with a grabber (HIG Sheets: "Include a grabber in a
/// resizable sheet"); tapping it cycles detents, also via VoiceOver.
class _SheetFrame extends StatelessWidget {
  final VoidCallback onGrabberTap;
  final Widget child;
  const _SheetFrame({required this.onGrabberTap, required this.child});

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
      // Material ancestor for InkWell/ink splashes inside a transparent-fill sheet.
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: [
            Semantics(
              button: true,
              label: 'Resize sheet',
              onTap: onGrabberTap,
              excludeSemantics: true,
              child: InkWell(
                onTap: onGrabberTap,
                child: SizedBox(
                  height: 44,
                  width: double.infinity,
                  child: Center(
                    child: Container(
                      width: 36,
                      height: 5,
                      decoration: BoxDecoration(
                        color: AppColors.slate500.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class _MapButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _MapButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      blurSigma: AppColors.glassBlurSigmaChrome,
      borderRadius: BorderRadius.circular(10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.hairline),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: IconButton(
            tooltip: label,
            icon: Icon(icon, color: AppColors.navy900),
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            onPressed: onTap,
          ),
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color tone;
  final (String, Future<void> Function())? action;
  const _Note({
    required this.icon,
    required this.text,
    this.tone = AppColors.slate500,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18, color: tone),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: AppTextStyles.bodySmall.copyWith(color: tone),
            ),
          ),
          if (action != null)
            TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
              onPressed: action!.$2,
              child: Text(action!.$1),
            ),
        ],
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  const _PrimaryButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 50),
    child: ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
    ),
  );
}

class _SecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  const _SecondaryButton({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 48),
    child: OutlinedButton(onPressed: onPressed, child: Text(label)),
  );
}
