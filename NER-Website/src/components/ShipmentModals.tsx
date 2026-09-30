import { useEffect, useState } from 'react';
import Modal from '@/components/Modal';
import { notify } from '@/lib/notify';
import type { Role } from '@/roles';
import {
  assignShipment, cancelShipment, createShipment, fetchShipments, listAssignableRiders, listDistricts, listRoutes,
  canAssign, type AssignableRider, type DistrictOption, type RouteOption, type Shipment,
} from '@/lib/shipments';

const BORDER = 'rgba(180,162,136,0.55)';
const SURFACE = 'rgba(250,247,240,0.82)';
const CARD = { background: '#FFFDF9', borderColor: BORDER };
const FIELD = { borderColor: BORDER, background: 'white', color: '#17212B' };
const LABEL = 'block text-xs font-medium mb-1';

const RISKS = ['low', 'medium', 'high', 'critical'];

export function riderLabel(r: AssignableRider): string {
  const where = r.current_district ? `in ${r.current_district} now` : r.home_district ? `home: ${r.home_district}` : 'no district';
  return [
    r.full_name || 'Unnamed rider',
    [r.vehicle_type, r.vehicle_registration].filter(Boolean).join(' ') || null,
    r.is_on_duty ? 'on duty' : 'off duty',
    where,
    r.open_shipments ? `${r.open_shipments} open` : null,
  ].filter(Boolean).join(' · ');
}

const errText = (e: unknown) => (e instanceof Error ? e.message : 'Something went wrong. Please try again.');

function ErrorLine({ message }: { message: string | null }) {
  if (!message) return null;
  return (
    <div role="alert" className="mt-3 rounded border px-3 py-2 text-xs" style={{ background: '#FEE9E9', borderColor: '#F5B8B8', color: '#BE2424' }}>
      {message}
    </div>
  );
}

function Actions({ onCancel, busy, submitLabel, disabled, danger, dismissLabel = 'Cancel' }:
  { onCancel: () => void; busy: boolean; submitLabel: string; disabled?: boolean; danger?: boolean; dismissLabel?: string }) {
  return (
    <div className="mt-5 flex justify-end gap-2">
      <button type="button" onClick={onCancel}
        className="ui-press text-sm font-medium px-4 py-2 rounded border" style={{ borderColor: BORDER, color: '#17212B', background: SURFACE }}>
        {dismissLabel}
      </button>
      <button type="submit" disabled={busy || disabled}
        className="ui-press text-sm font-semibold px-4 py-2 rounded disabled:opacity-60 disabled:cursor-not-allowed"
        style={{ background: danger ? '#BE2424' : '#17324D', color: 'white' }}>
        {busy ? 'Working…' : submitLabel}
      </button>
    </div>
  );
}

// ── Rider picker ─────────────────────────────────────────────────────────────────────────────────
function RiderSelect({ id, riders, value, onChange, required, emptyLabel }:
  { id: string; riders: AssignableRider[] | null; value: string; onChange: (v: string) => void; required?: boolean; emptyLabel: string }) {
  return (
    <select id={id} value={value} onChange={e => onChange(e.target.value)} required={required} disabled={riders === null}
      className="w-full rounded border px-3 py-2 text-sm" style={FIELD}>
      <option value="">{riders === null ? 'Loading riders…' : emptyLabel}</option>
      {(riders ?? []).map(r => <option key={r.user_id} value={r.user_id}>{riderLabel(r)}</option>)}
    </select>
  );
}

function useRiders(): [AssignableRider[] | null, string | null] {
  const [riders, setRiders] = useState<AssignableRider[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let cancelled = false;
    listAssignableRiders()
      .then(r => { if (!cancelled) setRiders(r); })
      .catch(e => { if (!cancelled) { setRiders([]); setError(errText(e)); } });
    return () => { cancelled = true; };
  }, []);
  return [riders, error];
}

// ── New shipment ─────────────────────────────────────────────────────────────────────────────────
export function NewShipmentModal({ open, role, onClose, onDone }:
  { open: boolean; role: Role; onClose: () => void; onDone: () => void }) {
  return (
    <Modal open={open} onClose={onClose} labelledBy="new-shipment-title">
      <NewShipmentForm role={role} onClose={onClose} onDone={onDone} />
    </Modal>
  );
}

