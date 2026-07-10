# M1 · 01 — Environment setup

Everything an engineer needs to go from a fresh machine to "able to build the app, run the
backend locally, and deploy to GCP." Do this once per developer; the GCP bootstrap is done once
for the team.

> Version policy: where a tool moves fast, a **caret/minimum** is given (e.g. "Flutter ≥ 3.29").
> Pin the exact patch in your lockfiles (`pubspec.lock`, `requirements.txt`, `.terraform.lock.hcl`)
> at first build and treat those lockfiles as the source of truth.

---

## 0. Prerequisites overview

| Tool | Min version | Used for |
|---|---|---|
| Flutter SDK (+ Dart) | ≥ 3.29 stable | the app |
| Xcode | ≥ 16 | Local iOS **interactive debugging** only (macOS). **Not required** — iOS is built/signed in cloud CI, see §1b |
| Android Studio + SDK | latest stable | Android builds + emulator |
| Python | ≥ 3.12 | backend, jobs, scoring |
| Docker | ≥ 26 | container builds for Cloud Run / Valhalla |
| Google Cloud CLI (`gcloud`) | latest | deploy + manage GCP |
| Terraform | ≥ 1.9 | infra as code |
| Node.js | ≥ 20 LTS | (M2 web UI; install now if convenient) |
| `psql` / Postgres client | ≥ 16 | DB access |
| git | any recent | VCS |

> **iOS and Android are both first-class targets from M1 — you do not need a Mac.** A local Mac is
> required *only* for the interactive iOS debug loop (`flutter run` on a plugged-in iPhone).
> Everything else — building, signing, and shipping iOS to your iPhone via TestFlight, plus the
> whole app + backend + web stack — works from Linux/Windows by producing iOS builds in **cloud CI
> (Codemagic)**. Set this up from the start; see **§1b** below.

---

## 1. Flutter + Dart

### macOS / Linux
```bash
# Recommended: use the official install or a version manager (fvm) for reproducibility.
# Option A — fvm (Flutter Version Management), keeps the team on one version:
dart pub global activate fvm           # if you already have Dart; otherwise install fvm via brew
brew install leoafarias/fvm/fvm        # macOS
fvm install 3.29.0
fvm use 3.29.0                          # writes .fvmrc in the repo

# Option B — direct install: download the stable SDK from flutter.dev, add to PATH:
export PATH="$PATH:$HOME/development/flutter/bin"

flutter --version
flutter doctor                          # follow every red ✗ it reports
```

`flutter doctor` will flag missing Xcode, Android toolchain, CocoaPods, and licenses. Resolve all
of them before continuing.

### iOS toolchain (macOS) — **only if you have a Mac for interactive debugging**
iOS is built and shipped via cloud CI (§1b), so this is **not required**. Set it up only if you own
a Mac and want the local interactive debug loop on a plugged-in iPhone:
```bash
xcode-select --install
sudo xcodebuild -license accept
sudo gem install cocoapods              # or: brew install cocoapods
```

### Android toolchain
- Install **Android Studio**, then in *SDK Manager* install: latest **SDK Platform**, **Platform
  Tools**, **Build Tools**, and an **emulator** image.
- Accept licenses:
```bash
flutter doctor --android-licenses
```

### Confirm device targets
```bash
flutter devices        # should list a simulator/emulator and any plugged-in phone
```

> **Physical phones are mandatory for M1, and iOS is a first-class target from day one.** The five
> risk questions are about real cars, GPS multipath, cabin noise, and thermals — none of which a
> simulator reproduces. Have **at least one iPhone (11-class or newer) and one mid-range Android
> device** so both platforms are field-tested from M1. You do **not** need a Mac to build for the
> iPhone — iOS builds are produced in cloud CI and installed via TestFlight (see §1b).

---

## 1b. Building iOS without a Mac (first-class iOS from M1)

