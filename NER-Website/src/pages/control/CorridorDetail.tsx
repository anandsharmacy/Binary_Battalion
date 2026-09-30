import { useEffect, useMemo, useRef, useState } from 'react';
import L from 'leaflet';
import 'leaflet/dist/leaflet.css';
import { MlNotice, MlSourceTag, MlStatePill, MlCaveat, LoadingRows } from '@/components/MlRisk';
import { SeverityBadge, StatusBadge } from '@/components/StatusBadge';
import { corridorFor, locate, normalizeRouteId, type LatLng } from '@/data/geo';
import type { RouteStatus } from '@/data/demo';
import { fetchRouteRisk, fetchRoutesSummary, formatMlDate, promoteMlAlert, topShare, useMlQuery, type RouteRisk } from '@/lib/ml';
import { getIncidents, subscribeToIncidents, type StoredIncident } from '@/lib/incidentStore';
import { useAlerts } from '@/lib/alerts';
import { listRoutes, useShipments, type RouteOption } from '@/lib/shipments';
import { distanceM, distanceToLineM } from '@/lib/routing';
import { notify } from '@/lib/notify';
import { Card, CardHeader, BORDER, NAVY, TEAL } from '../fo/ui';

/* ────────────────────────────────────────────────────────────────
   Control room — Corridor Detail. One highway corridor at a time:
   ML risk index + factors, 7-run trend, recorded disruptions,
   map, current disposition and recommended actions. Every number
   comes from live data (ML RPCs, road_incidents, alerts, shipments).
──────────────────────────────────────────────────────────────── */

const RED = '#BE2424';
const ORANGE = '#C25A1A';
const AMBER = '#C4861A';
const GREEN = '#2D6B4F';
const MUTED = '#5A6670';
const INK = '#17212B';
const OSM_TILES = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const OSM_ATTRIBUTION = '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors';
const NEAR_ROUTE_M = 1000;
const DONE_SHIPMENT = ['arrived', 'completed', 'cancelled'];

function level(score: number | null): { label: string; color: string } {
  if (score == null) return { label: 'No data', color: MUTED };
  if (score >= 99) return { label: 'Extreme', color: RED };
  if (score >= 95) return { label: 'High', color: ORANGE };
  if (score >= 80) return { label: 'Elevated', color: AMBER };
  return { label: 'Low', color: GREEN };
}