function NewShipmentForm({ role, onClose, onDone }: { role: Role; onClose: () => void; onDone: () => void }) {
  const [riders, riderError] = useRiders();
  const [routes, setRoutes] = useState<RouteOption[]>([]);
  const [districts, setDistricts] = useState<DistrictOption[]>([]);
  const [f, setF] = useState({ cargo: '', weight: '', origin: '', destination: '', route: '', eta: '', risk: 'low', district: '', rider: '' });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const set = (k: keyof typeof f) => (v: string) => setF(cur => ({ ...cur, [k]: v }));
  const control = role === 'control';

  useEffect(() => {
    listRoutes().then(setRoutes).catch(() => setRoutes([]));
    if (control) listDistricts().then(setDistricts).catch(() => setDistricts([]));
  }, [control]);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      await createShipment({
        cargo_description: f.cargo, cargo_weight_kg: f.weight, origin: f.origin, destination: f.destination,
        route_id: f.route, risk_level: f.risk, district_id: control ? f.district : undefined, rider_id: f.rider,
        estimated_arrival: f.eta ? new Date(f.eta).toISOString() : undefined,
      });
      const rider = riders?.find(r => r.user_id === f.rider);
      notify(rider ? `Shipment created and assigned to ${rider.full_name || 'the rider'}.` : 'Shipment created. Assign a rider from the Unassigned tab.');
      onDone();
      onClose();
    } catch (err) {
      setError(errText(err));
      setBusy(false);
    }
  };

  return (
    <form onSubmit={submit} className="w-[34rem] max-w-full rounded-xl border p-5 shadow-2xl" style={CARD}>
      <h2 id="new-shipment-title" className="font-semibold text-base" style={{ color: '#17212B' }}>New shipment</h2>
      <p className="text-sm mt-1" style={{ color: '#5A6670' }}>
        {control ? 'Create a shipment in any district and optionally assign a rider now.' : 'Create a shipment in your district and optionally assign a rider now.'}
      </p>

      <div className="mt-4 grid grid-cols-1 sm:grid-cols-2 gap-3">
        {control && (
          <div className="sm:col-span-2">
            <label htmlFor="ns-district" className={LABEL} style={{ color: '#5A6670' }}>District *</label>
            <select id="ns-district" required value={f.district} onChange={e => set('district')(e.target.value)}
              className="w-full rounded border px-3 py-2 text-sm" style={FIELD}>
              <option value="">Choose a district</option>
              {districts.map(d => <option key={d.id} value={d.id}>{d.name}{d.state ? `, ${d.state}` : ''}</option>)}
            </select>
          </div>
        )}
        <div className="sm:col-span-2">
          <label htmlFor="ns-cargo" className={LABEL} style={{ color: '#5A6670' }}>Cargo</label>
          <input id="ns-cargo" value={f.cargo} onChange={e => set('cargo')(e.target.value)} placeholder="e.g. Medical kits, 40 boxes"
            className="w-full rounded border px-3 py-2 text-sm" style={FIELD} />
        </div>
        <div>
          <label htmlFor="ns-origin" className={LABEL} style={{ color: '#5A6670' }}>Pick-up *</label>
          <input id="ns-origin" required value={f.origin} onChange={e => set('origin')(e.target.value)} className="w-full rounded border px-3 py-2 text-sm" style={FIELD} />
        </div>
        <div>
          <label htmlFor="ns-dest" className={LABEL} style={{ color: '#5A6670' }}>Destination *</label>
          <input id="ns-dest" required value={f.destination} onChange={e => set('destination')(e.target.value)} className="w-full rounded border px-3 py-2 text-sm" style={FIELD} />
        </div>
        <div>
          <label htmlFor="ns-route" className={LABEL} style={{ color: '#5A6670' }}>Route</label>
          <select id="ns-route" value={f.route} onChange={e => set('route')(e.target.value)} className="w-full rounded border px-3 py-2 text-sm" style={FIELD}>
            <option value="">No fixed route</option>
            {routes.map(r => <option key={r.id} value={r.id}>{r.route_number} · {r.name}</option>)}
          </select>
        </div>
        <div>
          <label htmlFor="ns-eta" className={LABEL} style={{ color: '#5A6670' }}>Expected arrival</label>
          <input id="ns-eta" type="datetime-local" value={f.eta} onChange={e => set('eta')(e.target.value)} className="w-full rounded border px-3 py-2 text-sm" style={FIELD} />
        </div>
        <div>
          <label htmlFor="ns-weight" className={LABEL} style={{ color: '#5A6670' }}>Weight (kg)</label>
          <input id="ns-weight" type="number" min="0" step="any" value={f.weight} onChange={e => set('weight')(e.target.value)} className="w-full rounded border px-3 py-2 text-sm" style={FIELD} />
        </div>
        <div>
          <label htmlFor="ns-risk" className={LABEL} style={{ color: '#5A6670' }}>Risk level</label>
          <select id="ns-risk" value={f.risk} onChange={e => set('risk')(e.target.value)} className="w-full rounded border px-3 py-2 text-sm capitalize" style={FIELD}>
            {RISKS.map(r => <option key={r} value={r}>{r}</option>)}
          </select>
        </div>
        <div className="sm:col-span-2">
          <label htmlFor="ns-rider" className={LABEL} style={{ color: '#5A6670' }}>Assign to rider</label>
          <RiderSelect id="ns-rider" riders={riders} value={f.rider} onChange={set('rider')} emptyLabel="Assign later" />
          {riders !== null && riders.length === 0 && !riderError && (
            <p className="text-xs mt-1" style={{ color: 'var(--text-muted)' }}>No riders are available to you yet. You can still create the shipment and assign it later.</p>
          )}
        </div>
      </div>
      <ErrorLine message={error ?? riderError} />
      <Actions onCancel={onClose} busy={busy} submitLabel={f.rider ? 'Create and assign' : 'Create shipment'} />
    </form>
  );
}

