import { useCallback, useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';
import Modal from '@/components/Modal';
import EmptyState from '@/components/EmptyState';
import { Icon } from '@/auth/Icons';
import { notify } from '@/lib/notify';

// Pending sign-ups the signed-in officer may review. The database decides who sees what
// (pending_accounts / review_account): district officers get field officers of their own
// district, the control room gets every pending account.

interface PendingAccount {
  user_id: string;
  full_name: string | null;
  email: string;
  role: string;
  district: string | null;
  state: string | null;
  requested_at: string;
}

const ROLE_LABELS: Record<string, string> = {
  field_officer: 'Field Officer',
  district_officer: 'District Officer',
  control_room: 'Control Room',
};

const BORDER = 'rgba(180,162,136,0.55)';
const spinner = <span aria-hidden="true" className="ui-spin">↻</span>;
const SURFACE = 'rgba(250,247,240,0.82)';

export default function Approvals() {
  const [accounts, setAccounts] = useState<PendingAccount[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<{ id: string; approve: boolean } | null>(null);
  const [rejecting, setRejecting] = useState<PendingAccount | null>(null);
  const [query, setQuery] = useState('');

  const load = useCallback(async () => {
    if (!supabase) {
      setError('The sign-in service is not configured for this build.');
      setLoading(false);
      return;
    }
    setLoading(true);
    const { data, error: rpcError } = await supabase.rpc('pending_accounts');
    if (rpcError) setError('Could not load approval requests. Please try again.');
    else {
      setError(null);
      setAccounts((data ?? []) as PendingAccount[]);
    }
    setLoading(false);
  }, []);

  useEffect(() => { void load(); }, [load]);

  const review = async (account: PendingAccount, approve: boolean) => {
    if (!supabase) return;
    setBusy({ id: account.user_id, approve });
    const { error: rpcError } = await supabase.rpc('review_account', { p_user_id: account.user_id, p_approve: approve });
    setBusy(null);
    if (rpcError) {
      setError(rpcError.message || 'Could not update this request. Please try again.');
      return;
    }
    setAccounts(current => current.filter(item => item.user_id !== account.user_id));
    // Server RPC: no undo, so the message states the outcome plainly.
    notify(`${approve ? 'Approved' : 'Rejected'} ${account.full_name || account.email}.`);
  };
  const rejectingName = rejecting ? rejecting.full_name || rejecting.email : '';
  const needle = query.trim().toLowerCase();
  const visible = accounts.filter(a => !needle || [a.full_name ?? '', a.email].some(v => v.toLowerCase().includes(needle)));

  return (
    <div className="space-y-5 max-w-screen-2xl">
      <div className="flex items-start justify-between flex-wrap gap-3">
        <div>
          <h1 className="font-semibold text-2xl" style={{ color: '#17212B' }}>Approvals</h1>
          <p className="text-sm mt-0.5" style={{ color: '#5A6670' }}>New account requests waiting for your approval</p>
        </div>
        <button onClick={() => void load()} disabled={loading} aria-busy={loading}
          className="ui-press inline-flex items-center gap-1.5 text-xs font-medium px-3 py-2 rounded border disabled:opacity-60"
          style={{ borderColor: BORDER, color: '#2F6F7E', background: SURFACE }}>
          {loading ? <>Refreshing… {spinner}</> : 'Refresh ↻'}
        </button>
      </div>

      {error && (
        <div role="alert" className="rounded-lg border px-4 py-2.5 text-xs" style={{ background: '#FEE9E9', borderColor: '#F5B8B8', color: '#BE2424' }}>
          {error}
        </div>
      )}

      <div className="rounded-xl border shadow-sm overflow-hidden" style={{ background: SURFACE, borderColor: BORDER }}>
        <div className="px-4 py-3 border-b flex flex-wrap items-center justify-between gap-2" style={{ borderColor: BORDER, background: 'rgba(238,228,210,0.88)' }}>
          <span className="text-sm font-medium" style={{ color: '#17212B' }}>
            {visible.length} request{visible.length !== 1 ? 's' : ''}
          </span>
          <input type="search" value={query} onChange={e => setQuery(e.target.value)}
            onKeyDown={e => { if (e.key === 'Escape' && query) { e.preventDefault(); setQuery(''); } }}
            aria-label="Search account requests" placeholder="Search name or email"
            className="text-xs px-2 py-1.5 rounded border w-full sm:w-52" style={{ borderColor: BORDER, background: SURFACE }} />
        </div>
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr style={{ background: 'rgba(238,228,210,0.88)' }}>
                {['Name', 'Email', 'Requested Role', 'District', 'State', 'Requested', 'Actions'].map(h => (
                  <th key={h} scope="col" className="text-left px-4 py-2.5 text-xs font-semibold uppercase tracking-wider whitespace-nowrap" style={{ color: '#5A6670' }}>{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {loading ? (
                [0, 1, 2].map(row => (
                  <tr key={row} aria-hidden="true">
                    <td colSpan={7} className="px-4 py-3"><div className="ui-skeleton h-4" /></td>
                  </tr>
                ))
              ) : visible.length === 0 && needle ? (
                <tr><td colSpan={7}><EmptyState icon={<Icon name="search" size={22} />} title="No matches" message={`No requests match “${query.trim()}”.`} action={{ label: 'Clear search', run: () => setQuery('') }} /></td></tr>
              ) : visible.length === 0 ? (
                <tr><td colSpan={7}><EmptyState icon={<Icon name="approvals" size={22} />} title="No pending account requests" message="New sign-ups you can review will appear here." action={{ label: 'Refresh', run: () => void load() }} /></td></tr>
              ) : visible.map((account, i) => {
                const pending = busy?.id === account.user_id;
                return (
                <tr key={account.user_id} style={{ background: i % 2 === 0 ? SURFACE : 'rgba(243,235,220,0.55)' }}>
                  <td className="px-4 py-2.5 text-xs font-semibold" style={{ color: '#17212B' }}>{account.full_name || '—'}</td>
                  <td className="px-4 py-2.5 text-xs" style={{ color: '#5A6670' }}>{account.email}</td>
                  <td className="px-4 py-2.5 text-xs" style={{ color: '#17212B' }}>{ROLE_LABELS[account.role] ?? account.role}</td>
                  <td className="px-4 py-2.5 text-xs" style={{ color: '#5A6670' }}>{account.district || '—'}</td>
                  <td className="px-4 py-2.5 text-xs" style={{ color: '#5A6670' }}>{account.state || '—'}</td>
                  <td className="px-4 py-2.5 text-xs whitespace-nowrap" style={{ color: 'var(--text-muted)' }}>
                    {new Date(account.requested_at).toLocaleString('en-IN', { dateStyle: 'medium', timeStyle: 'short' })}
                  </td>
                  <td className="px-4 py-2.5">
                    <span className="inline-flex gap-1">
                      <button onClick={() => void review(account, true)} disabled={pending} aria-busy={pending && busy.approve}
                        className="ui-press inline-flex items-center gap-1 text-xs px-2 py-1 rounded border disabled:opacity-60"
                        style={{ borderColor: '#A8D4B8', background: '#EAF4EE', color: '#2D6B4F' }}>
                        {pending && busy.approve ? <>Approving… {spinner}</> : 'Approve'}
                      </button>
                      <button onClick={() => setRejecting(account)} disabled={pending} aria-busy={pending && !busy.approve}
                        className="ui-press inline-flex items-center gap-1 text-xs px-2 py-1 rounded border disabled:opacity-60"
                        style={{ borderColor: '#F5B8B8', background: '#FEE9E9', color: '#BE2424' }}>
                        {pending && !busy.approve ? <>Rejecting… {spinner}</> : 'Reject'}
                      </button>
                    </span>
                  </td>
                </tr>
                );
              })}
            </tbody>
          </table>
          {loading && <span className="sr-only" role="status">Loading requests…</span>}
        </div>
      </div>

      <Modal open={rejecting !== null} onClose={() => setRejecting(null)} labelledBy="reject-title">
        <div className="w-[26rem] max-w-full rounded-xl border p-5 shadow-2xl" style={{ background: '#FFFDF9', borderColor: BORDER }}>
          <h2 id="reject-title" className="font-semibold text-base" style={{ color: '#17212B' }}>Reject {rejectingName}'s request?</h2>
          <p className="text-sm mt-1.5" style={{ color: '#5A6670' }}>They won't be able to sign in. This can't be undone from here.</p>
          <div className="mt-5 flex justify-end gap-2">
            <button type="button" autoFocus onClick={() => setRejecting(null)}
              className="ui-press text-sm font-medium px-4 py-2 rounded border" style={{ borderColor: BORDER, color: '#17212B', background: SURFACE }}>Cancel</button>
            <button type="button" onClick={() => { const account = rejecting!; setRejecting(null); void review(account, false); }}
              className="ui-press text-sm font-semibold px-4 py-2 rounded" style={{ background: '#BE2424', color: 'white' }}>Reject</button>
          </div>
        </div>
      </Modal>
    </div>
  );
}
