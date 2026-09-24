import { useCallback, useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase';

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
const SURFACE = 'rgba(250,247,240,0.82)';

export default function Approvals() {
  const [accounts, setAccounts] = useState<PendingAccount[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

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
    if (!approve && !window.confirm(`Reject the account request from ${account.full_name || account.email}?`)) return;
    setBusy(account.user_id);
    const { error: rpcError } = await supabase.rpc('review_account', { p_user_id: account.user_id, p_approve: approve });
    setBusy(null);
    if (rpcError) {
      setError(rpcError.message || 'Could not update this request. Please try again.');
      return;
    }
    setAccounts(current => current.filter(item => item.user_id !== account.user_id));
  };

  return (
    <div className="space-y-5 max-w-screen-2xl">
      <div className="flex items-start justify-between">
        <div>
          <h1 className="font-semibold text-2xl" style={{ color: '#17212B' }}>Approvals</h1>
          <p className="text-sm mt-0.5" style={{ color: '#5A6670' }}>New account requests waiting for your approval</p>
        </div>
        <button onClick={() => void load()} disabled={loading}
          className="text-xs font-medium px-3 py-2 rounded border disabled:opacity-60"
          style={{ borderColor: BORDER, color: '#2F6F7E', background: SURFACE }}>
          Refresh ↻
        </button>
      </div>

      {error && (
        <div role="alert" className="rounded-lg border px-4 py-2.5 text-xs" style={{ background: '#FEE9E9', borderColor: '#F5B8B8', color: '#BE2424' }}>
          {error}
        </div>
      )}

      <div className="rounded-xl border shadow-sm overflow-hidden" style={{ background: SURFACE, borderColor: BORDER }}>
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr style={{ background: 'rgba(238,228,210,0.88)' }}>
                {['Name', 'Email', 'Requested Role', 'District', 'State', 'Requested', 'Actions'].map(h => (
                  <th key={h} className="text-left px-4 py-2.5 text-xs font-semibold uppercase tracking-wider whitespace-nowrap" style={{ color: '#5A6670' }}>{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {loading ? (
                <tr><td colSpan={7} className="px-4 py-10 text-center text-sm" style={{ color: '#8A9098' }}>Loading requests…</td></tr>
              ) : accounts.length === 0 ? (
                <tr><td colSpan={7} className="px-4 py-10 text-center text-sm" style={{ color: '#8A9098' }}>No pending account requests.</td></tr>
              ) : accounts.map((account, i) => (
                <tr key={account.user_id} style={{ background: i % 2 === 0 ? SURFACE : 'rgba(243,235,220,0.55)' }}>
                  <td className="px-4 py-2.5 text-xs font-semibold" style={{ color: '#17212B' }}>{account.full_name || '—'}</td>
                  <td className="px-4 py-2.5 text-xs" style={{ color: '#5A6670' }}>{account.email}</td>
                  <td className="px-4 py-2.5 text-xs" style={{ color: '#17212B' }}>{ROLE_LABELS[account.role] ?? account.role}</td>
                  <td className="px-4 py-2.5 text-xs" style={{ color: '#5A6670' }}>{account.district || '—'}</td>
                  <td className="px-4 py-2.5 text-xs" style={{ color: '#5A6670' }}>{account.state || '—'}</td>
                  <td className="px-4 py-2.5 text-xs whitespace-nowrap" style={{ color: '#8A9098' }}>
                    {new Date(account.requested_at).toLocaleString('en-IN', { dateStyle: 'medium', timeStyle: 'short' })}
                  </td>
                  <td className="px-4 py-2.5">
                    <span className="inline-flex gap-1">
                      <button onClick={() => void review(account, true)} disabled={busy === account.user_id}
                        className="text-xs px-2 py-1 rounded border disabled:opacity-60"
                        style={{ borderColor: '#A8D4B8', background: '#EAF4EE', color: '#2D6B4F' }}>Approve</button>
                      <button onClick={() => void review(account, false)} disabled={busy === account.user_id}
                        className="text-xs px-2 py-1 rounded border disabled:opacity-60"
                        style={{ borderColor: '#F5B8B8', background: '#FEE9E9', color: '#BE2424' }}>Reject</button>
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}