// ── Assign a rider to a shipment ─────────────────────────────────────────────────────────────────
export function AssignRiderModal({ shipment, onClose, onDone }: { shipment: Shipment | null; onClose: () => void; onDone: () => void }) {
  return (
    <Modal open={shipment !== null} onClose={onClose} labelledBy="assign-rider-title">
      {shipment && <AssignRiderForm shipment={shipment} onClose={onClose} onDone={onDone} />}
    </Modal>
  );
}

function AssignRiderForm({ shipment, onClose, onDone }: { shipment: Shipment; onClose: () => void; onDone: () => void }) {
  const [riders, riderError] = useRiders();
  const [rider, setRider] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const reassign = shipment.status === 'assigned';

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      await assignShipment(shipment.id, rider);
      notify(`${shipment.shipment_number} assigned to ${riders?.find(r => r.user_id === rider)?.full_name || 'the rider'}.`);
      onDone();
      onClose();
    } catch (err) {
      setError(errText(err));
      setBusy(false);
    }
  };

  return (
    <form onSubmit={submit} className="w-[28rem] max-w-full rounded-xl border p-5 shadow-2xl" style={CARD}>
      <h2 id="assign-rider-title" className="font-semibold text-base" style={{ color: '#17212B' }}>
        {reassign ? 'Reassign' : 'Assign'} {shipment.shipment_number}
      </h2>
      <p className="text-sm mt-1" style={{ color: '#5A6670' }}>
        {shipment.origin} → {shipment.destination}{shipment.cargo_description ? ` · ${shipment.cargo_description}` : ''}
      </p>
      {reassign && (
        <p className="text-xs mt-2" style={{ color: '#7A6D2A' }}>
          Currently waiting on {shipment.rider_name || 'a rider'}. Reassigning sends it to the new rider instead.
        </p>
      )}
      <label htmlFor="ar-rider" className={`${LABEL} mt-4`} style={{ color: '#5A6670' }}>Rider *</label>
      <RiderSelect id="ar-rider" riders={riders} value={rider} onChange={setRider} required emptyLabel="Choose a rider" />
      {riders !== null && riders.length === 0 && !riderError && (
        <p className="text-xs mt-1" style={{ color: 'var(--text-muted)' }}>No riders are available to you yet.</p>
      )}
      <ErrorLine message={error ?? riderError} />
      <Actions onCancel={onClose} busy={busy} submitLabel={reassign ? 'Reassign' : 'Assign'} disabled={!rider} />
    </form>
  );
}

// ── Assign a shipment to a rider (from the Logistics rider panel) ────────────────────────────────
export function AssignToRiderModal({ rider, onClose, onDone }:
  { rider: { id: string; name: string } | null; onClose: () => void; onDone: () => void }) {
  return (
    <Modal open={rider !== null} onClose={onClose} labelledBy="assign-to-rider-title">
      {rider && <AssignToRiderForm rider={rider} onClose={onClose} onDone={onDone} />}
    </Modal>
  );
}

