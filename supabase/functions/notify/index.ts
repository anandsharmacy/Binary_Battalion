/**
 * Alert delivery fan-out. Called once per new row in public.alerts by the trigger in
 * ./webhook.sql (or a Dashboard Database Webhook with the same header).
 *
 * Recipients: every active control_room user, plus field/district officers of the alert's
 * district. Each user's notification_prefs (push/email/sms) decide the channels; a missing
 * prefs row means push+email on, SMS off.
 *
 * Channels by severity: push for all but `info`, email for high+critical, SMS for critical only.
 *
 * Also handles `{table:'shipments', type:'ASSIGNED'}` from the shipments_notify trigger
 * (migration 20260929100000): a push to the assigned rider only, honouring their push preference.
 * Each sender is skipped with a "not configured" log line when its secrets are unset:
 *   FCM_SERVICE_ACCOUNT_JSON              push (FCM HTTP v1; Android, iOS, web)
 *   RESEND_API_KEY + NOTIFY_EMAIL_FROM    email (Resend; FROM must be on a verified domain)
 *   MSG91_AUTH_KEY + MSG91_TEMPLATE_ID    SMS (MSG91 Flow; DLT-approved template)
 *   NOTIFY_WEBHOOK_SECRET                 required: shared secret in the x-notify-secret header
 *   NOTIFY_APP_URL                        optional: link placed in email/push
 */

import postgres from 'npm:postgres@3';

const env = (k: string) => Deno.env.get(k)?.trim() ?? '';
const secret = env('NOTIFY_WEBHOOK_SECRET');
const sql = postgres(env('SUPABASE_DB_URL'), { prepare: false, max: 1 });

type Alert = {
  id: string; title: string; description: string | null; severity: 'critical' | 'high' | 'moderate' | 'info';
  district_id: string | null; status: string;
};
type PushMessage = { title: string; body: string; data: Record<string, string> };
type Shipment = {
  id: string; shipment_number: string; cargo_description: string | null; origin: string | null;
  destination: string | null; rider_id: string | null; status: string;
};
type Recipient = { user_id: string; email: string | null; phone: string | null; push: boolean; email_on: boolean; sms: boolean };

