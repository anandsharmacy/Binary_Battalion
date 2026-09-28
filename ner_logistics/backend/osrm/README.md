# OSRM: self-hosted routing for North-East India

The web planner (`web/NER-Website/src/lib/routing.ts`) and the Flutter app
(`lib/services/routing/`) call OSRM's `/route` API. Until this is deployed, both
fall back to the public demo server `router.project-osrm.org`. That server
allows about 1 request/s and does not permit production use.

The graph is built from the Geofabrik **north-eastern-zone** extract (about
105 MB `.osm.pbf`), which covers Assam, Arunachal, Manipur, Meghalaya, Mizoram,
Nagaland, Tripura and Sikkim. Siliguri and the rest of West Bengal are **not**
included. Car profile, MLD algorithm.

## VM sizing

For this extract:

| | |
|---|---|
| Build (extract, partition, customize) | up to about 4 GB RAM, a few minutes (estimate, not re-measured) |
| Serve (`osrm-routed`) | 530 MB RSS (measured) |
| Disk | 800 MB total: pbf plus graph (measured) |

**2 vCPU / 4 GB RAM / 30–50 GB disk, in an Indian region, is enough.** The same VM
can also run GeoServer and the daily ML job (DELIVERY_GAP_PLAN.md §3.7).
Examples: DigitalOcean BLR1 4 GB, AWS Lightsail/EC2 `ap-south-1` (t3.medium),
GCP `asia-south1` e2-medium.

## Deploy (Ubuntu 24.04, Docker installed)

```bash
# 1. Code and graph
git clone <repo> ner && cd ner/ner_logistics/backend/osrm
./prepare.sh                      # downloads the extract and builds data/north-eastern-zone-latest.osrm*
docker compose up -d              # osrm-routed on :5000

# 2. Smoke test (Guwahati → Shillong, expect "code":"Ok", about 99 km)
curl -s "http://localhost:5000/route/v1/driving/91.7362,26.1445;91.8933,25.5788?overview=false" | head -c 300

# 3. HTTPS: Caddy in front, with only 80/443 open to the internet
sudo apt install -y caddy
echo 'osrm.<your-domain> {
  reverse_proxy localhost:5000
}' | sudo tee /etc/caddy/Caddyfile
sudo systemctl reload caddy
sudo ufw allow 22,80,443/tcp && sudo ufw enable   # 5000 stays private

# 4. Weekly refresh (Sunday 03:00 IST), rebuilding from the latest extract
( crontab -l 2>/dev/null; echo '30 21 * * 6 cd $HOME/ner/ner_logistics/backend/osrm && REFRESH=1 ./prepare.sh && docker compose restart osrm' ) | crontab -
```

`osrm-routed` already sends `Access-Control-Allow-Origin: *`, so browsers can
call it directly.

## Point the apps at it

- **Web (Vercel):** set `VITE_OSRM_URL=https://osrm.<your-domain>` in the
  project env and redeploy.
- **Flutter:** add `"OSRM_URL": "https://osrm.<your-domain>"` to `env.json`
  (`flutter run --dart-define-from-file=env.json`), or pass
  `--dart-define=OSRM_URL=...`. See `lib/services/geo_config.dart`.

## Seeded corridors (`public.routes`)

`seed_routes.py` generates `supabase/migrations/20260927100020_routing_seed_routes.sql`
and `web/NER-Website/src/data/corridors.generated.ts`:

- **District points.** Each district's OSM `admin_centre` (its HQ town) from
  Overpass goes into `locations.geom`, only where that is still null.
- **Corridors.** 11 NH corridors, routed by OSRM between those district points,
  with via points that pin each route to its highway. The script aborts if any
  point snaps more than 2 km from a road, for example a point outside the
  extract.

```bash
docker compose up -d
OSRM_URL=http://localhost:5000 python3 seed_routes.py
# macOS python.org builds may need: SSL_CERT_FILE=/etc/ssl/cert.pem
```

Re-run it after changing the corridor list or refreshing the extract, then add
the regenerated SQL as a **new** migration. Never edit an applied one.

`./check_web_routing.sh` exercises the web routing module (polyline decoding,
pick rules, and a hazard detour on NH-6) against a running OSRM.
