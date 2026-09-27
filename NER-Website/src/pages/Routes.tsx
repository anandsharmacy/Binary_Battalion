import { useEffect, useRef, useState } from 'react';
import L from 'leaflet';
import 'leaflet/dist/leaflet.css';
import { MlBandPill, MlCaveat, MlRouteSummary, MlRoutesBoard, MlStatePill } from '@/components/MlRisk';
import EmptyState from '@/components/EmptyState';
import { Icon } from '@/auth/Icons';
import { NER_CENTER, NER_ZOOM, type LatLng } from '@/data/geo';
import { supabase } from '@/lib/supabase';
import { planRoute, usesPublicOsrm, type PlannedRoute, type RoutePlan } from '@/lib/routing';
import { SURFACE as CARD, SURFACE_2 as HEAD, BORDER } from './fo/ui';

interface Place {
  id: string;
  name: string;
  state: string;
  at: LatLng;
}


/** PostgREST returns geography as hex EWKB; a point is SRID-tagged x, y doubles. */
function ewkbPoint(hex: string | null): LatLng | null {
  if (!hex || hex.length < 50) return null;
  const bytes = new Uint8Array(hex.match(/../g)!.map(h => parseInt(h, 16)));
  const v = new DataView(bytes.buffer);
  const le = bytes[0] === 1;
  const hasSrid = (v.getUint32(1, le) & 0x20000000) !== 0;
  const o = hasSrid ? 9 : 5;
  return [v.getFloat64(o + 8, le), v.getFloat64(o, le)];
}

const km = (m: number) => `${Math.round(m / 1000)} km`;
function eta(s: number) {
  const h = Math.floor(s / 3600), m = Math.round((s % 3600) / 60);
  return h ? `${h} h ${m} min` : `${m} min`;
}
const KIND_LABEL = { fastest: 'Fastest', alternative: 'Alternative', detour: 'Detour around hazard' } as const;

function PlanMap({ plan, selected, onSelect }: { plan: RoutePlan | null; selected: number; onSelect: (i: number) => void }) {
  const el = useRef<HTMLDivElement>(null);
  const map = useRef<L.Map | null>(null);
  const layer = useRef<L.LayerGroup | null>(null);

  useEffect(() => {
    if (!el.current) return;
    const m = L.map(el.current, { center: NER_CENTER, zoom: NER_ZOOM });
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19, attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
    }).addTo(m);
    map.current = m;
    layer.current = L.layerGroup().addTo(m);
    return () => { m.remove(); map.current = null; };
  }, []);

  useEffect(() => {
    const g = layer.current;
    if (!g || !map.current) return;
    g.clearLayers();
    if (!plan) return;
    // Selected route last so it draws on top.
    const order = plan.routes.map((_, i) => i).filter(i => i !== selected).concat(selected);
    for (const i of order) {
      const r = plan.routes[i];
      const on = i === selected;
      L.polyline(r.geometry, {
        color: r.blocked ? '#BE2424' : on ? '#2F6F7E' : '#5A6670',
        weight: on ? 6 : 4, opacity: on ? 0.95 : 0.55, dashArray: on ? undefined : '6 8',
      }).on('click', () => onSelect(i)).bindTooltip(`${KIND_LABEL[r.kind]} · ${km(r.distanceM)} · ${eta(r.durationS)}`).addTo(g);
    }
    for (const h of plan.hazards) {
      L.circleMarker(h.at, { radius: 7, color: '#BE2424', fillColor: '#BE2424', fillOpacity: 0.8 })
        .bindTooltip(`Active ${h.type.replace('_', ' ')} (${h.severity})`).addTo(g);
    }
    const sel = plan.routes[selected];
    if (sel) map.current.fitBounds(L.latLngBounds(sel.geometry), { padding: [24, 24] });
  }, [plan, selected, onSelect]);

  return <div ref={el} className="w-full rounded-lg border" style={{ height: 460, borderColor: BORDER }} role="region" aria-label="Route map" />;
}

