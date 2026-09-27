import { useEffect, useMemo, useState } from 'react';
import MapViz from '@/components/MapViz';
import { vehicles } from '@/data/demo';
import type { Severity } from '@/data/demo';
import { STATUS_LABEL, pathOf, useCorridorAccessibility, type CorridorStatus } from '@/lib/accessibility';
import { stateLabel, topShare } from '@/lib/ml';
import { getIncidents, subscribeToIncidents } from '@/lib/incidentStore';
import type { Role } from '@/roles';
import { profileService } from '@/lib/profileService';

const layerOptions = [
  { id: 'ROADS', label: 'Roads (accessibility status)' },
  { id: 'INCIDENTS', label: 'Incidents' },
  { id: 'FLOOD', label: 'Flood hazard (Bhuvan)' },
  { id: 'LANDSLIDE', label: 'Mapped landslides (Bhuvan)' },
  { id: 'RISK ZONES', label: 'Incident risk zones' },
  { id: 'ML ROAD RISK', label: 'ML road risk' },
  { id: 'LOGISTICS', label: 'Logistics' },
];
const statusColor: Record<CorridorStatus, string> = { open: '#2D6B4F', restricted: '#C4861A', blocked: '#BE2424' };
const riskFilters: { label: string; severity: Severity }[] = [
  { label: 'Low', severity: 'LOW' },
  { label: 'Moderate', severity: 'MODERATE' },
  { label: 'High', severity: 'HIGH' },
  { label: 'Critical', severity: 'CRITICAL' },
];
const timeFilters = ['Last 1 hour', 'Last 6 hours', 'Last 24 hours', 'Last 7 days'];

function parseIncidentTime(timeStr?: string): number {
  if (!timeStr) return 0;
  const str = timeStr.trim();
  const now = Date.now();

  const relMatch = str.match(/^(\d+)\s*(min|mins|minute|minutes|hr|hrs|hour|hours|day|days)\s*ago$/i);
  if (relMatch) {
    const val = parseInt(relMatch[1], 10);
    const unit = relMatch[2].toLowerCase();
    if (unit.startsWith('min')) return now - val * 60 * 1000;
    if (unit.startsWith('hr') || unit.startsWith('hour')) return now - val * 3600 * 1000;
    if (unit.startsWith('day')) return now - val * 24 * 3600 * 1000;
  }

  if (/^yesterday/i.test(str)) {
    return now - 24 * 3600 * 1000;
  }

  const parsed = new Date(str);
  if (!isNaN(parsed.getTime())) {
    return parsed.getTime();
  }

  const timeMatch = str.match(/^(\d{1,2}):(\d{2})\s*(AM|PM)?$/i);
  if (timeMatch) {
    let hours = parseInt(timeMatch[1], 10);
    const minutes = parseInt(timeMatch[2], 10);
    const ampm = timeMatch[3];
    if (ampm) {
      if (ampm.toUpperCase() === 'PM' && hours < 12) hours += 12;
      if (ampm.toUpperCase() === 'AM' && hours === 12) hours = 0;
    }
    const d = new Date();
    d.setHours(hours, minutes, 0, 0);
    return d.getTime();
  }

  return NaN; // unusable timestamp: excluded from every time range rather than guessed
}

/** Actual report time: the stored ISO `reportedAt`, else the legacy display string. */
function incidentTime(incident: { reportedAt?: string; reportedTime?: string }): number {
  const iso = Date.parse(incident.reportedAt ?? '');
  return Number.isNaN(iso) ? parseIncidentTime(incident.reportedTime) : iso;
}

function getTimeRangeCutoffMs(timeFilter: string): number {
  switch (timeFilter) {
    case 'Last 1 hour':
      return 1 * 3600 * 1000;
    case 'Last 6 hours':
      return 6 * 3600 * 1000;
    case 'Last 24 hours':
      return 24 * 3600 * 1000;
    case 'Last 7 days':
      return 7 * 24 * 3600 * 1000;
    default:
      return 24 * 3600 * 1000;
  }
}