function AssignToRiderForm({ rider, onClose, onDone }: { rider: { id: string; name: string }; onClose: () => void; onDone: () => void }) {
  const [shipments, setShipments] = useState<Shipment[] | null>(null);
  const [pick, setPick] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    fetchShipments()
      .then(rows => { if (!cancelled) setShipments(rows.filter(canAssign)); })
      .catch(e => { if (!cancelled) { setShipments([]); setError(errText(e)); } });
    return () => { cancelled = true; };
  }, []);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      await assignShipment(pick, rider.id);
      notify(`${shipments?.find(s => s.id === pick)?.shipment_number ?? 'Shipment'} assigned to ${rider.name}.`);
      onDone();
      onClose();
    } catch (err) {
      setError(errText(err));
      setBusy(false);
    }
  };

  return (
    <form onSubmit={submit} className="w-[30rem] max-w-full rounded-xl border p-5 shadow-2xl" style={CARD}>
      <h2 id="assign-to-rider-title" className="font-semibold text-base" style={{ color: '#17212B' }}>Assign a shipment to {rider.name}</h2>
      <p className="text-sm mt-1" style={{ color: '#5A6670' }}>Shipments that no rider has accepted yet.</p>
      <label htmlFor="atr-shipment" className={`${LABEL} mt-4`} style={{ color: '#5A6670' }}>Shipment *</label>
      <select id="atr-shipment" required value={pick} onChange={e => setPick(e.target.value)} disabled={shipments === null}
        className="w-full rounded border px-3 py-2 text-sm" style={FIELD}>
        <option value="">{shipments === null ? 'Loading shipments…' : 'Choose a shipment'}</option>
        {(shipments ?? []).map(s => (
          <option key={s.id} value={s.id}>
            {s.shipment_number} · {s.origin} → {s.destination}{s.status === 'assigned' ? ` · waiting on ${s.rider_name || 'a rider'}` : ''}
          </option>
        ))}
      </select>
      {shipments !== null && shipments.length === 0 && !error && (
        <p className="text-xs mt-1" style={{ color: 'var(--text-muted)' }}>Nothing to assign. Create a shipment from the Shipments page first.</p>
      )}
      <ErrorLine message={error} />
      <Actions onCancel={onClose} busy={busy} submitLabel="Assign" disabled={!pick} />
    </form>
  );
}

// ── Cancel ───────────────────────────────────────────────────────────────────────────────────────
export function CancelShipmentModal({ shipment, onClose, onDone }: { shipment: Shipment | null; onClose: () => void; onDone: () => void }) {
  return (
    <Modal open={shipment !== null} onClose={onClose} labelledBy="cancel-shipment-title">
      {shipment && <CancelShipmentForm shipment={shipment} onClose={onClose} onDone={onDone} />}
    </Modal>
  );
}

function CancelShipmentForm({ shipment, onClose, onDone }: { shipment: Shipment; onClose: () => void; onDone: () => void }) {
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      await cancelShipment(shipment.id, reason);
      notify(`${shipment.shipment_number} cancelled.`);
      onDone();
      onClose();
    } catch (err) {
      setError(errText(err));
      setBusy(false);
    }
  };

  return (
    <form onSubmit={submit} className="w-[26rem] max-w-full rounded-xl border p-5 shadow-2xl" style={CARD}>
      <h2 id="cancel-shipment-title" className="font-semibold text-base" style={{ color: '#17212B' }}>Cancel {shipment.shipment_number}?</h2>
      <p className="text-sm mt-1.5" style={{ color: '#5A6670' }}>
        {shipment.rider_name ? `${shipment.rider_name} will no longer see this shipment.` : 'The shipment is closed and cannot be assigned.'}
      </p>
      <label htmlFor="cs-reason" className={`${LABEL} mt-4`} style={{ color: '#5A6670' }}>Reason (optional)</label>
      <textarea id="cs-reason" rows={3} value={reason} onChange={e => setReason(e.target.value)} className="w-full rounded border px-3 py-2 text-sm" style={FIELD} />
      <ErrorLine message={error} />
      <Actions onCancel={onClose} busy={busy} submitLabel="Cancel shipment" danger dismissLabel="Keep shipment" />
    </form>
  );
}
