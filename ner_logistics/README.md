# NER Logistics — Flutter mobile app

Android-first mobile version of the NER Logistics Platform (MDoNER SIH26002).
It shares **one Supabase backend** with the web dashboards in
`NER-Website/` (repository root):

```text
WEB (React/Vite)  ⇄  Supabase (Postgres + PostGIS + Auth + Realtime)  ⇄  Flutter (this app)
```

Same accounts, same roles, same tables. The mobile app adds one role that the
web does not have — **Logistics Rider** — whose live GPS position is stored in
Supabase and streamed to the Field / District / Control Room dashboards.

See [SUPABASE_INTEGRATION.md](SUPABASE_INTEGRATION.md) for the architecture,
schema changes, security model and tuning notes.

## Requirements

- Flutter 3.35+ / Dart 3.9+ (`flutter --version`)
- Android Studio + SDK (Android) or Xcode (iOS)
- Docker Desktop + Supabase CLI to run the shared backend locally

## 1. Backend

Use the hosted Supabase project, or run one locally. The schema (tables, RLS
policies, RPCs, seeded districts) is in [`../supabase/migrations`](../supabase/migrations):

```bash
cd ..                       # repository root
supabase start
supabase db reset           # applies every migration
```

There are no demo accounts. Create an account from the app's *Create account*
screen (or the website). Riders are active immediately; field, district and
control-room accounts wait for approval by a district officer or the control
room. The very first control-room account is activated by hand:

```sql
update public.user_roles set is_active = true where user_id = '<uuid>';
```

## 2. Run the app

```bash
cd ner_logistics
flutter pub get
flutter run                       # Android emulator → http://10.0.2.2:54321
                                  # iOS simulator   → http://127.0.0.1:54321
```

Defaults point at the local Supabase stack with the CLI's local publishable
key. For a physical phone, or a hosted project, pass the values explicitly:

```bash
flutter run \
  --dart-define=SUPABASE_URL=http://192.168.1.20:54321 \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
```

For the hosted project, copy `env.example.json` to `env.json` (git-ignored) and fill in the publishable key (Supabase
dashboard → Project Settings → API Keys) and run:

```bash
flutter run --dart-define-from-file=env.json
flutter build apk --dart-define-from-file=env.json
```

Only the *publishable* key ever ships in the app. Row Level Security is the
security boundary.

Other optional defines (unchanged): `OSRM_URL`, `GEOSERVER_URL` — see
`backend/README.md`.

## 3. What to try

**Rider** → *Rider Dashboard* → *Live location sharing* →
**Start sharing** (or *Start trip*). The card shows the last fix, accuracy,
speed, queued count and last sync. Turn off Wi-Fi/data: fixes queue locally and
sync automatically on reconnect. Android keeps tracking with the screen off via
a foreground-service notification.

**Any officer** → drawer → **Live Riders**. Every rider appears on the map with
a heading arrow, colour by cargo risk, grey when stale (>30 min). Tap a rider
for details, phone call and the recent trail. Positions update through Supabase
Realtime without refreshing; the chip shows *Live* / *Polling* status. Live
riders also appear on the District Map and Regional Map *Logistics* layer.

## Tests

```bash
flutter analyze
flutter test
```

New suites: `test/features/location_policy_test.dart` (throttle/heartbeat
rules), `location_queue_test.dart` (durable offline queue),
`live_rider_test.dart` (officer-side model + Realtime merge),
`auth_mapping_test.dart` (officer-ID → email, role mapping, error mapping).

## Project layout (new parts)

```text
lib/core/config/supabase_config.dart        URL/key from --dart-define with local defaults
lib/core/supabase/supabase_providers.dart   Supabase client provider
lib/core/network/connectivity_provider.dart online/offline stream
lib/features/auth/                          AuthRepository, AuthController (Riverpod), models
lib/features/rider/application/             LocationPolicy, LocationQueue, RiderTrackingController
lib/features/rider/data/rider_repository.dart   sync_rider_locations / set_rider_duty / get_my_rider_context RPCs
lib/features/rider/presentation/live_sharing_card.dart
lib/features/tracking/                      LiveRider model, repository (RPC + Realtime), controller, Live Riders screen
```
