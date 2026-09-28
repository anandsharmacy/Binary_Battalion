import { useMemo, useState } from 'react';
import type { Role } from '@/roles';
import EmptyState from '@/components/EmptyState';
import { Icon } from '@/auth/Icons';
import { StatusBadge } from '@/components/StatusBadge';
import { AssignRiderModal, CancelShipmentModal, NewShipmentModal } from '@/components/ShipmentModals';
import {
  canAssign, canCancel, statusLabel, tabOf, TAB_LABEL, useShipments, type Shipment, type ShipmentTab,
} from '@/lib/shipments';
import { SURFACE, BORDER } from './fo/ui';

const TABS = Object.keys(TAB_LABEL) as ShipmentTab[];
const HEADERS = ['Shipment', 'Route', 'Pick-up → Destination', 'District', 'Rider', 'Expected', 'Status', 'Actions'];

function ago(iso: string): string {
  const min = Math.round((Date.now() - Date.parse(iso)) / 60_000);
  if (min < 1) return 'just now';
  if (min < 60) return `${min} min ago`;
  const h = Math.round(min / 60);
  return h < 48 ? `${h} h ago` : `${Math.round(h / 24)} d ago`;
}
const when = (iso: string | null) =>
  iso ? new Date(iso).toLocaleString([], { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }) : '—';

/** Why a shipment is where it is, in one line (declines and cancellations matter to the officer). */
function note(s: Shipment): { text: string; tone: 'warn' | 'muted' } | null {
  if (s.status === 'scheduled' && s.declined_at) {
    return { text: `Declined by ${s.declined_by_name || 'the rider'}${s.decline_reason ? `: ${s.decline_reason}` : ''}`, tone: 'warn' };
  }
  if (s.status === 'cancelled' && s.cancel_reason) return { text: `Cancelled: ${s.cancel_reason}`, tone: 'muted' };
  return null;
}