function RouteCard({ r, recommended, selected, onSelect, plan }: {
  r: PlannedRoute; recommended: boolean; selected: boolean; onSelect: () => void; plan: RoutePlan;
}) {
  return (
    <button type="button" onClick={onSelect} aria-pressed={selected}
      className="w-full text-left rounded-lg border p-3 space-y-2"
      style={{ borderColor: selected ? '#2F6F7E' : BORDER, background: selected ? 'rgba(47,111,126,0.08)' : 'rgba(255,253,249,0.6)', borderWidth: selected ? 2 : 1 }}>
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-sm font-semibold" style={{ color: '#17212B' }}>{KIND_LABEL[r.kind]}</span>
        {recommended && <span className="text-xs font-semibold px-2 py-0.5 rounded" style={{ background: '#EAF4EE', color: '#2D6B4F' }}>✓ Recommended</span>}
        {r.blocked && <span className="text-xs font-semibold px-2 py-0.5 rounded" style={{ background: '#FEE9E9', color: '#BE2424' }}>▲ Passes an active hazard</span>}
      </div>
      <div className="grid grid-cols-3 gap-2 text-xs">
        <div><div style={{ color: 'var(--text-muted)' }}>Distance</div><div className="font-semibold tabular-nums" style={{ color: '#17212B' }}>{km(r.distanceM)}</div></div>
        <div><div style={{ color: 'var(--text-muted)' }}>ETA</div><div className="font-semibold tabular-nums" style={{ color: '#17212B' }}>{eta(r.durationS)}</div></div>
        <div><div style={{ color: 'var(--text-muted)' }}>Nearest hazard</div><div className="font-semibold tabular-nums" style={{ color: '#17212B' }}>{Number.isFinite(r.hazardClearanceM) ? km(r.hazardClearanceM) : 'None active'}</div></div>
      </div>
      {r.summary && <div className="text-xs" style={{ color: '#5A6670' }}>Via {r.summary}</div>}
      {r.risk?.summary
        ? (selected
          ? <MlRouteSummary meta={r.risk} summary={r.risk.summary} coverage={r.risk.coverage_fraction} lengthM={r.risk.route_length_m} showState={false} />
          : <MlBandPill band={r.risk.summary.band} />)
        : <div className="text-xs" style={{ color: 'var(--text-muted)' }}>{plan.mlSignedOut ? 'Sign in for ML risk' : r.risk ? 'ML risk unavailable (no published run)' : 'ML risk not scored'}</div>}
    </button>
  );
}

