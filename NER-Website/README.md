# NER Logistics — Web dashboards

Web dashboards for the [NER Logistics Platform](../README.md): hazard-aware logistics planning and monitoring for the North Eastern Region of India, built for **MDoNER SIH26002** (Smart India Hackathon 2026).

Live: <https://binary-battalion.vercel.app>

Field officers, district officers and the control room share one operational view of incidents, tasks, alerts, routes, shipments and rider locations, on top of a Supabase backend (Postgres + PostGIS, Auth, Realtime).

## Roles and what they see

| Role | Sees |
|---|---|
| **Field officer** | Own dashboard, assigned tasks, a 6-step incident report wizard (type, location, evidence, details, review, submit), alerts, past reports |
| **District officer** | Dashboard, district map, incidents, routes, logistics, shipments, tasks, AI insights, alerts, account approvals, reports, analytics |
| **Control room** | Command center, regional map, live logistics, shipments, AI predictions, incidents, routes, alerts, account approvals, analytics |

Riders use the separate Flutter mobile app; their live locations show up on the logistics and map screens here.

Access is enforced by Supabase Row Level Security, not just by hiding screens: an incident reported by a field officer is scoped to their district and is visible to that district's officer and to the control room.

## Features

- **Incidents and tasks** — report, verify, escalate, resolve; turn an incident into a task; Undo on status changes.
- **Live data** — tables are mirrored in memory and kept fresh with Supabase Realtime.
- **Maps** — Leaflet with OpenStreetMap tiles: incident pins, corridor accessibility, live rider positions.
- **Routing** — corridor accessibility and route comparison. Set `VITE_OSRM_URL` to use your own OSRM server.
- **AI Insights** — per-segment road-disruption risk scores served from Supabase (currently a replay of historical scores, not a live forecast).
- **Shipments** — create shipments and assign them to riders.
- **Accounts** — real Supabase Auth. New officer accounts wait for approval from a district officer or the control room; the very first control-room account is activated by hand in the database.

### Interface

Built against Apple's Human Interface Guidelines as a design benchmark:

- One shared native `<dialog>` for all modals (focus trap, Esc to close).
- Toasts that say only what actually happened, with Undo.
- Visible keyboard focus, labelled icon buttons, 44 px touch targets.
- A translucent "glass" material for floating panels, with opaque fallbacks for `prefers-reduced-transparency`, `prefers-contrast` and browsers without `backdrop-filter`.

The dashboard is currently light-mode only.

## Tech stack

React 19 · Vite 8 · TypeScript 5.7 · Tailwind CSS 4 · Leaflet · `@supabase/supabase-js`

## Getting started

Requires Node.js 22 (see `../.mise.toml`) and a Supabase project.

```bash
npm ci
cp .env.example .env.local     # then fill in the values below
npm run dev
```

| Variable | Required | Purpose |
|---|---|---|
| `VITE_SUPABASE_URL` | yes | Your Supabase project URL |
| `VITE_SUPABASE_PUBLISHABLE_KEY` | yes | The project's publishable (`sb_publishable_…`) key. Never put a `service_role` / secret key in a `VITE_` variable: it would ship to every browser |
| `VITE_OSRM_URL` | no | Self-hosted OSRM routing server. Unset falls back to the public demo server `router.project-osrm.org` (demo use only, about 1 request per second) |

Both Supabase variables are needed to sign in.

### Scripts

| Command | What it does |
|---|---|
| `npm run dev` | Start the Vite dev server |
| `npm run build` | Production build to `NER-Website/dist` |
| `npm run preview` | Serve the production build locally |
| `npm run format` | Format with oxfmt |
| `npx tsc --noEmit` | Type-check |

## Project layout

```text
src/
  pages/        One file per screen; pages/fo = field officer, pages/control = control room
  components/   Shell (sidebar/header), Modal, MapViz, panels
  lib/          Supabase client, live tables (incidents, tasks, alerts), routing, rider tracking
  data/         Static geo reference data
  auth/         Login and sign-up screens
```

> The `src/`, `index.html` and `package.json` at the **repository root** are an older, undeployed copy. Make changes here in `NER-Website/`.

## Deployment

Pushes to `main` deploy to Vercel automatically (production); other branches get preview deployments. `../vercel.json` installs and builds inside `NER-Website/` and rewrites all routes to `index.html` for client-side routing. Set the two `VITE_SUPABASE_*` variables in the Vercel project settings.

## Related components

The Flutter app, ML pipeline and Supabase schema live in the same repository. See the [project overview](../README.md).

## License

[MIT](../LICENSE) © 2026 Anand Sharma