export default function DistrictMap({ role }: { role?: Role }) {
  const currentRole = role ?? profileService.getCurrentRole() ?? 'district';
  const [incidents, setIncidents] = useState(() => getIncidents());
  const [activeLayers, setActiveLayers] = useState(new Set(['ROADS', 'INCIDENTS', 'LOGISTICS']));
  const [severities, setSeverities] = useState<Set<Severity>>(new Set());
  const [selectedRoute, setSelectedRoute] = useState<string | null>(null);
  const [timeFilter, setTimeFilter] = useState('Last 24 hours');

  useEffect(() => subscribeToIncidents(stored => setIncidents(stored)), []);

  const toggleLayer = (l: string) => {
    setActiveLayers(prev => {
      const next = new Set(prev);
      next.has(l) ? next.delete(l) : next.add(l);
      return next;
    });
  };

  const toggleSeverity = (severity: Severity) => {
    setSeverities(prev => {
      const next = new Set(prev);
      next.has(severity) ? next.delete(severity) : next.add(severity);
      return next;
    });
  };

  const mapIncidents = useMemo(() => {
    const cutoff = Date.now() - getTimeRangeCutoffMs(timeFilter);
    return incidents.filter(incident => {
      const incTime = incidentTime(incident);
      const withinTime = incTime >= cutoff;
      const withinSeverity = severities.size === 0 || severities.has(incident.severity);
      return withinTime && withinSeverity;
    });
  }, [incidents, timeFilter, severities]);

  // Road status comes from the database (open incidents + route geometry), scoped to the caller's district.
  const access = useCorridorAccessibility();
  const corridorRows = useMemo(() => access.data?.routes ?? [], [access.data]);
  const mapRoutes = useMemo(() => corridorRows.map(r => ({
    id: r.route_number, name: r.name, status: STATUS_LABEL[r.status], path: pathOf(r), accessibility: r.accessibility_pct,
  })), [corridorRows]);

  const mapVehicles = useMemo(() => {
    if (mapIncidents.length === 0) {
      return [];
    }
    const activeRouteIds = new Set(mapIncidents.map(inc => inc.route));
    return vehicles.filter(v => activeRouteIds.has(v.route));
  }, [mapIncidents]);

  const route = corridorRows.find(r => r.route_number === selectedRoute);

  return (
    <div className="space-y-4 h-full flex flex-col max-w-screen-2xl">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="font-semibold text-2xl" style={{ color: '#17212B' }}>{currentRole === 'control' ? 'Regional Map' : 'District Map'}</h1>
          <p className="text-sm mt-0.5" style={{ color: '#5A6670' }}>Geospatial intelligence — routes, incidents, logistics</p>
        </div>
      </div>

      <div className="flex-1 flex gap-4 min-h-0">
        {/* Left controls */}
        <div className="w-56 flex-shrink-0 space-y-4">
          {/* Layers */}
          <div className="rounded-xl border p-3" style={{ background: 'rgba(250,247,240,0.82)', borderColor: 'rgba(180,162,136,0.55)' }}>
            <h3 className="text-xs font-semibold uppercase tracking-wider mb-2" style={{ color: '#5A6670' }}>Map Layers</h3>
            <div className="space-y-1.5">
              {layerOptions.map(l => (
                <label key={l.id} className="flex items-center gap-2 text-xs cursor-pointer" style={{ color: '#17212B' }}>
                  <input type="checkbox" checked={activeLayers.has(l.id)} onChange={() => toggleLayer(l.id)}
                    className="rounded" />
                  {l.label}
                </label>
              ))}
            </div>
          </div>

          {/* Risk filter */}
          <div className="rounded-xl border p-3" style={{ background: 'rgba(250,247,240,0.82)', borderColor: 'rgba(180,162,136,0.55)' }}>
            <h3 className="text-xs font-semibold uppercase tracking-wider mb-2" style={{ color: '#5A6670' }}>Risk Level</h3>
            <div className="flex flex-col gap-1">
              {riskFilters.map(f => {
                const selected = severities.has(f.severity);
                return (
                  <button key={f.label} onClick={() => toggleSeverity(f.severity)} aria-pressed={selected}
                    className="text-left text-xs px-2 py-1.5 rounded transition-colors"
                    style={{ background: selected ? '#17324D' : 'rgba(238,228,210,0.88)', color: selected ? 'white' : '#17212B' }}>{f.label}</button>
                );
              })}
            </div>
          </div>

          {/* Time filter */}
          <div className="rounded-xl border p-3" style={{ background: 'rgba(250,247,240,0.82)', borderColor: 'rgba(180,162,136,0.55)' }}>
            <h3 className="text-xs font-semibold uppercase tracking-wider mb-2" style={{ color: '#5A6670' }}>Time Range</h3>
            {timeFilters.map(f => (
              <button key={f} onClick={() => setTimeFilter(f)}
                className="w-full text-left text-xs px-2 py-1.5 rounded mb-0.5 transition-colors"
                style={{
                  background: timeFilter === f ? '#17324D' : 'rgba(238,228,210,0.88)',
                  color: timeFilter === f ? 'white' : '#17212B',
                }}>
                {f}
              </button>
            ))}
          </div>

          {/* Routes list */}
          <div className="rounded-xl border p-3" style={{ background: 'rgba(250,247,240,0.82)', borderColor: 'rgba(180,162,136,0.55)' }}>
            <h3 className="text-xs font-semibold uppercase tracking-wider mb-2" style={{ color: '#5A6670' }}>Routes</h3>
            <div className="space-y-1">
              {access.signedOut && <p className="text-xs" style={{ color: 'var(--text-muted)' }}>Sign in to load live road status.</p>}
              {access.error && <p className="text-xs" style={{ color: '#BE2424' }}>Road status unavailable: {access.error}</p>}
              {access.data && corridorRows.length === 0 && <p className="text-xs" style={{ color: 'var(--text-muted)' }}>No routes stored yet.</p>}
              {corridorRows.map(r => (
                <button key={r.route_id} onClick={() => setSelectedRoute(selectedRoute === r.route_number ? null : r.route_number)} title={r.name}
                  className="w-full text-left px-2 py-1.5 rounded text-xs transition-colors"
                  style={{
                    background: selectedRoute === r.route_number ? 'rgba(238,228,210,0.88)' : 'transparent',
                    color: '#17212B',
                    borderLeft: selectedRoute === r.route_number ? '2px solid #D7A73A' : '2px solid transparent',
                  }}>
                  <span className="font-medium">{r.route_number}</span>
                  <span className="ml-2" style={{ color: statusColor[r.status] }}>● {STATUS_LABEL[r.status]}</span>
                  {r.accessibility_pct !== null && <span className="ml-1" style={{ color: 'var(--text-muted)' }}>{r.accessibility_pct}%</span>}
                </button>
              ))}
            </div>
          </div>
        </div>

        {/* Map */}
        <div className="flex-1 min-w-0 flex flex-col gap-4">
          <div className="rounded-xl border shadow-sm overflow-hidden" style={{ borderColor: 'rgba(180,162,136,0.55)' }}>
            <MapViz incidents={mapIncidents} routes={mapRoutes} vehicles={mapVehicles} height={520} showLegend
              rounded="12px" focusRouteId={selectedRoute}
              layers={{
                routes: activeLayers.has('ROADS'),
                incidents: activeLayers.has('INCIDENTS'),
                logistics: activeLayers.has('LOGISTICS'),
                risk: activeLayers.has('RISK ZONES'),
                ml: activeLayers.has('ML ROAD RISK'),
                flood: activeLayers.has('FLOOD'),
                landslide: activeLayers.has('LANDSLIDE'),
              }} />
          </div>

          {/* Route detail panel */}
          {route && (
            <div className="rounded-xl border p-4" style={{ background: 'rgba(250,247,240,0.82)', borderColor: 'rgba(180,162,136,0.55)' }}>
              <div className="flex items-start justify-between mb-3">
                <div>
                  <h3 className="font-semibold text-base" style={{ color: '#17212B' }}>Route {route.route_number}</h3>
                  <p className="text-xs" style={{ color: '#5A6670' }}>
                    {route.name}{route.length_m ? ` · ${(route.length_m / 1000).toFixed(0)} km` : ''}
                  </p>
                </div>
                <span className="text-xs font-semibold" style={{ color: statusColor[route.status] }}>● {STATUS_LABEL[route.status]}</span>
              </div>
              <div className="grid grid-cols-2 sm:grid-cols-5 gap-3">
                {[
                  { label: 'Accessibility', value: route.accessibility_pct === null ? 'No geometry' : `${route.accessibility_pct}%` },
                  { label: 'Clear length', value: route.open_length_pct === null ? '—' : `${route.open_length_pct}%` },
                  { label: 'Open incidents', value: String(route.open_incidents) },
                  { label: 'Blocking', value: String(route.blocking_incidents) },
                  { label: 'ML risk (max)', value: route.ml?.max_percentile != null ? `${topShare(route.ml.max_percentile)} of roads` : 'No ML coverage' },
                ].map(item => (
                  <div key={item.label} className="rounded p-2" style={{ background: 'rgba(238,228,210,0.88)' }}>
                    <div className="text-xs mb-0.5" style={{ color: 'var(--text-muted)' }}>{item.label}</div>
                    <div className="text-xs font-semibold" style={{ color: '#17212B' }}>{item.value}</div>
                  </div>
                ))}
              </div>
              <p className="mt-3 text-xs" style={{ color: 'var(--text-muted)' }}>
                Status from open incidents within 1 km of the route{access.data?.scope !== 'region' ? ' in your district' : ''}.
                {route.ml ? ` ML: ${stateLabel(access.data?.ml ?? null)}, ${route.ml.n_segments} segments, advisory only.` : ''}
              </p>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
