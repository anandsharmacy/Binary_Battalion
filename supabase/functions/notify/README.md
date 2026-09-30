# notify: alert + shipment push delivery (push / email / SMS)

Two triggers POST here:
- Every new `public.alerts` row (ML promotion, officers, or a high/critical road incident via
  `road_incidents_raise_alert`). Recipients: active control_room users, plus officers whose
  `user_roles.district_id` matches the alert. Each user's `notification_prefs` decides the channels.
- Every `public.shipments` row that becomes `status = 'assigned'` (`shipments_notify`, migration
  `20260929100000_shipment_assignment.sql`). One push to that shipment's `rider_id`, unless their
  `notification_prefs.push` is `false`.

| Channel | Severity / event | Secrets | Missing secrets |
|---|---|---|---|
| Push (FCM HTTP v1) | alerts: all but `info`; shipments: always | `FCM_SERVICE_ACCOUNT_JSON` (whole service-account JSON) | logs `push: not configured` |
| Email (Resend) | alerts: high, critical | `RESEND_API_KEY`, `NOTIFY_EMAIL_FROM` (verified domain) | logs `email: not configured` |
| SMS (MSG91 Flow) | alerts: critical | `MSG91_AUTH_KEY`, `MSG91_TEMPLATE_ID` (DLT-approved, vars `##title##` `##severity##`) | logs `sms: not configured` |

Required: `NOTIFY_WEBHOOK_SECRET`. Optional: `NOTIFY_APP_URL` (a link that goes in the email).

## Deploy

**Status on the hosted project (`qzxaeidwjidkdhcdsxtu`), done 2026-09-30:** the function is deployed,
`NOTIFY_WEBHOOK_SECRET` is set, and the `notify_url` / `notify_secret` Vault secrets exist, so both
triggers now reach the function (verified with a direct `curl` against each branch). **Only
`FCM_SERVICE_ACCOUNT_JSON` is still missing** — until it's set, every push is skipped with
`push: not configured` and nothing else is affected. Redo these steps after a `supabase db reset`
or on a new project:

1. Apply migrations `20260927100050_alerts_notifications.sql` and `20260929100000_shipment_assignment.sql`.
2. Deploy the function: `supabase functions deploy notify --no-verify-jwt`
3. Set the secrets: `supabase secrets set NOTIFY_WEBHOOK_SECRET=... FCM_SERVICE_ACCOUNT_JSON="$(cat sa.json)" ...`
   (`openssl rand -hex 32` makes a good webhook secret.)
4. Create the two Vault secrets, using the **same value** as `NOTIFY_WEBHOOK_SECRET` for the second one:
   ```sql
   select vault.create_secret('https://<project-ref>.supabase.co/functions/v1/notify', 'notify_url');
   select vault.create_secret('<same random secret as NOTIFY_WEBHOOK_SECRET>', 'notify_secret');
   ```
   (`webhook.sql` documents the same two secrets; it only installs the `alerts` trigger, since
   `shipments_notify` is created by the shipment-assignment migration.)
5. Test it without touching real data — a shipment with a made-up id is safely ignored:
   ```sh
   curl -X POST "https://<project-ref>.supabase.co/functions/v1/notify" \
     -H "Content-Type: application/json" -H "x-notify-secret: <the secret>" \
     -d '{"type":"ASSIGNED","table":"shipments","schema":"public","record":{"id":"00000000-0000-0000-0000-000000000000","rider_id":"00000000-0000-0000-0000-000000000000","status":"assigned","shipment_number":"SHP-TEST"}}'
   ```
   Expect `HTTP 200` and `{"push":0,"skipped":"rider not found or push disabled"}`. Then check the
   function logs for the real thing: assign a shipment to a rider, or insert a critical alert.

## Firebase (Flutter push)

The server side above works without this; it only decides whether a push actually reaches a phone.

**Status, done 2026-09-30 via the Firebase CLI/MCP (project `ner-logistics-b77de`):**
- Both apps are registered: Android `in.gov.ner.ner_logistics` and iOS `in.gov.ner.nerLogistics`.
  (The iOS bundle ID used to be the placeholder `logistic` in every Xcode build config — fixed to a
  proper reverse-DNS ID, matching what `RunnerTests`' ID already implied.)
- `android/app/google-services.json` and `ios/Runner/GoogleService-Info.plist` are committed. Android's
  Gradle plugin (`android/settings.gradle.kts` + `app/build.gradle.kts`) activates automatically now
  that the file exists — verified with `./gradlew help` and a `processDebugGoogleServices` task check.
  iOS's project file was hand-edited to bundle the plist as a resource — verified with `plutil -lint`
  and `xcodebuild -list` (Xcode itself parses the project and resolves the Firebase SPM packages).
- `startPushRegistration` (`lib/features/alerts/push_registration.dart`) needs no further change: it
  already requests permission and registers the device token on sign-in.

**`FCM_SERVICE_ACCOUNT_JSON` is set (2026-09-30).** Android needs nothing further: rebuild the app
(the config file and Gradle wiring are already in place) and install it on a device — the token
registers on sign-in and pushes should arrive. Verified by creating+assigning+cancelling a real test
shipment and confirming in `function_logs` that the key is read (`notify shipment {"push":0}` with no
"not configured" line; `push:0` just means no device has registered a token yet).

**Still open — needs an Apple Developer account, not attempted:**
1. For iOS specifically, two more things beyond the JSON key:
   - Upload an APNs auth key in Firebase console → Project settings → Cloud Messaging → Apple app
     configuration.
   - Add the "Push Notifications" capability to the `Runner` target in Xcode (creates a
     `Runner.entitlements` file with `aps-environment`), which needs a provisioning profile from that
     same Apple Developer account — not something to generate headlessly.

Web push (service worker + VAPID) is not wired. The web app gets alerts live in the page through Realtime.
