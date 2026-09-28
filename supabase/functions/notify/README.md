# notify: alert delivery (push / email / SMS)

Each new `public.alerts` row (from ML promotion, officers, or high/critical road incidents via the
`road_incidents_raise_alert` trigger) is POSTed here. The function picks the recipients: active
control_room users, plus officers whose `user_roles.district_id` matches the alert. Each user's
`notification_prefs` then decides the channels.

| Channel | Severity | Secrets | Missing secrets |
|---|---|---|---|
| Push (FCM HTTP v1) | all except `info` | `FCM_SERVICE_ACCOUNT_JSON` (whole service-account JSON) | logs `push: not configured` |
| Email (Resend) | high, critical | `RESEND_API_KEY`, `NOTIFY_EMAIL_FROM` (verified domain) | logs `email: not configured` |
| SMS (MSG91 Flow) | critical | `MSG91_AUTH_KEY`, `MSG91_TEMPLATE_ID` (DLT-approved, vars `##title##` `##severity##`) | logs `sms: not configured` |

Required: `NOTIFY_WEBHOOK_SECRET`. Optional: `NOTIFY_APP_URL` (a link that goes in the email).

## Deploy
1. Apply migration `20260927100050_alerts_notifications.sql`.
2. Deploy the function: `supabase functions deploy notify --no-verify-jwt`
3. Set the secrets: `supabase secrets set NOTIFY_WEBHOOK_SECRET=... FCM_SERVICE_ACCOUNT_JSON="$(cat sa.json)" ...`
4. Create the two Vault secrets described at the top of `webhook.sql`, then run `webhook.sql` in the SQL editor.
5. Test it: insert a critical alert, then check the function logs for `notify {"recipients":…}`.

## Firebase (Flutter push)
The app is ready for push, but Firebase is not configured yet. Until it is, `startPushRegistration` logs a message and does nothing.
1. Create a Firebase project and add an Android app with the package name `in.gov.ner.ner_logistics`.
2. Download `google-services.json` and put it in `ner_logistics/android/app/`.
3. Add the Google services Gradle plugin:
   - In `android/settings.gradle.kts` plugins, add `id("com.google.gms.google-services") version "4.4.2" apply false`.
   - In `android/app/build.gradle.kts` plugins, add `id("com.google.gms.google-services")`.
4. For iOS, add `GoogleService-Info.plist` to `ios/Runner`, turn on Push Notifications, and upload an APNs key in the Firebase console.
5. In Firebase, go to Project settings > Service accounts and generate a key. Its JSON becomes `FCM_SERVICE_ACCOUNT_JSON`.

Web push (service worker + VAPID) is not wired. The web app gets alerts live in the page through Realtime.