function shiftDate(iso: string, days: number) {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

/** Current risk plus up to six earlier published runs (one per day) for the trend. */
async function fetchCorridorRisk(routeId: string) {
  const current = await fetchRouteRisk(routeId);
  if (current.state === 'unavailable' || !current.score_date) return { current, trend: [] as { date: string; value: number | null }[] };
  const dates = [-6, -5, -4, -3, -2, -1].map(n => shiftDate(current.score_date!, n));
  const past = await Promise.all(dates.map(d => fetchRouteRisk(routeId, d).catch(() => null)));
  const trend = [
    ...past.map((r, i) => ({ date: dates[i], value: r?.state && r.state !== 'unavailable' ? r.summary?.max_percentile ?? null : null })),
    { date: current.score_date, value: current.summary?.max_percentile ?? null },
  ];
  return { current, trend };
}

function Section({ title, children, tag }: { title: string; children: React.ReactNode; tag?: React.ReactNode }) {
  return (
    <section className="space-y-3">
      <div className="flex items-center gap-3">
        <h2 className="text-xs font-semibold uppercase tracking-widest whitespace-nowrap" style={{ color: MUTED }}>{title}</h2>
        {tag}
        <div className="flex-1 border-t" style={{ borderColor: BORDER }} />
      </div>
      {children}
    </section>
  );
}

function FactorRow({ label, sub, value, display }: { label: string; sub: string; value: number | null; display?: string }) {
  const lv = level(value);
  return (
    <div className="grid items-center gap-4 py-3 border-b" style={{ gridTemplateColumns: 'minmax(160px,1fr) 2fr 72px', borderColor: BORDER }}>
      <div>
        <div className="text-sm font-semibold" style={{ color: INK }}>{label}</div>
        <div className="text-xs" style={{ color: MUTED }}>{sub}</div>
      </div>
      <div className="h-2.5 rounded-full overflow-hidden" style={{ background: 'rgba(180,162,136,0.3)' }}
        role="meter" aria-label={label} aria-valuemin={0} aria-valuemax={100} aria-valuenow={value ?? 0}>
        <div className="h-full rounded-full" style={{ width: `${Math.max(0, Math.min(100, value ?? 0))}%`, background: lv.color }} />
      </div>
      <div className="text-right">
        <div className="text-lg font-bold tabular-nums leading-tight" style={{ color: INK }}>{display ?? (value == null ? '—' : Math.round(value))}</div>
        <div className="text-xs font-medium" style={{ color: lv.color }}>{lv.label}</div>
      </div>
    </div>
  );
}

function TrendChart({ points }: { points: { date: string; value: number | null }[] }) {
  const known = points.filter(p => p.value != null);
  if (known.length < 2) {
    return <p className="text-xs" style={{ color: MUTED }}>Fewer than two published runs in the last 7 days — no trend to draw yet.</p>;
  }
  const W = 640, H = 150, pad = 24;
  const min = Math.min(80, ...known.map(p => p.value!)) - 2;
  const x = (i: number) => pad + (i * (W - pad * 2)) / (points.length - 1);
  const y = (v: number) => H - pad - ((v - min) / (100 - min)) * (H - pad * 2);
  const line = points.map((p, i) => (p.value == null ? null : `${x(i)},${y(p.value)}`)).filter(Boolean) as string[];
  const firstI = points.findIndex(p => p.value != null);
  const lastI = points.length - 1 - [...points].reverse().findIndex(p => p.value != null);
  const threshold = y(95);
  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="w-full h-auto" role="img"
      aria-label={`Peak segment risk over ${points.length} days: ${known.map(p => `${formatMlDate(p.date)} ${Math.round(p.value!)}`).join(', ')}`}>
      <polygon points={`${x(firstI)},${H - pad} ${line.join(' ')} ${x(lastI)},${H - pad}`} fill="rgba(190,36,36,0.1)" />
      <line x1={pad} x2={W - pad} y1={threshold} y2={threshold} stroke={MUTED} strokeDasharray="5 5" strokeWidth="1" />
      <text x={W - pad} y={threshold - 5} textAnchor="end" fontSize="11" fill={MUTED}>95th percentile</text>
      <polyline points={line.join(' ')} fill="none" stroke={RED} strokeWidth="2.5" strokeLinejoin="round" />
      {points.map((p, i) => p.value != null && <circle key={p.date} cx={x(i)} cy={y(p.value)} r={i === lastI ? 5 : 3} fill={RED} />)}
      {points.map((p, i) => (
        <text key={`l${p.date}`} x={x(i)} y={H - 6} textAnchor="middle" fontSize="10" fill={MUTED}>{p.date.slice(8)}/{p.date.slice(5, 7)}</text>
      ))}
    </svg>
  );
}

function CorridorMap({ path, risk, incidents }: { path: LatLng[]; risk: RouteRisk | null; incidents: { at: LatLng; label: string; blocked: boolean }[] }) {
  const el = useRef<HTMLDivElement>(null);
  const map = useRef<L.Map | null>(null);
  const layer = useRef<L.LayerGroup | null>(null);

  useEffect(() => {
    if (!el.current) return;
    const m = L.map(el.current, { scrollWheelZoom: false });
    L.tileLayer(OSM_TILES, { maxZoom: 19, attribution: OSM_ATTRIBUTION }).addTo(m);
    layer.current = L.layerGroup().addTo(m);
    map.current = m;
    return () => { m.remove(); map.current = null; };
  }, []);

  useEffect(() => {
    const m = map.current, g = layer.current;
    if (!m || !g) return;
    g.clearLayers();
    if (path.length) {
      L.polyline(path, { color: RED, weight: 4, opacity: 0.85 }).addTo(g);
      m.fitBounds(L.latLngBounds(path), { padding: [24, 24] });
    }
    for (const s of risk?.segments ?? []) {
      L.circleMarker([s.lat, s.lon], { radius: 4, color: s.tier === 'alert' ? RED : AMBER, fillOpacity: 0.8, weight: 1 })
        .bindTooltip(`${s.segment_id} · ${topShare(s.risk_percentile)}`).addTo(g);
    }
    const worst = risk?.summary?.worst;
    if (worst) {
      L.circleMarker([worst.lat, worst.lon], { radius: 9, color: '#fff', weight: 3, fillColor: RED, fillOpacity: 1 })
        .bindTooltip(`Riskiest segment ${worst.segment_id} · ${topShare(worst.risk_percentile)}`).addTo(g);
    }
    for (const inc of incidents) {
      L.circleMarker(inc.at, { radius: 7, color: inc.blocked ? RED : NAVY, weight: 2, fillColor: '#fff', fillOpacity: 1 })
        .bindTooltip(inc.label).addTo(g);
    }
  }, [path, risk, incidents]);

  return <div ref={el} className="w-full rounded-lg overflow-hidden" style={{ height: 320 }} aria-label="Corridor location map" role="region" />;
}

