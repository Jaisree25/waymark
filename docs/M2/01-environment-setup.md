# M2 · 01 — Environment setup (deltas from M1)

M2 keeps everything from `milestone-1/01-environment-setup.md` and adds the **web UI toolchain**,
a **weather/conditions data source**, and a few backend libraries. Do M1 setup first; this file
only lists what's new.

---

## 1. Web UI toolchain (Node + React + Vite + MapLibre)

```bash
node --version          # ≥ 20 LTS  (install from nodejs.org or nvm)
corepack enable         # gives you pnpm/yarn without global installs

# scaffold the viewer
cd web
npm create vite@latest . -- --template react-ts
npm install
# map + charts + data fetching (all OSS)
npm install maplibre-gl @tanstack/react-query
npm install uplot                 # tiny OSS charts for sparklines / risk profile
npm install -D tailwindcss postcss autoprefixer && npx tailwindcss init -p
```

`maplibre-gl` is the OSS map renderer (a fork of Mapbox GL JS, BSD-3); it draws the colored road
**line layers** and district **fill layers** the design calls for. `uplot` is a ~40 KB OSS charting
lib that handles the sparkline trend and the route "elevation-style" risk profile without pulling
in a heavy framework.

### Basemap tiles (open source, no proprietary key)
Choose one:
- **OpenFreeMap** — free, OSS-hosted vector tiles; point MapLibre's `style` at its public style URL.
- **Protomaps PMTiles** — download an SF `.pmtiles` extract once, host it on the
  `${PROJECT}-artifacts` (or a dedicated `${PROJECT}-tiles`) GCS bucket, and load it with the
  `pmtiles` MapLibre protocol. Fully self-hosted, fully OSS.

```bash
# Protomaps option:
npm install pmtiles
# build/download an SF extract (protomaps tooling or a prebuilt regional pmtiles), upload:
gsutil cp sf.pmtiles gs://${PROJECT}-tiles/
```

---

## 2. Weather / conditions data source

M2 auto-attaches **weather, time-of-day, and lighting** to events *and* breadcrumb miles. Time of
day and lighting (civil twilight / sunrise-sunset) are **computed locally** from timestamp + lat/lon
(no API): use the OSS Python `astral` library.

```bash
# backend conditions enrichment libs
pip install "astral>=3.2"          # sun position / civil twilight → lighting bucket, fully offline
pip install "httpx>=0.27"          # weather API client (already in M1)
```

For **weather**, you need a **historical/timestamped** lookup (events are enriched after the fact):
- **Open-Meteo** — free, open data, has a historical weather API and generous limits; no key for
  non-commercial use. Good default and keeps the "open wherever possible" rule.
- If you outgrow it, any commercial historical-weather API drops in behind the same
  `WeatherClient` interface.

Set the chosen base URL via config/secret:
```
WEATHER_API_BASE=https://archive-api.open-meteo.com/v1/archive
```

> Cost/coverage control (design's named M2 engineering risk): **cache + batch** lookups. Round
> each event to a coarse space-time cell (e.g. 0.1° × hour) and cache the result so a corridor of
> events on the same afternoon makes one weather call, not fifty. Store the cell key on the event
> so re-runs are free.

---

## 3. Extra backend libraries

```bash
# scoring + rollups (numpy/pandas/scipy already from M1; add nothing heavy — no ML in M2)
pip install "geopandas>=1.0" "pyproj>=3.6"      # district spatial joins / length-weighting helpers
```

(`statsmodels`, `PyMC`, etc. are intentionally **absent** — they belong to post-V1.)

---

## 4. New GCP enablement

```bash
# Firebase Hosting for the web UI (or use a GCS bucket + Cloud CDN instead)
npm install -g firebase-tools
firebase login
firebase init hosting            # in web/ ; sets public dir to dist/

# (optional) a dedicated tiles bucket if using Protomaps
gsutil mb -l $REGION -b on gs://${PROJECT}-tiles
gsutil iam ch allUsers:objectViewer gs://${PROJECT}-tiles    # public read for tiles only
```

Add to enabled APIs if not already on: `firebasehosting.googleapis.com`. Cloud Scheduler, Cloud
Run, Cloud SQL, GCS, Artifact Registry are all already enabled from M1.

---

## 5. Multi-contributor groundwork

M2 supports more than one phone/car. No new infra — Firebase Auth from M1 already gives each
logger a uid; the backend simply stops assuming a single user. Make sure each team member has a
Firebase account in the project, and confirm the ingest API records `user_id` on every trip
(it does, from M1's schema).

---

## 5b. iOS across multiple contributors (already first-class since M1)

iOS is **not** an M2 add-on — it's a first-class target from M1, built and signed in cloud CI
(Codemagic) with no local Mac. The full recipe (workflows, App Store Connect key, TestFlight,
`codemagic.yaml`) is in `milestone-1/01-environment-setup.md` §1b. M2 changes nothing about *how*
iOS is built; it only widens *who* runs the app, so the only iOS-related deltas here are
distribution and device coverage:

- **Onboard contributor iPhones via TestFlight.** The `ios-testflight` workflow from M1 already
  publishes builds; add external contributors as TestFlight testers (or use a public TestFlight
  link) so iPhone users can install and collect data. No pipeline change — just tester management in
  App Store Connect.
- **Keep both stores' builds in lockstep.** When M2 adds rich capture / provider modes, cut an
  Android build **and** an iOS TestFlight build from the same commit so multi-contributor data comes
  from identical app versions on both platforms (the "identical instrument" fairness the comparison
  depends on).
- **Watch CI minutes as builds get more frequent.** With more contributors you'll ship more often;
  keep the signed iOS workflow on a release-branch/manual trigger (M1 §1b) so you stay within the
  free tier, and lean on local Android builds for day-to-day iteration.

---

## 6. Acceptance checks for this file
- [ ] `npm run dev` in `web/` serves a blank Vite+React app with a MapLibre map centered on SF.
- [ ] The basemap renders from an OSS source (OpenFreeMap or self-hosted PMTiles) with no proprietary key.
- [ ] `python -c "import astral, geopandas, httpx"` works in the backend venv.
- [ ] A test weather lookup for an SF lat/lon + past timestamp returns data and is cached.
- [ ] Firebase Hosting (or GCS+CDN) is initialized for `web/dist`.
- [ ] iOS (live since M1 via CI) is distributed to contributor iPhones through **TestFlight**, and
      Android + iOS builds are cut from the **same commit** so all contributors run identical app
      versions (see §5b).

Next: [`02-flutter-app.md`](./02-flutter-app.md).