function sameSecret(a: string, b: string): boolean {
  if (!b || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// ── FCM HTTP v1 ─────────────────────────────────────────────────────────────────────────────
type ServiceAccount = { project_id: string; client_email: string; private_key: string };
let fcmToken: { value: string; exp: number } | null = null;

const b64url = (b: ArrayBuffer | Uint8Array | string) =>
  btoa(typeof b === 'string' ? b : String.fromCharCode(...new Uint8Array(b)))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

async function fcmAccessToken(sa: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (fcmToken && fcmToken.exp - 60 > now) return fcmToken.value;
  const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = b64url(JSON.stringify({
    iss: sa.client_email, scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token', iat: now, exp: now + 3600,
  }));
  const pem = sa.private_key.replace(/-----[^-]+-----|\s/g, '');
  const key = await crypto.subtle.importKey(
    'pkcs8', Uint8Array.from(atob(pem), (c) => c.charCodeAt(0)),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign'],
  );
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(`${header}.${claims}`));
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${header}.${claims}.${b64url(sig)}`,
    }),
  });
  if (!res.ok) throw new Error(`FCM OAuth ${res.status}: ${await res.text()}`);
  const body = await res.json();
  fcmToken = { value: body.access_token, exp: now + (body.expires_in ?? 3600) };
  return fcmToken.value;
}

async function sendPush(msg: PushMessage, userIds: string[]): Promise<number> {
  const raw = env('FCM_SERVICE_ACCOUNT_JSON');
  if (!raw) { console.log('push: not configured (FCM_SERVICE_ACCOUNT_JSON unset)'); return 0; }
  if (!userIds.length) return 0;
  const sa = JSON.parse(raw) as ServiceAccount;
  const tokens = await sql<{ token: string }[]>`select token from public.device_tokens where user_id = any(${userIds}::uuid[])`;
  if (!tokens.length) return 0;
  const access = await fcmAccessToken(sa);
  let sent = 0;
  await Promise.all(tokens.map(async ({ token }) => {
    const res = await fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${access}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        message: {
          token,
          notification: { title: msg.title, body: msg.body },
          data: msg.data,
          android: { priority: 'high' },
        },
      }),
    });
    if (res.ok) { sent++; return; }
    const text = await res.text();
    // Uninstalled app / rotated token: drop it so we stop sending.
    if (res.status === 404 || text.includes('UNREGISTERED')) {
      await sql`delete from public.device_tokens where token = ${token}`;
    } else {
      console.error(`push: FCM ${res.status}: ${text.slice(0, 300)}`);
    }
  }));
  return sent;
}

// ── Email (Resend) ──────────────────────────────────────────────────────────────────────────
async function sendEmail(alert: Alert, to: string[]): Promise<number> {
  const key = env('RESEND_API_KEY'), from = env('NOTIFY_EMAIL_FROM');
  if (!key || !from) { console.log('email: not configured (RESEND_API_KEY / NOTIFY_EMAIL_FROM unset)'); return 0; }
  if (!to.length) return 0;
  const link = env('NOTIFY_APP_URL');
  const text = [alert.description ?? '', '', `Severity: ${alert.severity}`, link && `Open: ${link}`].filter((l) => l !== '').join('\n');
  // Resend batch endpoint: one message per recipient (no shared To: line), max 100 per call.
  let sent = 0;
  for (let i = 0; i < to.length; i += 100) {
    const res = await fetch('https://api.resend.com/emails/batch', {
      method: 'POST',
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(to.slice(i, i + 100).map((addr) => ({
        from, to: [addr], subject: `[NER ${alert.severity.toUpperCase()}] ${alert.title}`, text,
      }))),
    });
    if (res.ok) sent += Math.min(100, to.length - i);
    else console.error(`email: Resend ${res.status}: ${(await res.text()).slice(0, 300)}`);
  }
  return sent;
}

// ── SMS (MSG91 Flow; the template must be DLT-approved with vars ##title## ##severity##) ────
const msisdn = (p: string) => {
  const d = p.replace(/\D/g, '');
  return d.length === 10 ? `91${d}` : d.length === 12 && d.startsWith('91') ? d : null;
};

async function sendSms(alert: Alert, phones: string[]): Promise<number> {
  const key = env('MSG91_AUTH_KEY'), template = env('MSG91_TEMPLATE_ID');
  if (!key || !template) { console.log('sms: not configured (MSG91_AUTH_KEY / MSG91_TEMPLATE_ID unset)'); return 0; }
  const mobiles = [...new Set(phones.map(msisdn).filter((m): m is string => !!m))];
  if (!mobiles.length) return 0;
  const res = await fetch('https://control.msg91.com/api/v5/flow', {
    method: 'POST',
    headers: { authkey: key, 'Content-Type': 'application/json', accept: 'application/json' },
    body: JSON.stringify({
      template_id: template, short_url: '0',
      recipients: mobiles.map((m) => ({ mobiles: m, title: alert.title.slice(0, 30), severity: alert.severity.toUpperCase() })),
    }),
  });
  if (!res.ok) { console.error(`sms: MSG91 ${res.status}: ${(await res.text()).slice(0, 300)}`); return 0; }
  return mobiles.length;
}

// One push to the rider a shipment was just assigned to.
async function notifyShipment(s: Shipment | undefined): Promise<Response> {
  const json = (o: unknown) => new Response(JSON.stringify(o), { headers: { 'Content-Type': 'application/json' } });
  if (!s?.id || !s.rider_id || s.status !== 'assigned') return json({ skipped: 'shipment is not assigned to a rider' });
  const [rider] = await sql<{ push: boolean }[]>`
    select coalesce(np.push, true) as push
    from public.user_roles ur
    join public.profiles p on p.id = ur.user_id and p.is_active
    left join public.notification_prefs np on np.user_id = ur.user_id
    where ur.user_id = ${s.rider_id}::uuid and ur.is_active and ur.role = 'rider'`;
  if (!rider?.push) return json({ shipment_id: s.id, push: 0, skipped: 'rider not found or push disabled' });
  const body = [s.cargo_description, s.destination ? `to ${s.destination}` : null].filter(Boolean).join(' ');
  const push = await sendPush(
    { title: `New shipment ${s.shipment_number}`, body, data: { shipment_id: s.id, type: 'shipment_assigned' } },
    [s.rider_id],
  ).catch((e) => { console.error(e); return 0; });
  console.log('notify shipment', JSON.stringify({ shipment_id: s.id, push }));
  return json({ shipment_id: s.id, push });
}

Deno.serve(async (req) => {
  if (!secret) return new Response('NOTIFY_WEBHOOK_SECRET not configured', { status: 500 });
  if (req.method !== 'POST' || !sameSecret(req.headers.get('x-notify-secret') ?? '', secret)) {
    return new Response('forbidden', { status: 403 });
  }
  const body = await req.json().catch(() => null);
  if (body?.table === 'shipments' && body?.type === 'ASSIGNED') return notifyShipment(body.record as Shipment | undefined);
  const alert = body?.record as Alert | undefined;
  if (body?.table !== 'alerts' || body?.type !== 'INSERT' || !alert?.id) {
    return new Response(JSON.stringify({ skipped: 'not an alerts INSERT' }), { status: 200 });
  }

  const recipients = await sql<Recipient[]>`
    select ur.user_id, u.email::text as email, p.phone,
           coalesce(np.push, true) as push, coalesce(np.email, true) as email_on, coalesce(np.sms, false) as sms
    from public.user_roles ur
    join public.profiles p on p.id = ur.user_id and p.is_active
    join auth.users u on u.id = ur.user_id
    left join public.notification_prefs np on np.user_id = ur.user_id
    where ur.is_active
      and (ur.role = 'control_room'
           or (ur.role in ('district_officer', 'field_officer') and ur.district_id = ${alert.district_id}::uuid))`;

  const sev = alert.severity;
  const settle = (p: Promise<number>) => p.catch((e) => { console.error(e); return 0; });
  const [push, email, sms] = await Promise.all([
    settle(sev === 'info' ? Promise.resolve(0) : sendPush(
      { title: `${alert.severity.toUpperCase()}: ${alert.title}`, body: alert.description ?? '',
        data: { alert_id: alert.id, severity: alert.severity } },
      recipients.filter((r) => r.push).map((r) => r.user_id))),
    settle(sev === 'critical' || sev === 'high'
      ? sendEmail(alert, recipients.filter((r) => r.email_on && r.email).map((r) => r.email!))
      : Promise.resolve(0)),
    settle(sev === 'critical'
      ? sendSms(alert, recipients.filter((r) => r.sms && r.phone).map((r) => r.phone!))
      : Promise.resolve(0)),
  ]);
  const result = { alert_id: alert.id, recipients: recipients.length, push, email, sms };
  console.log('notify', JSON.stringify(result));
  return new Response(JSON.stringify(result), { headers: { 'Content-Type': 'application/json' } });
});