export default function CorridorDetail({ setPage }: { setPage?: (p: string) => void }) {
  const [routes, setRoutes] = useState<RouteOption[]>([]);
  const [routesError, setRoutesError] = useState<string | null>(null);
  const [routeId, setRouteId] = useState<string | null>(null);
  const [incidents, setIncidents] = useState(() => getIncidents());
  const [promoting, setPromoting] = useState(false);
  const summary = useMlQuery(fetchRoutesSummary);
  const { alerts } = useAlerts();
  const { shipments } = useShipments();

  useEffect(() => subscribeToIncidents(setIncidents), []);
  useEffect(() => {
    listRoutes().then(setRoutes).catch((e: Error) => setRoutesError(e.message));
  }, []);

  // Default to the riskiest corridor once the ML summary is in, else the first route.
  useEffect(() => {
    if (routeId || !routes.length) return;
    if (summary.loading && !summary.signedOut && !summary.error) return;
    const ranked = [...(summary.data?.routes ?? [])].sort((a, b) => (b.summary.max_percentile ?? -1) - (a.summary.max_percentile ?? -1));
    setRouteId(ranked[0]?.route_id ?? routes[0].id);
  }, [routes, routeId, summary.loading, summary.signedOut, summary.error, summary.data]);

  const route = routes.find(r => r.id === routeId) ?? null;
  const risk = useMlQuery(() => (routeId ? fetchCorridorRisk(routeId) : Promise.resolve(null)), [routeId]);
  const current = risk.data?.current ?? null;
  const s = current?.summary;
  const path = useMemo(() => (route ? corridorFor(route.route_number)?.path ?? [] : []), [route]);
  const lengthKm = current?.route_length_m
    ? Math.round(current.route_length_m / 1000)
    : path.length > 1 ? Math.round(path.slice(1).reduce((sum, p, i) => sum + distanceM(path[i], p), 0) / 1000) : null;

  // Incidents on this corridor: named route matches, or captured GPS within 1 km of the road.
  const routeIncidents = useMemo(() => {
    if (!route) return [];
    return incidents
      .filter(inc => {
        if (normalizeRouteId(inc.route) === route.route_number) return true;
        const at = inc.gpsCoords !== 'Not captured' ? locate({ gpsCoords: inc.gpsCoords }) : null;
        return !!at && path.length > 1 && distanceToLineM(at, path) <= NEAR_ROUTE_M;
      })
      .sort((a, b) => (b.reportedAt ?? '').localeCompare(a.reportedAt ?? ''));
  }, [incidents, route, path]);

  const open = routeIncidents.filter(i => i.status !== 'RESOLVED');
  const blocking = open.filter(i => i.roadCondition === 'Fully Blocked');
  const partial = open.filter(i => i.roadCondition === 'Partially Accessible');
  const status: RouteStatus = blocking.length ? 'Blocked' : partial.length ? 'Restricted' : 'Open';
  const since = [...blocking].sort((a, b) => (a.reportedAt ?? '').localeCompare(b.reportedAt ?? ''))[0] ?? null;

  const incidentIds = new Set(routeIncidents.map(i => i.id));
  const routeAlerts = alerts.filter(a => a.status === 'active' && a.incident_id && incidentIds.has(a.incident_id));
  const activeShipments = route ? shipments.filter(sh => sh.route_number === route.route_number && !DONE_SHIPMENT.includes(sh.status)) : [];
  const criticalShipments = activeShipments.filter(sh => ['at_risk', 'delayed'].includes(sh.status) || ['high', 'critical'].includes(sh.risk_level));
  const pending = open.filter(i => i.status === 'PENDING_VERIFICATION');

  const mapIncidents = useMemo(() => routeIncidents.flatMap(inc => {
    const at = locate(inc);
    return at ? [{ at, label: `${inc.type} · ${inc.location}`, blocked: inc.roadCondition === 'Fully Blocked' }] : [];
  }), [routeIncidents]);

  const segs = current?.segments ?? [];
  const covered = s && s.band !== 'no_coverage';
  const index = covered && s.max_percentile != null ? Math.round(s.max_percentile) : null;
  const flagged = s ? s.n_alert + s.n_human_review : 0;
  const factors = covered ? [
    { label: 'Peak segment risk', sub: `riskiest of ${s.n_matched} segments · ML percentile`, value: s.max_percentile },
    { label: 'Flagged segment risk', sub: `mean of ${segs.length} alert / review segments`, value: segs.length ? segs.reduce((t, x) => t + x.risk_percentile, 0) / segs.length : null },
    { label: 'Steep terrain share', sub: 'flagged segments on steep slopes', value: segs.length ? (segs.filter(x => x.steep).length / segs.length) * 100 : null, pct: true },
    { label: 'Model coverage', sub: `share of ${lengthKm ?? '—'} km scored by the model`, value: (current?.coverage_fraction ?? 0) * 100, pct: true },
  ] : [];

  const raiseAlert = async () => {
    const worst = s?.worst;
    if (!worst) return;
    setPromoting(true);
    try {
      await promoteMlAlert(worst.segment_id, current?.run_id, `Corridor ${route?.route_number}`);
      notify(`Alert raised for ${worst.segment_id} on ${route?.route_number}.`);
    } catch (e) {
      notify(e instanceof Error ? e.message : String(e), { tone: 'error' });
    } finally {
      setPromoting(false);
    }
  };

  const actions: { label: string; onClick?: () => void; busy?: boolean }[] = [];
  if (s?.worst && s.worst.tier === 'alert') actions.push({ label: `Raise alert for riskiest segment ${s.worst.segment_id}`, onClick: raiseAlert, busy: promoting });
  if ((blocking.length || partial.length) && activeShipments.length) actions.push({ label: `Reroute ${activeShipments.length} active consignment${activeShipments.length > 1 ? 's' : ''} around ${route?.route_number}`, onClick: () => setPage?.('routes') });
  if (pending.length) actions.push({ label: `Verify ${pending.length} pending field report${pending.length > 1 ? 's' : ''}`, onClick: () => setPage?.('incidents') });
  if (criticalShipments.length) actions.push({ label: `Review ${criticalShipments.length} at-risk consignment${criticalShipments.length > 1 ? 's' : ''}`, onClick: () => setPage?.('shipments') });
  if (routeAlerts.length) actions.push({ label: `Acknowledge ${routeAlerts.length} active alert${routeAlerts.length > 1 ? 's' : ''}`, onClick: () => setPage?.('alerts') });

  const lv = level(index);

  return (
    <div className="space-y-5">
      <div className="flex items-start justify-between flex-wrap gap-3">
        <div>
          <h1 className="font-semibold text-2xl" style={{ color: INK }}>Corridor Detail</h1>
          <p className="text-sm mt-0.5" style={{ color: MUTED }}>Risk, disruptions and disposition for one highway corridor</p>
        </div>
        <div className="flex items-center gap-4 flex-wrap">
          <div className="text-right">
            <div className="text-xs" style={{ color: MUTED }}>Active alerts on corridor</div>
            <div className="font-bold tabular-nums" style={{ color: routeAlerts.length ? RED : INK }}>{routeAlerts.length}</div>
          </div>
          <div className="text-right">
            <div className="text-xs" style={{ color: MUTED }}>Segments monitored</div>
            <div className="font-bold tabular-nums" style={{ color: INK }}>{s ? s.n_matched.toLocaleString('en-IN') : '—'}</div>
          </div>
          <label className="flex flex-col text-xs" style={{ color: MUTED }}>
            Corridor
            <select value={routeId ?? ''} onChange={e => setRouteId(e.target.value)} disabled={!routes.length}
              className="mt-0.5 rounded border px-2 py-1.5 text-sm min-w-[220px]" style={{ borderColor: BORDER, color: INK, background: 'rgba(255,253,249,0.9)' }}>
              {!routes.length && <option value="">{routesError ? 'Routes unavailable' : 'Loading routes…'}</option>}
              {routes.map(r => <option key={r.id} value={r.id}>{r.route_number} · {r.name}</option>)}
            </select>
          </label>
        </div>
      </div>

      {routesError && <p role="alert" className="text-sm" style={{ color: RED }}>Routes could not be loaded: {routesError}</p>}

      {route && (
        <div className="grid grid-cols-1 xl:grid-cols-[minmax(0,1.6fr)_minmax(0,1fr)] gap-5">
          {/* ── Left: identity, factors, trend, events ── */}
          <Card className="p-5 space-y-6">
            <div className="flex flex-wrap items-start justify-between gap-4 pb-5 border-b" style={{ borderColor: BORDER }}>
              <div className="min-w-0">
                <div className="text-xs font-semibold uppercase tracking-widest" style={{ color: ORANGE }}>{route.route_number}</div>
                <h2 className="text-2xl font-bold mt-1" style={{ color: INK }}>{route.name}</h2>
                <p className="text-sm mt-1" style={{ color: MUTED }}>
                  {lengthKm != null ? `${lengthKm} km` : 'Length unknown'}
                  {s ? ` · ${s.n_matched} ML segments matched` : ''}
                  {` · ${routeIncidents.length} recorded disruption${routeIncidents.length === 1 ? '' : 's'}`}
                </p>
              </div>
              <div className="text-right pl-5 border-l" style={{ borderColor: BORDER }}>
                <div className="text-5xl font-bold tabular-nums leading-none" style={{ color: lv.color }}>{index ?? '—'}</div>
                <div className="text-xs uppercase tracking-widest mt-2" style={{ color: MUTED }}>Risk index · {lv.label}</div>
                <div className="mt-2 flex justify-end"><StatusBadge status={status} /></div>
              </div>
            </div>

            <Section title="Contributing factors" tag={<MlSourceTag version={current?.model_version} />}>
              <MlNotice signedOut={risk.signedOut} error={risk.error} meta={current} />
              {risk.loading && !risk.data && !risk.signedOut && <LoadingRows label="Loading corridor risk…" />}
              {current && current.state !== 'unavailable' && !covered && (
                <p className="text-xs rounded-lg border px-3 py-2" style={{ color: MUTED, borderColor: BORDER }}>
                  This corridor is outside ML model coverage (Siliguri corridor, Sikkim, North Bengal). Status below comes from field reports.
                </p>
              )}
              {factors.length > 0 && (
                <div>
                  {factors.map(f => (
                    <FactorRow key={f.label} label={f.label} sub={f.sub} value={f.value}
                      display={f.value == null ? '—' : f.pct ? `${Math.round(f.value)}%` : undefined} />
                  ))}
                  <p className="text-xs mt-2" style={{ color: MUTED }}>
                    {s!.n_alert} high-risk and {s!.n_human_review} review segments ({flagged} flagged) · riskiest is {topShare(s!.max_percentile)} of corridor roads.
                  </p>
                </div>
              )}
            </Section>

            <Section title="7-day risk trend">
              <div className="rounded-lg border p-4" style={{ borderColor: BORDER, background: 'rgba(255,253,249,0.6)' }}>
                <div className="flex flex-wrap items-baseline justify-between gap-2 mb-2">
                  <div className="text-sm font-semibold" style={{ color: INK }}>Peak segment risk — last 7 runs</div>
                  <MlStatePill meta={current} signedOut={risk.signedOut} />
                </div>
                {risk.data ? <TrendChart points={risk.data.trend} /> : <p className="text-xs" style={{ color: MUTED }}>{risk.loading ? 'Loading…' : 'No ML data.'}</p>}
              </div>
              <MlCaveat meta={current} />
            </Section>

            <Section title="Recorded disruption events">
              {routeIncidents.length === 0 ? (
                <p className="text-sm" style={{ color: MUTED }}>No field reports recorded on this corridor.</p>
              ) : (
                <ul>
                  {routeIncidents.slice(0, 8).map(inc => (
                    <li key={inc.id} className="grid gap-4 py-3 border-b items-center" style={{ gridTemplateColumns: '90px 1fr auto', borderColor: BORDER }}>
                      <div className="text-sm font-semibold" style={{ color: INK }}>
                        {inc.reportedAt ? new Date(inc.reportedAt).toLocaleDateString('en-IN', { day: '2-digit', month: 'short' }) : '—'}
                        <div className="text-xs font-normal" style={{ color: MUTED }}>{inc.reportedAt ? new Date(inc.reportedAt).getFullYear() : ''}</div>
                      </div>
                      <div className="min-w-0">
                        <div className="text-sm" style={{ color: INK }}>{inc.type}{inc.roadCondition ? ` — ${inc.roadCondition.toLowerCase()}` : ''}</div>
                        <div className="text-xs truncate" style={{ color: MUTED }}>{inc.location}{inc.estimatedDisruption !== 'Not estimated' ? ` · ${inc.estimatedDisruption}` : ''}</div>
                      </div>
                      <div className="flex gap-1.5 flex-wrap justify-end">
                        <SeverityBadge severity={inc.severity} />
                        <StatusBadge status={inc.status} />
                      </div>
                    </li>
                  ))}
                </ul>
              )}
              {routeIncidents.length > 8 && (
                <button onClick={() => setPage?.('incidents')} className="text-xs font-medium" style={{ color: TEAL }}>
                  View all {routeIncidents.length} in Incidents →
                </button>
              )}
            </Section>
          </Card>

          {/* ── Right: map, disposition, actions ── */}
          <div className="space-y-5">
            <Card>
              <CardHeader title="Segment location" sub={`${route.route_number} · ${route.name}`} />
              <div className="p-3">
                {path.length ? <CorridorMap path={path} risk={current} incidents={mapIncidents} />
                  : <p className="text-sm p-3" style={{ color: MUTED }}>No map geometry for this route.</p>}
              </div>
            </Card>

            <Card>
              <CardHeader title="Current disposition" />
              <dl className="px-4 pb-2">
                {([
                  ['Operational status', <span style={{ color: status === 'Blocked' ? RED : status === 'Restricted' ? AMBER : GREEN }}>
                    {status === 'Blocked' ? `Closed — ${blocking[0].type.toLowerCase()}` : status === 'Restricted' ? `Restricted — ${partial[0].type.toLowerCase()}` : 'Open'}
                  </span>],
                  ['Closed since', since?.reportedAt ? new Date(since.reportedAt).toLocaleString('en-IN', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Kolkata' }) + ' IST' : '—'],
                  ['Est. reopening', since && since.estimatedDisruption !== 'Not estimated' ? since.estimatedDisruption : '—'],
                  ['Open incidents', `${open.length}${pending.length ? ` · ${pending.length} unverified` : ''}`],
                  ['Active alerts', String(routeAlerts.length)],
                  ['Affected consignments', `${activeShipments.length} active · ${criticalShipments.length} critical`],
                ] as [string, React.ReactNode][]).map(([k, v]) => (
                  <div key={k} className="flex justify-between gap-3 py-2.5 border-b last:border-b-0 text-sm" style={{ borderColor: BORDER }}>
                    <dt style={{ color: MUTED }}>{k}</dt>
                    <dd className="font-semibold text-right" style={{ color: INK }}>{v}</dd>
                  </div>
                ))}
              </dl>
            </Card>

            <Card>
              <CardHeader title="Recommended actions" />
              <ul className="px-4 pb-2">
                {actions.length === 0 ? (
                  <li className="py-3 text-sm" style={{ color: MUTED }}>No action needed — corridor is clear.</li>
                ) : actions.map(a => (
                  <li key={a.label} className="border-b last:border-b-0" style={{ borderColor: BORDER }}>
                    <button onClick={a.onClick} disabled={a.busy} aria-busy={a.busy}
                      className="ui-press w-full flex items-center gap-3 py-3 text-sm text-left disabled:opacity-60" style={{ color: INK }}>
                      <span aria-hidden="true" style={{ color: TEAL }}>→</span>
                      <span className="flex-1">{a.busy ? 'Working…' : a.label}</span>
                    </button>
                  </li>
                ))}
              </ul>
            </Card>
          </div>
        </div>
      )}
    </div>
  );
}
