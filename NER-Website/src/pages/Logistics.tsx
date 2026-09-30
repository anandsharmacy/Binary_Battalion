import { useEffect, useState } from 'react';
import EmptyState from '@/components/EmptyState';
import { Icon } from '@/auth/Icons';
import { StatusBadge } from '@/components/StatusBadge';
import MapViz from '@/components/MapViz';
import { routes } from '@/data/demo';
import type { LatLng } from '@/data/geo';
import { AssignToRiderModal } from '@/components/ShipmentModals';
import { fetchRiderTrail, STALE_MINUTES, useLiveRiders, type LiveRider } from '@/lib/riderTracking';

const BORDER = 'rgba(180,162,136,0.55)';
const PANEL = { background: 'rgba(250,247,240,0.82)', borderColor: BORDER };

function ago(iso: string, now: number): string {
  const min = Math.round((now - Date.parse(iso)) / 60_000);
  if (min < 1) return 'just now';
  if (min < 60) return `${min} min ago`;
  const h = Math.round(min / 60);
  return h < 48 ? `${h} h ago` : `${Math.round(h / 24)} d ago`;
}

const COMPASS = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
const heading = (deg: number | null) => (deg == null ? '—' : `${Math.round(deg)}° ${COMPASS[Math.round(deg / 45) % 8]}`);
const speed = (kmph: number | null) => (kmph == null ? '—' : `${Math.round(kmph)} km/h`);
const status = (r: LiveRider) => (r.stale ? 'Stale' : r.onDuty ? 'Active' : 'Off duty');