**iOS + Android are both first-class targets from M1** — this project is never Android-only. The
*only* Mac-only step is compiling and signing the iOS build; everything else (the Flutter app for
either platform, the FastAPI/Cloud Run backend, PostGIS, Valhalla, the React web UI, Terraform,
gcloud, Docker) is cross-platform. So you get iOS from day one **without owning a Mac** by
producing the iOS build in **cloud CI (Codemagic)** — a hosted Mac compiles/signs it — and
installing it on your iPhone via **TestFlight**.

Set this up **in M1, not later.** Because Android vs iOS is the *same* `app/` project compiled for a
different target, wiring CI early means every feature you write is validated on both platforms as
you go, instead of accumulating iOS surprises.

> **The one honest limitation of not having a Mac:** you can *build, sign, distribute, and
> field-test* iOS from day one via CI + TestFlight, but you cannot do the tight **interactive
> debug loop** on iOS (`flutter run`/breakpoints on a plugged-in iPhone) — that specific loop needs
> a local Mac. In practice you debug logic on Android (identical Dart) and validate on the iPhone
> via TestFlight builds. If you later get a Mac, interactive iOS debugging just turns on — no rework.
> If iOS interactive debugging matters to you now, a cheap Apple-silicon Mac mini or a rented cloud
> Mac (MacStadium / AWS EC2 Mac) is the only way to get it; CI covers everything else.

### Apple prerequisites (Apple's, unavoidable for any iOS distribution)
- **Apple Developer Program** membership (annual fee) — required for TestFlight / App Store / signed builds.
- An **App Store Connect API key** (`.p8` + Key ID + Issuer ID) — lets CI sign & upload without
  hand-managing certificates.
- Your **bundle ID** registered in the Apple Developer portal, matching `app/ios/`.

### Codemagic setup (do this in M1)
Recommended: **Codemagic** (strong Flutter support, mono-repo aware, automated iOS code signing).
Free tier is 500 build-minutes/month on Apple-silicon machines (verify current limits at setup).
Sign up with GitHub → grant read access to the repo → add the App Store Connect API key under Team
Integrations (name it e.g. `fsd_asc_key`) → commit a `codemagic.yaml` at the **repo root** (not
inside `app/`; point it at the sub-folder via `working_directory: app`).

```yaml
# codemagic.yaml (repo root) — two workflows: unsigned smoke-test, then signed TestFlight.
workflows:
  ios-unsigned-smoketest:          # verifies the app COMPILES on iOS; needs NO Apple account
    name: iOS unsigned smoke test
    instance_type: mac_mini_m2
    working_directory: app         # Flutter root in the mono-repo
    environment:
      flutter: stable              # or pin to your fvm version
      xcode: latest
      cocoapods: default
    scripts:
      - flutter pub get
      - flutter build ios --debug --no-codesign   # unsigned: no cert needed
    artifacts:
      - build/ios/iphoneos/*.app

  ios-testflight:                  # signed build → TestFlight; needs Apple Dev + API key
    name: iOS TestFlight release
    instance_type: mac_mini_m2
    working_directory: app
    integrations:
      app_store_connect: fsd_asc_key
    environment:
      flutter: stable
      xcode: latest
      cocoapods: default
      vars:
        APP_STORE_APPLE_ID: 1234567890          # your app's numeric App Store Connect ID
      ios_signing:
        distribution_type: app_store
        bundle_identifier: com.yourorg.fsdbench # must match app/ios/
    scripts:
      - flutter pub get
      - name: Set build number
        script: |
          BUILD_NUMBER=$(($(app-store-connect get-latest-app-store-build-number "$APP_STORE_APPLE_ID") + 1))
          echo "BUILD_NUMBER=$BUILD_NUMBER" >> $CM_ENV
      - name: Build signed IPA
        script: flutter build ipa --release --build-number=$BUILD_NUMBER
    artifacts:
      - build/ios/ipa/*.ipa
    publishing:
      app_store_connect:
        auth: integration
        submit_to_testflight: true
```

