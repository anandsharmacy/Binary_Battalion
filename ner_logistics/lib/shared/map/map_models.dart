import 'package:latlong2/latlong.dart';

import '../../mock_data/models.dart';

/// Map overlay models. Pure Dart (no Flutter imports) so routing / GIS
/// services and the `tool/` generators can share them with the widgets.

/// Line styling for route segments. Matches [MapLegend]:
/// clear / caution / high risk solid, avoided route dashed grey.
enum MapLineTone { clear, caution, critical, avoided, candidate, travelled }

class MapRoute {
  final String? label;
  final List<LatLng> points;
  final MapLineTone tone;
  const MapRoute({this.label, required this.points, required this.tone});
}

class MapIncident {
  final String id;
  final LatLng point;
  final Priority severity;
  final IncidentType type;
  final String label;
  final bool resolved;
  const MapIncident({
    required this.id,
    required this.point,
    required this.severity,
    required this.type,
    required this.label,
    this.resolved = false,
  });
}

class MapVehicle {
  final String id;
  final LatLng point;
  final Priority risk;
  final String label;
  /// The signed-in officer's own vehicle — drawn as a navigation arrow.
  final bool self;

  /// A rider reporting from the mobile app (Supabase `rider_locations`).
  /// Live vehicles are drawn larger, rotated to [heading], and greyed when
  /// [stale] (no fix inside the staleness window).
  final bool live;
  final double? heading;
  final bool stale;
  final bool selected;
  final void Function()? onTap;

  const MapVehicle({
    required this.id,
    required this.point,
    required this.risk,
    required this.label,
    this.self = false,
    this.live = false,
    this.heading,
    this.stale = false,
    this.selected = false,
    this.onTap,
  });
}

enum MapZoneKind { safe, flood, landslide, impact }

class MapZone {
  final LatLng center;
  final double radiusMeters;
  final MapZoneKind kind;
  final String label;
  const MapZone({
    required this.center,
    required this.radiusMeters,
    required this.kind,
    required this.label,
  });
}

enum MapPoiKind { depot, bridge, destination }

class MapPoi {
  final LatLng point;
  final MapPoiKind kind;
  final String label;
  const MapPoi({required this.point, required this.kind, required this.label});
}

/// A GeoServer WMS layer drawn over the base map (e.g. `ner:risk_zones`).
class WmsOverlay {
  /// WMS endpoint ending in `?`, e.g. `http://host/geoserver/ner/wms?`.
  final String url;
  final String layer;
  final String? style;
  /// GeoServer `CQL_FILTER` vendor parameter, e.g. `kind='flood'`.
  final String? cql;
  final double opacity;

  const WmsOverlay({
    required this.url,
    required this.layer,
    this.style,
    this.cql,
    this.opacity = 0.75,
  });

  String get cacheKey => '$url|$layer|$style|$cql';
}

/// Public hazard layers from ISRO Bhuvan (NRSC), toggled from the map controls.
/// GetMap verified in EPSG:3857 on 2026-09-27; the web map uses the same layers.
enum NerHazard { flood, landslide }

const nerHazardLabels = {
  NerHazard.flood: 'Flood hazard (Bhuvan)',
  NerHazard.landslide: 'Mapped landslides (Bhuvan)',
};

const nerHazardOverlays = {
  NerHazard.flood: [
    // Assam flood hazard zonation 1998–2023; Arunachal aggregated flood extent 2003–2020.
    WmsOverlay(url: 'https://bhuvan-ras2.nrsc.gov.in/mapcache?', layer: 'as_hz', opacity: 0.6),
    WmsOverlay(url: 'https://bhuvan-ras2.nrsc.gov.in/mapcache?', layer: 'agg_ar', opacity: 0.6),
  ],
  NerHazard.landslide: [
    // Landslide Atlas of India 2023 inventories (Manipur: 2017 state inventory).
    WmsOverlay(
      url: 'https://bhuvan-vec2.nrsc.gov.in/bhuvan/wms?',
      layer: 'disaster:LS_ARUNACHAL_2023,disaster:LS_ASSAM_2023,disaster:LS_MEGHALAYA_2023,'
          'disaster:LS_MIZORAM_2023,disaster:LS_NAGALAND_2023,disaster:LS_SIKKIM_2023,'
          'disaster:LS_TRIPURA_2023,disaster:MN_SLIM_2017',
      opacity: 0.7,
    ),
  ],
};