export default function Logistics() {
  const { riders, loading, error, live, now } = useLiveRiders();
  const [selectedRiderId, setSelectedRiderId] = useState<string | null>(null);
  const [trail, setTrail] = useState<LatLng[]>([]);
  const [trailError, setTrailError] = useState<string | null>(null);
  const [assigning, setAssigning] = useState(false);
  const selected = riders.find(r => r.id === selectedRiderId) ?? null;

  useEffect(() => {
    setTrail([]);
    setTrailError(null);
    if (!selectedRiderId) return;
    let cancelled = false;
    fetchRiderTrail(selectedRiderId)
      .then(points => { if (!cancelled) setTrail(points); })
      .catch((e: Error) => { if (!cancelled) setTrailError(e.message); });
    return () => { cancelled = true; };
  }, [selectedRiderId]);

  // Extend the loaded trail with live fixes that arrive while the rider is selected.
  const pos = selected?.position;
  const shownTrail = pos && trail.length && (trail[trail.length - 1][0] !== pos[0] || trail[trail.length - 1][1] !== pos[1])
    ? [...trail, pos] : trail;

  const kpis = [
    { label: 'Riders reporting', value: riders.length, color: '#17324D', bg: '#E6EDF4' },
    { label: 'On duty', value: riders.filter(r => r.onDuty && !r.stale).length, color: '#2F6F7E', bg: '#E6F0F4' },
    { label: 'Moving', value: riders.filter(r => r.isMoving && !r.stale).length, color: '#2D6B4F', bg: '#EAF4EE' },
    { label: `Stale (>${STALE_MINUTES} min)`, value: riders.filter(r => r.stale).length, color: '#5A6670', bg: '#F0EFED' },
  ];
  const toggleRider = (id: string) => setSelectedRiderId(current => (current === id ? null : id));
  const empty = !loading && !error && riders.length === 0;

  return (
    <div className="space-y-5 max-w-screen-2xl">
      <div className="flex items-end justify-between gap-3 flex-wrap">
        <div>
          <h1 className="font-semibold text-2xl" style={{ color: '#17212B' }}>Logistics</h1>
          <p className="text-sm mt-0.5" style={{ color: '#5A6670' }}>Live GPS tracking of riders in your area</p>
        </div>
        <span className="text-xs font-medium" role="status" style={{ color: live ? '#2D6B4F' : '#5A6670' }}>
          {loading ? 'Connecting…' : live ? '● Live' : '○ Polling every 30 s'}
        </span>
      </div>

      {error && (
        <div role="alert" className="rounded-lg border px-4 py-2 text-sm" style={{ background: '#FEE9E9', borderColor: '#F5B8B8', color: '#BE2424' }}>
          Rider feed unavailable: {error}
        </div>
      )}

      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        {kpis.map(k => (
          <div key={k.label} className="rounded-xl border p-4 shadow-sm" style={{ background: k.bg, borderColor: BORDER }}>
            <div className="text-3xl font-bold" style={{ color: k.color }}>{k.value}</div>
            <div className="text-xs font-medium mt-1" style={{ color: k.color }}>{k.label}</div>
          </div>
        ))}
      </div>

      <div className="grid grid-cols-1 xl:grid-cols-3 gap-5">
        <div className="xl:col-span-2 rounded-xl border shadow-sm overflow-hidden" style={PANEL}>
          <div className="px-4 py-3 border-b flex items-center justify-between gap-3" style={{ borderColor: BORDER }}>
            <h2 className="font-semibold text-base" style={{ color: '#17212B' }}>Live Rider Map</h2>
            {selectedRiderId && (
              <button type="button" onClick={() => setSelectedRiderId(null)} className="text-xs font-medium" style={{ color: '#2F6F7E' }}>
                Show all
              </button>
            )}
          </div>
          <MapViz incidents={[]} routes={routes} riders={riders} selectedRiderId={selectedRiderId} onSelectRider={setSelectedRiderId}
            riderTrail={shownTrail} height={380} showLegend />
        </div>

        <div className="rounded-xl border shadow-sm" style={PANEL}>
          <div className="px-4 py-3 border-b flex items-center justify-between gap-3" style={{ borderColor: BORDER }}>
            <h2 className="font-semibold text-base" style={{ color: '#17212B' }}>{selected ? selected.name : 'Rider Details'}</h2>
            {selected && (
              <button type="button" onClick={() => setAssigning(true)} className="ui-press text-xs font-semibold px-3 py-1.5 rounded"
                style={{ background: '#17324D', color: 'white' }}>
                Assign shipment
              </button>
            )}
          </div>
          {!selected ? (
            <EmptyState icon={<Icon name="truck" size={22} />}
              title={empty ? 'No riders reporting yet' : 'Select a rider'}
              message={empty ? 'Riders appear here once they go on duty in the NER app and share location.' : 'Click a marker or a table row to see the last fix, speed, heading and recent trail.'} />
          ) : (
            <dl className="px-4 py-3 grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 text-xs">
              {([
                ['Status', <StatusBadge key="s" status={status(selected)} />],
                ['Last fix', `${ago(selected.recordedAt, now)} · ${new Date(selected.recordedAt).toLocaleTimeString()}`],
                ['Speed', speed(selected.speedKmph)],
                ['Heading', heading(selected.headingDeg)],
                ['Position', `${selected.position[0].toFixed(5)}, ${selected.position[1].toFixed(5)}`],
                ['Battery', selected.batteryPercent == null ? '—' : `${selected.batteryPercent}%`],
                ['District', selected.district ?? '—'],
                ['Vehicle', [selected.vehicleType, selected.vehicleRegistration].filter(Boolean).join(' · ') || '—'],
                ['Phone', selected.phone ?? '—'],
                ['Shipment', selected.shipmentNumber ? `${selected.shipmentNumber}${selected.destination ? ` → ${selected.destination}` : ''}` : 'None'],
                ['Trail (2 h)', trailError ? `Unavailable: ${trailError}` : trail.length ? `${shownTrail.length} fixes` : 'No history in the last 2 h'],
              ] as [string, React.ReactNode][]).map(([k, v]) => (
                <div key={k} className="contents">
                  <dt style={{ color: '#5A6670' }}>{k}</dt>
                  <dd style={{ color: '#17212B' }}>{v}</dd>
                </div>
              ))}
            </dl>
          )}
        </div>
      </div>

      <div className="rounded-xl border shadow-sm overflow-hidden" style={PANEL}>
        <div className="px-4 py-3 border-b" style={{ borderColor: BORDER, background: 'rgba(238,228,210,0.88)' }}>
          <h2 className="font-semibold text-base" style={{ color: '#17212B' }}>Riders</h2>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr style={{ background: 'rgba(243,235,220,0.55)' }}>
                {['Rider', 'Officer ID', 'District', 'Vehicle', 'Status', 'Speed', 'Last fix'].map(h => (
                  <th key={h} scope="col" className="text-left px-4 py-2.5 text-xs font-semibold uppercase tracking-wider whitespace-nowrap"
                    style={{ color: '#5A6670' }}>{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {riders.length === 0 && (
                <tr><td colSpan={7}>
                  {loading
                    ? <div className="py-8 text-center text-xs" style={{ color: 'var(--text-muted)' }}>Loading riders…</div>
                    : <EmptyState icon={<Icon name="truck" size={22} />} title="No riders reporting yet" message="Riders appear here once their app starts sharing location." />}
                </td></tr>
              )}
              {riders.map((r, i) => {
                const isSel = r.id === selectedRiderId;
                return (
                  <tr key={r.id} onClick={() => toggleRider(r.id)} className="cursor-pointer" aria-selected={isSel}
                    style={{
                      background: isSel ? 'rgba(47,111,126,0.12)' : i % 2 === 0 ? 'rgba(250,247,240,0.82)' : 'rgba(243,235,220,0.55)',
                      opacity: r.stale ? 0.55 : 1,
                    }}>
                    <td className="px-4 py-2.5 text-xs font-medium" style={{ color: '#17212B' }}>
                      <button type="button" className="text-left" aria-pressed={isSel} onClick={e => { e.stopPropagation(); toggleRider(r.id); }}>{r.name}</button>
                    </td>
                    <td className="px-4 py-2.5 font-mono text-xs" style={{ color: '#2F6F7E' }}>{r.officerId ?? '—'}</td>
                    <td className="px-4 py-2.5 text-xs" style={{ color: '#17212B' }}>{r.district ?? '—'}</td>
                    <td className="px-4 py-2.5 text-xs" style={{ color: '#5A6670' }}>{[r.vehicleType, r.vehicleRegistration].filter(Boolean).join(' · ') || '—'}</td>
                    <td className="px-4 py-2.5"><StatusBadge status={status(r)} /></td>
                    <td className="px-4 py-2.5 text-xs" style={{ color: '#17212B' }}>{speed(r.speedKmph)}</td>
                    <td className="px-4 py-2.5 text-xs whitespace-nowrap" style={{ color: '#17212B' }}>{ago(r.recordedAt, now)}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </div>

      <AssignToRiderModal rider={assigning && selected ? { id: selected.id, name: selected.name } : null}
        onClose={() => setAssigning(false)} onDone={() => setAssigning(false)} />
    </div>
  );
}
