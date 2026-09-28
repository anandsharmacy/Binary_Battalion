# NER Logistics Platform

Hazard-aware logistics planning, monitoring and routing for the **North Eastern Region of India**. Built for **MDoNER SIH26002** (Smart India Hackathon 2026).

Live web dashboards: <https://binary-battalion.vercel.app>

Roads through the North East, especially the Siliguri ("Chicken's Neck") corridor, are repeatedly cut by monsoon landslides and floods. This platform gives field officers, district officers, the control room and logistics riders one shared, real-time picture of incidents, shipments, routes and rider positions, and adds a machine-learning model that scores each road segment for rainfall-triggered disruption risk.

```text
 Web dashboards (React)  ⇄  Supabase  ⇄  Flutter app (field officer + rider)
                         Postgres + PostGIS · Auth · Realtime · Edge Functions
                                  ⇅
                    ML pipeline: per-segment risk scores
```

All three clients use the same accounts, roles and tables. Row Level Security in Postgres is the security boundary, not the UI.

## What is in this repository

| Path | Component | Details |
|---|---|---|
| [`NER-Website/`](NER-Website) | Web dashboards | React 19, Vite, Tailwind CSS 4, Leaflet. Field officer, district officer and control-room views. Deployed to Vercel. [README](NER-Website/README.md) |
| [`ner_logistics/`](ner_logistics) | Flutter mobile app | Field officer and logistics rider app: live GPS tracking, incident reporting with an offline outbox, offline turn-by-turn navigation. [README](ner_logistics/README.md) |
| [`sih-ml/`](sih-ml) | ML model and pipeline | Corridor-disruption prediction with LightGBM, spatial-block cross-validation, calibration and serving bundle. [README](sih-ml/README.md) |
| [`supabase/`](supabase) | Backend | 20 SQL migrations (schema, RLS, RPCs, PostGIS), and Edge Functions: `chat` (assistant), `ml-publish`, `notify` |
| [`docs/`](docs) | Documentation | Requirements (SRS), ML integration plan, Apple HIG UI audits, system architecture diagram |
| `docker-compose.yml` | Local stack | PostGIS, GeoServer, OSRM, ML inference and the web dashboard |

The `src/`, `index.html` and `package.json` at the repository root are an older copy of the website that is not deployed. The deployed app is `NER-Website/`.

## Components

### Web dashboards

Roles: **field officer** (report incidents, tasks, alerts), **district officer** and **control room** (incidents, routes, logistics, shipments, alerts, account approvals, analytics, AI insights; the control room also has a command-center map across all districts).

Shared native dialog with focus handling, toasts with Undo, live data over Supabase Realtime, Leaflet maps with live rider positions, shipment assignment to riders, and a translucent "glass" material for floating panels with opaque fallbacks for reduced-transparency and high-contrast settings. Setup, environment variables and scripts are in the [web README](NER-Website/README.md).

### Flutter app

- **Field officer:** a step-by-step incident report saved on the device first and sent automatically when online (durable outbox, retries with backoff), task list, alerts.
- **Logistics rider:** live location sharing with a throttled, queued-when-offline GPS feed, an active trip screen, and a live-riders map.
- **Offline navigation:** routing computed on the phone (pure-Dart A\* over a compact OpenStreetMap road graph, in an isolate), an MBTiles offline basemap, live position, next-turn banner, automatic re-routing, spoken directions. It ships with a **Guwahati–Shillong sample pack**; tools to build the full-region pack are in [`ner_logistics/tool/`](ner_logistics/tool).
- **Accessibility and design:** VoiceOver/TalkBack labels, 44 pt targets, text scaling, Reduce Motion and increased-contrast handling, audited against Apple's Human Interface Guidelines (see [`docs/`](docs)).

```bash
cd ner_logistics
cp env.example.json env.json          # then fill in your Supabase URL and publishable key
flutter pub get
flutter run --dart-define-from-file=env.json
flutter analyze && flutter test
```