export default function Routes() {
  const [places, setPlaces] = useState<Place[] | null>(null);
  const [placesError, setPlacesError] = useState<string | null>(null);
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [plan, setPlan] = useState<RoutePlan | null>(null);
  const [selected, setSelected] = useState(0);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!supabase) { setPlaces([]); return; }
    supabase.from('locations').select('id, name, state, geom').eq('kind', 'district').not('geom', 'is', null)
      .order('state').order('name')
      .then(({ data, error }) => {
        if (error) { setPlacesError(error.message); setPlaces([]); return; }
        setPlaces((data ?? []).flatMap(r => {
          const at = ewkbPoint(r.geom as string);
          return at ? [{ id: r.id, name: r.name, state: r.state, at }] : [];
        }));
      });
  }, []);

  async function run() {
    const a = places?.find(p => p.id === from), b = places?.find(p => p.id === to);
    if (!a || !b) return;
    setBusy(true); setError(null); setPlan(null);
    try {
      const p = await planRoute(a.at, b.at);
      setPlan(p);
      setSelected(Math.max(p.best, 0));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  const byState = (places ?? []).reduce<Record<string, Place[]>>((acc, p) => ((acc[p.state] ??= []).push(p), acc), {});
  const options = Object.entries(byState).map(([state, list]) => (
    <optgroup key={state} label={state}>{list.map(p => <option key={p.id} value={p.id}>{p.name}</option>)}</optgroup>
  ));
  const riskMeta = plan?.routes.find(r => r.risk)?.risk ?? null;

  return (
    <div className="space-y-5 max-w-screen-2xl">
      <div>
        <h1 className="font-semibold text-2xl" style={{ color: '#17212B' }}>Routes</h1>
        <p className="text-sm mt-0.5" style={{ color: '#5A6670' }}>Plan a road route: alternatives scored by active hazards and ML disruption risk</p>
      </div>

      <div className="rounded-xl border shadow-sm" style={{ background: CARD, borderColor: BORDER }}>
        <div className="px-4 py-3 border-b flex flex-wrap items-end gap-3" style={{ borderColor: BORDER, background: HEAD }}>
          <label className="text-xs" style={{ color: '#5A6670' }}>From (district HQ)
            <select value={from} onChange={e => setFrom(e.target.value)} className="block mt-1 text-sm px-2 py-1.5 rounded border min-w-52" style={{ borderColor: BORDER, background: CARD }}>
              <option value="">Select…</option>{options}
            </select>
          </label>
          <label className="text-xs" style={{ color: '#5A6670' }}>To (district HQ)
            <select value={to} onChange={e => setTo(e.target.value)} className="block mt-1 text-sm px-2 py-1.5 rounded border min-w-52" style={{ borderColor: BORDER, background: CARD }}>
              <option value="">Select…</option>{options}
            </select>
          </label>
          <button type="button" onClick={run} disabled={!from || !to || from === to || busy}
            className="text-sm font-medium px-4 py-1.5 rounded disabled:opacity-50 disabled:cursor-not-allowed min-h-[34px]"
            style={{ background: '#17324D', color: 'white' }}>
            {busy ? 'Planning…' : 'Plan route'}
          </button>
          {riskMeta && <MlStatePill meta={riskMeta} signedOut={plan?.mlSignedOut} />}
          {usesPublicOsrm && <span className="text-xs" style={{ color: 'var(--text-muted)' }}>Routing: public OSRM demo server (set VITE_OSRM_URL for production)</span>}
        </div>

        <div className="p-4 grid grid-cols-1 xl:grid-cols-5 gap-4">
          <div className="xl:col-span-2 space-y-3" aria-live="polite">
            {places?.length === 0 && (
              <EmptyState icon={<Icon name="route" size={22} />} title="No places to route between"
                message={placesError ?? (supabase ? 'District locations have no coordinates yet (apply migration 20260927100020).' : 'Sign in to plan routes.')} />
            )}
            {error && <p className="text-sm" role="alert" style={{ color: '#BE2424' }}>Routing failed: {error}</p>}
            {plan?.mlError && <p className="text-xs" style={{ color: '#9A6412' }}>ML risk could not be scored: {plan.mlError}</p>}
            {plan && plan.best < 0 && (
              <p className="text-sm font-medium" role="alert" style={{ color: '#BE2424' }}>
                Every route found passes an active hazard and no detour exists. Hold the trip or clear the incident.
              </p>
            )}
            {plan?.routes.map((r, i) => (
              <RouteCard key={i} r={r} plan={plan} recommended={i === plan.best} selected={i === selected} onSelect={() => setSelected(i)} />
            ))}
            {!plan && !busy && places && places.length > 0 && (
              <p className="text-sm" style={{ color: 'var(--text-muted)' }}>Choose two places. The recommendation avoids routes within 800 m of an open flood, landslide or blockage, then prefers the lowest ML risk within 1.5× the fastest time.</p>
            )}
            {riskMeta && <MlCaveat meta={riskMeta} />}
          </div>
          <div className="xl:col-span-3">
            <PlanMap plan={plan} selected={selected} onSelect={setSelected} />
          </div>
        </div>
      </div>

      <MlRoutesBoard />
    </div>
  );
}