### Sequencing
1. **Run `ios-unsigned-smoketest` first** — it needs no Apple account and confirms `app/` compiles
   on a real Mac + Xcode. Get this green **at the start of M1**, before much code exists.
   (`flutter build ipa` requires signing; the smoke-test uses `--no-codesign` to decouple "does it
   compile" from "is signing configured.")
2. **Then wire the API key + `ios-testflight`** so every meaningful M1 build lands on your iPhone
   via TestFlight for real-car field testing on iOS.
3. **Restrict the signed workflow** to a release branch or manual trigger — a signed iOS build with
   CocoaPods can burn 8–15 min; don't spend free minutes on every push. Fast logic iteration stays
   on Android (free, local); iOS is validated via TestFlight builds.

### Keep both platforms healthy as you build
- **Implement iOS paths as you write each feature**, never stub them out. Where the plans touch
  platform-specific code (permissions here; the HEVC codec channel and ML Kit in M3), write and
  **CI-build** the iOS side immediately so it's tested, not deferred.
- **Keep `app/ios/` config correct from day one** — bundle ID, `Info.plist` permission strings (mic,
  camera, location), minimum iOS version. These live under `app/ios/` and are **editable from any
  OS**; CI compiles them. Correct config now = green iOS builds throughout.

---

## 2. Backend toolchain (Python)

```bash
# Use a recent Python and an isolated venv per service.
python3 --version                       # ≥ 3.12
python3 -m venv .venv && source .venv/bin/activate
pip install --upgrade pip

# Core backend libs for M1 (pin in backend/ingest/requirements.txt):
pip install "fastapi>=0.115" "uvicorn[standard]>=0.32" \
            "pydantic>=2.9" "pydantic-settings>=2.5" \
            "sqlalchemy>=2.0" "psycopg[binary]>=3.2" "geoalchemy2>=0.15" \
            "google-cloud-storage>=2.18" "alembic>=1.13" \
            "httpx>=0.27" "shapely>=2.0" "python-multipart>=0.0.9"

# Scoring/aggregation libs (backend/jobs/requirements.txt):
pip install "numpy>=2.0" "pandas>=2.2" "scipy>=1.14"
```

`psycopg` v3 is the maintained PostgreSQL driver. `geoalchemy2` + `shapely` give you PostGIS
types from Python. (statsmodels/PyMC are **not** needed in M1 — they belong to post-V1 scoring.)

---

## 3. Docker, Terraform, gcloud

### Docker
```bash
# macOS: Docker Desktop, or colima (OSS) for a lighter daemon:
brew install colima docker && colima start
docker run --rm hello-world
```

### Terraform
```bash
brew install terraform          # or download from releases; verify checksum
terraform -version              # ≥ 1.9
```

### Google Cloud CLI
```bash
# macOS
brew install --cask google-cloud-sdk
# or the cross-platform installer from cloud.google.com/sdk/docs/install

gcloud version
gcloud components install gke-gcloud-auth-plugin beta   # 'beta' for Cloud Run Jobs convenience
gcloud auth login
gcloud auth application-default login    # gives Terraform & local code ADC credentials
```

---

## 4. GCP project bootstrap (one-time, team-wide)

### 4.1 Create the project and link billing
```bash
export ORG_ID=<your-org-or-omit>
export BILLING=<your-billing-account-id>
export PROJECT=fsd-benchmark-dev          # use -prod later for production

gcloud projects create "$PROJECT" ${ORG_ID:+--organization=$ORG_ID}
gcloud billing projects link "$PROJECT" --billing-account "$BILLING"
gcloud config set project "$PROJECT"
```

### 4.2 Enable the APIs M1 needs
```bash
gcloud services enable \
  run.googleapis.com \
  sqladmin.googleapis.com \
  storage.googleapis.com \
  artifactregistry.googleapis.com \
  cloudscheduler.googleapis.com \
  cloudbuild.googleapis.com \
  secretmanager.googleapis.com \
  iam.googleapis.com \
  compute.googleapis.com            # for the Valhalla GCE option / VPC
# Firebase Auth (used for app sign-in): enable Identity Platform / Firebase in the console.
```

### 4.3 Region choice
Use a single region close to SF for low latency and to keep data in one place, e.g.
`us-west1` (Oregon) or `us-central1`. Set it once:
```bash
gcloud config set run/region us-west1
export REGION=us-west1
```

### 4.4 Terraform state bucket (manual, before Terraform manages everything else)
```bash
gsutil mb -l $REGION -b on gs://${PROJECT}-tfstate
gsutil versioning set on gs://${PROJECT}-tfstate
```
Point the Terraform backend at it in `infra/envs/dev/backend.tf`:
```hcl
terraform {
  backend "gcs" {
    bucket = "fsd-benchmark-dev-tfstate"
    prefix = "m1"
  }
}
```

### 4.5 Artifact Registry (container images)
```bash
gcloud artifacts repositories create fsd \
  --repository-format=docker --location=$REGION \
  --description="FSD benchmark images"
gcloud auth configure-docker ${REGION}-docker.pkg.dev
```

The remaining GCP resources (Cloud SQL, GCS data buckets, Cloud Run services, the scheduler job)
are created by Terraform in [`03-backend-gcp.md`](./03-backend-gcp.md) — not by hand.

---

## 5. Firebase Auth (app sign-in)

The founding team is tiny, but having real identity from the start makes per-logger calibration
(M2's emotion z-scoring) trivial later, and lets the ingest API attribute uploads.

1. In the Firebase console, **add Firebase to the same GCP project**.
2. Enable **Email/Password** (and optionally Google) sign-in.
3. Download `google-services.json` (Android) and `GoogleService-Info.plist` (iOS) into the app
   when you wire it up in [`02-flutter-app.md`](./02-flutter-app.md).

The backend verifies Firebase ID tokens with the Firebase Admin SDK (added in `03`).

---

## 6. Repo + local config

```bash
git clone <your-repo> fsd-benchmark && cd fsd-benchmark
# Layout per the top-level README. Create the M1 skeleton:
mkdir -p app backend/ingest backend/jobs backend/scoring backend/mapmatch infra db docs
```

Create `.env.example` files (never commit real secrets — use Secret Manager in cloud):
```
# backend/ingest/.env.example
DATABASE_URL=postgresql+psycopg://app:app@localhost:5432/fsd
GCS_BUCKET=fsd-benchmark-dev-artifacts
VALHALLA_URL=http://localhost:8002
FIREBASE_PROJECT_ID=fsd-benchmark-dev
```

---

## 7. Local Postgres + PostGIS (for offline dev)

You can develop against a local Postgres before Cloud SQL exists:
```bash
docker run -d --name fsd-pg -p 5432:5432 \
  -e POSTGRES_USER=app -e POSTGRES_PASSWORD=app -e POSTGRES_DB=fsd \
  postgis/postgis:16-3.4          # OSS PostGIS image
psql postgresql://app:app@localhost:5432/fsd -c "CREATE EXTENSION IF NOT EXISTS postgis;"
```

The same schema runs on Cloud SQL (which supports the PostGIS extension).

---

## 8. Acceptance checks for this file

You are done with environment setup when:
- [ ] `flutter doctor` is green for your local target(s); `flutter devices` shows a real Android
      phone (and an iPhone if you have a Mac). On a Mac-less Linux/Windows box, Xcode/CocoaPods
      showing unavailable locally is expected — iOS is built in CI (§1b).
- [ ] **iOS is live from M1:** a `codemagic.yaml` exists at the repo root and the **unsigned iOS
      smoke-test** builds `app/` green on a hosted Mac; the signed TestFlight workflow puts a build
      on a real iPhone for field testing — all with **no local Mac required**.
- [ ] `python -c "import fastapi, sqlalchemy, geoalchemy2"` succeeds in the venv.
- [ ] `docker run hello-world`, `terraform -version`, `gcloud version` all work.
- [ ] `gcloud config get-value project` returns your project; billing is linked.
- [ ] The tfstate bucket and Artifact Registry repo exist.
- [ ] A local PostGIS container accepts `CREATE EXTENSION postgis`.

Next: [`02-flutter-app.md`](./02-flutter-app.md).