Only the *publishable* Supabase key ever ships in the app.

### ML model

Per-road-segment, per-day prediction of rainfall-triggered landslide and flood road disruption for the Siliguri corridor. Labels come from landslide and disaster event catalogues (COOLR/GLC, ReliefWeb) plus verified corridor events; features come from segment statics, hydrology and CHIRPS daily rainfall. Evaluation uses spatial-block, out-of-time and leave-one-event-cluster-out splits with a locked final test set.

- Trained models and calibrators: [`sih-ml/models/`](sih-ml/models) (`registry.json` records the versions).
- Serving bundle used by the inference container: [`sih-ml/deploy/bundles/`](sih-ml/deploy/bundles).
- Method and results: [`FINAL_MODEL.md`](sih-ml/FINAL_MODEL.md), [`REMEDIATION.md`](sih-ml/REMEDIATION.md), [`FORMULAS_AND_ALGORITHMS.md`](sih-ml/FORMULAS_AND_ALGORITHMS.md), [`ML_ARCHITECTURE.md`](sih-ml/ML_ARCHITECTURE.md), [`DEPLOYMENT.md`](sih-ml/DEPLOYMENT.md).

Version notes, so the numbers are not mixed up: `registry.json` names `final_v6` as champion and `final_v2` as release champion, and the inference bundle currently points at `final_v3`. `final_v1` is documented as leaked and superseded (see `REMEDIATION.md`).

**Read the scores with care.** `p_calibrated` is calibrated on a case-control training panel (about 10 sampled negatives per positive), so its absolute level overstates the true daily probability on the full corridor, and calibration did not transfer cleanly to a new region in testing. Use `risk_percentile` to rank segments. The dashboards currently show a **replay** of historical scores (5 Aug 2025), not a live forecast.

```bash
cd sih-ml
pip install -r requirements.txt
python -m pytest tests/ -q     # some tests need the data snapshots, which are not in this repo
```

### Supabase backend

[`supabase/migrations/`](supabase/migrations) build the whole schema: users and roles, districts and PostGIS geometry, incidents, tasks, alerts, shipments and rider assignment, rider tracking, ML score tables, and RLS policies scoped by role and district. Edge Functions live in [`supabase/functions/`](supabase/functions). To run it locally: `supabase start && supabase db reset`.

New accounts are real Supabase Auth accounts. Riders are active immediately; other roles wait for approval by a district officer or the control room, and the first control-room account is activated by hand.

## What is intentionally not in this repository

This repository is public, so anything secret, generated or very large is left out:

- **Secrets and signing keys** — Android release keystore, `key.properties`, `.env`, `env.json`, service-role keys. Templates: `.env.example`, `ner_logistics/env.example.json`.
- **Build output** — Flutter `build/` (several GB), `node_modules`, virtual environments.
- **Large data** — OSRM road data (about 800 MB), the ML raw data tree, feature store and score archives (over 1 GB), training runs and experiment logs. The pipeline documents how each is produced.
- **Internal working notes** — agent progress logs and planning drafts.

Because of that, `docker compose up` needs the OSRM data and ML feature store prepared first; see [`ner_logistics/backend/`](ner_logistics/backend) and [`sih-ml/DEPLOYMENT.md`](sih-ml/DEPLOYMENT.md).

## Documentation

- [`docs/SRS.md`](docs/SRS.md) — software requirements specification
- [`docs/ML_INTEGRATION_PLAN.md`](docs/ML_INTEGRATION_PLAN.md) — connecting risk scores to the clients
- [`docs/UI_AUDIT_APPLE_HIG.md`](docs/UI_AUDIT_APPLE_HIG.md) and [`docs/UI_AUDIT_APPLE_HIG_V2.md`](docs/UI_AUDIT_APPLE_HIG_V2.md) — design audit and re-audit
- [`docs/architecture/`](docs/architecture) — system architecture diagram (open `index.html`)

## License

[MIT](LICENSE) © 2026 Anand Sharma
