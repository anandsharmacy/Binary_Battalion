-- Wires public.alerts INSERT -> the `notify` edge function. NOT a migration: run it by hand
-- (SQL editor) after deploying the function and setting its secrets. Safe to re-run.
--
-- 1. supabase functions deploy notify --no-verify-jwt   (auth is the shared secret below)
-- 2. supabase secrets set NOTIFY_WEBHOOK_SECRET=<random 32+ chars> [FCM_/RESEND_/MSG91_ ...]
-- 3. Store the same values in Vault, then run this file:
--      select vault.create_secret('https://<project-ref>.supabase.co/functions/v1/notify', 'notify_url');
--      select vault.create_secret('<same random secret>', 'notify_secret');
--
-- Until both Vault secrets exist the trigger does nothing, so alerts inserts never fail on it.
-- (Equivalent alternative: Dashboard > Database > Webhooks, table alerts, INSERT, HTTP POST to the
--  function URL with header x-notify-secret. Use one or the other, not both.)

create extension if not exists pg_net with schema extensions;

create or replace function public.notify_alert_webhook()
returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_url    text := (select decrypted_secret from vault.decrypted_secrets where name = 'notify_url');
  v_secret text := (select decrypted_secret from vault.decrypted_secrets where name = 'notify_secret');
begin
  if v_url is null or v_secret is null then return new; end if;
  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-notify-secret', v_secret),
    body    := jsonb_build_object('type', 'INSERT', 'table', 'alerts', 'schema', 'public', 'record', to_jsonb(new))
  );
  return new;
end $$;
revoke execute on function public.notify_alert_webhook() from public, anon, authenticated;

drop trigger if exists alerts_notify on public.alerts;
create trigger alerts_notify after insert on public.alerts
  for each row execute function public.notify_alert_webhook();
