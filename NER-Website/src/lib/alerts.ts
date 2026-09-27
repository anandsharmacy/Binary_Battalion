import { useEffect, useState } from 'react';
import type { RealtimeChannel } from '@supabase/supabase-js';
import { supabase } from '@/lib/supabase';
import { notify } from '@/lib/notify';

export type AlertSeverity = 'critical' | 'high' | 'moderate' | 'info';
export type AlertStatus = 'active' | 'acknowledged' | 'resolved';

export interface AlertRow {
  id: string;
  title: string;
  description: string | null;
  severity: AlertSeverity;
  status: AlertStatus;
  source: 'human' | 'rule' | 'feed' | 'ml';
  district_id: string | null;
  incident_id: string | null;
  acknowledged_by: string | null;
  acknowledged_at: string | null;
  resolved_by: string | null;
  resolved_at: string | null;
  created_at: string;
  district: { name: string } | null;
  /** Display names for acknowledged_by / resolved_by (profiles lookup). */
  acknowledgedByName?: string | null;
  resolvedByName?: string | null;
}

export interface AlertsState {
  alerts: AlertRow[];
  loading: boolean;
  error: string | null;
}

// One shared query + realtime channel for every component that shows alerts (Shell badge, page).
let state: AlertsState = { alerts: [], loading: true, error: null };
const listeners = new Set<(s: AlertsState) => void>();
let channel: RealtimeChannel | null = null;

function set(next: Partial<AlertsState>) {
  state = { ...state, ...next };
  listeners.forEach(l => l(state));
}

async function load() {
  if (!supabase) { set({ loading: false, error: 'Backend not configured' }); return; }
  const { data, error } = await supabase
    .from('alerts')
    .select('id,title,description,severity,status,source,district_id,incident_id,acknowledged_by,acknowledged_at,resolved_by,resolved_at,created_at,district:locations(name)')
    .order('created_at', { ascending: false })
    .limit(200);
  if (error) { set({ loading: false, error: error.message }); return; }
  const rows = (data ?? []) as unknown as AlertRow[];
  const ids = [...new Set(rows.flatMap(r => [r.acknowledged_by, r.resolved_by]).filter((x): x is string => !!x))];
  if (ids.length) {
    const { data: people } = await supabase.from('profiles').select('id,full_name').in('id', ids);
    const names = new Map((people ?? []).map(p => [p.id as string, p.full_name as string | null]));
    rows.forEach(r => {
      r.acknowledgedByName = r.acknowledged_by ? names.get(r.acknowledged_by) ?? null : null;
      r.resolvedByName = r.resolved_by ? names.get(r.resolved_by) ?? null : null;
    });
  }
  set({ alerts: rows, loading: false, error: null });
}

function start() {
  if (!supabase || channel) return;
  void load();
  channel = supabase
    .channel('alerts-feed')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'alerts' }, payload => {
      const row = payload.new as Partial<AlertRow>;
      if (payload.eventType === 'INSERT' && (row.severity === 'critical' || row.severity === 'high')) {
        notify(`${row.severity === 'critical' ? 'Critical' : 'High'} alert: ${row.title}`, { tone: 'error' });
      }
      // ponytail: refetch the latest 200 on every change; patch rows in place if volume grows.
      void load();
    })
    .subscribe();
}

function stop() {
  if (supabase && channel) void supabase.removeChannel(channel);
  channel = null;
}

/** Live list of alerts visible to the signed-in officer (RLS), newest first. */
export function useAlerts(): AlertsState {
  const [s, setS] = useState(state);
  useEffect(() => {
    listeners.add(setS);
    start();
    setS(state);
    return () => {
      listeners.delete(setS);
      if (!listeners.size) stop();
    };
  }, []);
  return s;
}

/** Acknowledge or resolve; the server records auth.uid() as the actor. */
export async function setAlertStatus(id: string, status: 'acknowledged' | 'resolved') {
  if (!supabase) throw new Error('Backend not configured');
  const { error } = await supabase.rpc('set_alert_status', { p_alert_id: id, p_status: status });
  if (error) throw new Error(error.message);
  await load();
}