export default function Shipments({ role }: { role: Role }) {
  const { shipments, loading, error, live, reload } = useShipments();
  const [tab, setTab] = useState<ShipmentTab>('unassigned');
  const [query, setQuery] = useState('');
  const [creating, setCreating] = useState(false);
  const [assigning, setAssigning] = useState<Shipment | null>(null);
  const [cancelling, setCancelling] = useState<Shipment | null>(null);

  const counts = useMemo(() => {
    const c: Record<ShipmentTab, number> = { unassigned: 0, awaiting: 0, active: 0, delivered: 0, cancelled: 0 };
    shipments.forEach(s => { c[tabOf(s)] += 1; });
    return c;
  }, [shipments]);

  const needle = query.trim().toLowerCase();
  const rows = shipments.filter(s => tabOf(s) === tab &&
    (!needle || [s.shipment_number, s.cargo_description, s.origin, s.destination, s.rider_name, s.route_number, s.district]
      .some(v => v?.toLowerCase().includes(needle))));

  const control = role === 'control';

  return (
    <div className="space-y-5 max-w-screen-2xl">
      <div className="flex items-start justify-between flex-wrap gap-3">
        <div>
          <h1 className="font-semibold text-2xl" style={{ color: '#17212B' }}>Shipments</h1>
          <p className="text-sm mt-0.5" style={{ color: '#5A6670' }}>
            {control ? 'Create shipments and assign them to riders across all districts' : 'Create shipments and assign them to riders in your district'}
          </p>
        </div>
        <div className="flex items-center gap-3">
          <span className="text-xs font-medium" role="status" style={{ color: live ? '#2D6B4F' : '#5A6670' }}>
            {loading ? 'Connecting…' : live ? '● Live' : '○ Polling every 30 s'}
          </span>
          <button type="button" onClick={() => setCreating(true)}
            className="ui-press text-sm font-semibold px-4 py-2 rounded" style={{ background: '#17324D', color: 'white' }}>
            + New shipment
          </button>
        </div>
      </div>

      {error && (
        <div role="alert" className="rounded-lg border px-4 py-2 text-sm" style={{ background: '#FEE9E9', borderColor: '#F5B8B8', color: '#BE2424' }}>
          Shipments unavailable: {error}
        </div>
      )}

      <div className="grid grid-cols-2 sm:grid-cols-5 gap-3">
        {TABS.map(t => (
          <button key={t} type="button" onClick={() => setTab(t)} aria-pressed={tab === t}
            className="ui-card rounded-xl border p-3 text-left transition-all"
            style={{ background: tab === t ? '#17324D' : SURFACE, borderColor: tab === t ? '#17324D' : BORDER }}>
            <div className="text-2xl font-bold" style={{ color: tab === t ? 'white' : '#17212B' }}>{counts[t]}</div>
            <div className="text-xs mt-0.5" style={{ color: tab === t ? '#8AAFC8' : '#5A6670' }}>{TAB_LABEL[t]}</div>
          </button>
        ))}
      </div>

      <div className="rounded-xl border shadow-sm overflow-hidden" style={{ background: SURFACE, borderColor: BORDER }}>
        <div className="px-4 py-3 border-b flex flex-wrap items-center justify-between gap-2" style={{ borderColor: BORDER, background: 'rgba(238,228,210,0.88)' }}>
          <span className="text-sm font-medium" style={{ color: '#17212B' }}>
            {rows.length} shipment{rows.length !== 1 ? 's' : ''} · {TAB_LABEL[tab]}
          </span>
          <input type="search" value={query} onChange={e => setQuery(e.target.value)}
            onKeyDown={e => { if (e.key === 'Escape' && query) { e.preventDefault(); setQuery(''); } }}
            aria-label="Search shipments" placeholder="Search number, cargo, place or rider"
            className="text-xs px-2 py-1.5 rounded border w-full sm:w-64" style={{ borderColor: BORDER, background: 'white' }} />
        </div>
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr style={{ background: 'rgba(243,235,220,0.55)' }}>
                {HEADERS.map(h => (
                  <th key={h} scope="col" className="text-left px-4 py-2.5 text-xs font-semibold uppercase tracking-wider whitespace-nowrap"
                    style={{ color: '#5A6670' }}>{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {rows.map((s, i) => {
                const n = note(s);
                return (
                  <tr key={s.id} style={{ background: i % 2 === 0 ? 'rgba(250,247,240,0.82)' : 'rgba(243,235,220,0.55)' }}>
                    <td className="px-4 py-2.5">
                      <div className="font-mono text-xs font-semibold" style={{ color: '#2F6F7E' }}>{s.shipment_number}</div>
                      <div className="text-xs mt-0.5" style={{ color: '#17212B' }}>
                        {s.cargo_description || 'No cargo description'}{s.cargo_weight_kg ? ` · ${s.cargo_weight_kg} kg` : ''}
                      </div>
                      {n && <div className="text-xs mt-0.5" style={{ color: n.tone === 'warn' ? '#BE2424' : 'var(--text-muted)' }}>{n.text}</div>}
                    </td>
                    <td className="px-4 py-2.5 text-xs font-mono" style={{ color: '#5A6670' }}>{s.route_number ?? '—'}</td>
                    <td className="px-4 py-2.5 text-xs" style={{ color: '#17212B' }}>{s.origin} → {s.destination}</td>
                    <td className="px-4 py-2.5 text-xs" style={{ color: '#17212B' }}>{s.district ?? '—'}</td>
                    <td className="px-4 py-2.5 text-xs" style={{ color: s.rider_name ? '#17212B' : 'var(--text-muted)' }}>
                      {s.rider_name ? <>{s.rider_name}{s.rider_officer_id && <span className="font-mono" style={{ color: '#2F6F7E' }}> · {s.rider_officer_id}</span>}</> : '— None'}
                    </td>
                    <td className="px-4 py-2.5 text-xs whitespace-nowrap" style={{ color: '#17212B' }}>{when(s.estimated_arrival)}</td>
                    <td className="px-4 py-2.5">
                      <StatusBadge status={statusLabel(s.status)} />
                      <div className="text-xs mt-1 whitespace-nowrap" style={{ color: 'var(--text-muted)' }}>{ago(s.updated_at)}</div>
                    </td>
                    <td className="px-4 py-2.5 whitespace-nowrap">
                      {canAssign(s) && (
                        <button type="button" onClick={() => setAssigning(s)} className="text-xs px-2 py-1 rounded border mr-1.5"
                          style={{ borderColor: '#A8CDD8', background: '#E6F0F4', color: '#1E5A6E' }}>
                          {s.status === 'assigned' ? 'Reassign' : 'Assign rider'}
                        </button>
                      )}
                      {canCancel(s) && (
                        <button type="button" onClick={() => setCancelling(s)} className="text-xs px-2 py-1 rounded border"
                          style={{ borderColor: '#F5B8B8', background: '#FEE9E9', color: '#BE2424' }}>Cancel</button>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          {rows.length === 0 && (loading
            ? <div className="py-8 text-center text-xs" style={{ color: 'var(--text-muted)' }}>Loading shipments…</div>
            : shipments.length === 0
              ? <EmptyState icon={<Icon name="truck" size={22} />} title="No shipments yet"
                  message="Create a shipment and assign it to a rider. The rider sees it in the NER app straight away."
                  action={{ label: '+ New shipment', run: () => setCreating(true) }} />
              : <EmptyState icon={<Icon name="search" size={22} />} title={query ? 'No shipments match your search' : `Nothing in ${TAB_LABEL[tab]}`}
                  message={query ? 'Try another search term.' : 'Shipments move here as they progress.'}
                  action={query ? { label: 'Clear search', run: () => setQuery('') } : undefined} />)}
        </div>
      </div>

      <NewShipmentModal open={creating} role={role} onClose={() => setCreating(false)} onDone={() => void reload()} />
      <AssignRiderModal shipment={assigning} onClose={() => setAssigning(null)} onDone={() => void reload()} />
      <CancelShipmentModal shipment={cancelling} onClose={() => setCancelling(null)} onDone={() => void reload()} />
    </div>
  );
}
