# infra — Terraform for all GCP resources (Person C)

## The problem it solves

M1 runs on a handful of GCP services — a Postgres database, object storage, a container service, a
batch job, a scheduler. If those are created by clicking around the Cloud console, nobody can
reproduce the environment, review a change, or tear it down cleanly, and "what's actually deployed"
drifts from what's in the repo. This module makes **every cloud resource code**: one `terraform apply`
stands up (or updates) the whole stack, and `terraform plan` shows exactly what will change before it
does. No click-ops.

## What it provisions

The minimum M1 set from [docs/M1/03-backend-gcp.md](../docs/M1/03-backend-gcp.md) §7, defined once in
the shared [`modules/stack`](./modules/stack/main.tf) module and instantiated per environment:

| Resource | Terraform | Why |
|---|---|---|
| **Cloud SQL (Postgres 16 + PostGIS)** | `google_sql_database_instance.pg` + db + user | Relational + geo store for A's schema. |
| **GCS `${project}-artifacts`** | `google_storage_bucket.artifacts` | Audio/sensor blobs; 90-day lifecycle → NEARLINE. |
| **GCS `${project}-osm`** | `google_storage_bucket.osm` | SF OSM extract + Valhalla tiles. |
| **GCS `${project}-uploads`** | `google_storage_bucket.uploads` | Phone-uploaded event blobs via signed PUT URLs; short lifecycle. |
| **Ingest service account** | `google_service_account.ingest` (+ IAM) | Runtime identity; objectAdmin on uploads; self-`tokenCreator` for keyless V4 signing. |
| **Cloud Run service `fsd-ingest`** | `google_cloud_run_v2_service.ingest` | Hosts the FastAPI ingest container (runs as the ingest SA). |
| **Cloud Run job `fsd-aggregate`** | `google_cloud_run_v2_job.aggregate` | Nightly `severity ÷ miles` scoring (Person A's image). |
| **Cloud Scheduler** | `google_cloud_scheduler_job.nightly` | Triggers the aggregate job at 03:00. |

### Layout — one module, three environments

```
infra/
├── modules/stack/           the resources above, parameterized (source of truth)
│   ├── main.tf              resource definitions
│   ├── variables.tf         inputs incl. env knobs (deletion_protection, db_tier, HA)
│   ├── outputs.tf           uploads_bucket, ingest_url, ingest_sa_email, …
│   └── versions.tf          provider requirements
└── envs/
    ├── dev/                 disposable: no deletion protection, single-zone DB
    ├── staging/             prod-shaped but disposable; longer upload retention
    └── prod/                PROTECTED: deletion protection + regional HA + larger tier
```

Each `envs/<env>/main.tf` is a thin wrapper: a `terraform{}`/backend block, a `provider "google"`,
and a single `module "stack"` call that passes the env's project + secrets and sets the behaviour
knobs. **Every environment is a separate GCP project** (`fsd-benchmark-{dev,staging,prod}`), so
resource names don't collide and blast radius is contained. `variables.tf` +
`terraform.tfvars.example` are per-env; copy the example to `terraform.tfvars` (gitignored) or use
`TF_VAR_*`.

| Knob | dev | staging | prod |
|---|---|---|---|
| `deletion_protection` | false | false | **true** |
| `db_availability_type` | ZONAL | ZONAL | **REGIONAL** (HA) |
| `db_tier` | 1 vCPU / 3.75GB | 1 vCPU / 3.75GB | **2 vCPU / 7.5GB** |
| uploads retention | 30d | 60d | 90d |

## Intent / design rules

- **Secrets never touch git.** `db_password` and `database_url` are `sensitive` variables sourced from
  **Secret Manager** / `TF_VAR_*`. `terraform.tfvars` is gitignored; only `*.example` is committed.
- **`.terraform.lock.hcl` is committed** — it pins provider versions so every machine and CI run
  resolves the same `hashicorp/google` provider.
- **Remote state, later.** The GCS backend block is stubbed in `main.tf`; bootstrap the tfstate bucket
  once, then uncomment it so state is shared, not local.
- **Dev is disposable.** `deletion_protection = false` on the dev DB — do **not** carry that to prod.

## Test / run steps

Terraform's own gates *are* the tests — they run in CI and locally:

```bash
cd infra/envs/dev                 # or envs/staging, envs/prod — same commands per env
terraform init -backend=false     # CI: no remote state needed just to validate
terraform validate                # CI gate — config is internally consistent  ✅ passing today
terraform fmt -check               # CI gate — formatting

# to actually plan/apply against a real project (needs gcloud auth + a GCP project):
terraform init                     # with the GCS backend enabled
terraform plan                     # shows the expected resource set — review before apply
terraform apply
```

After apply, enable PostGIS once on the new instance:

```bash
gcloud sql connect fsd-pg --user=app     # then in psql:  CREATE EXTENSION IF NOT EXISTS postgis;
```

## Ownership note

Person C owns the infra. One variable — `aggregate_image` — points at **Person A's** nightly-job
container; C only wires it into Cloud Run + Scheduler, A builds it. The ingest image
(`ingest_image`) is C's own, built from [backend/ingest/](../backend/ingest/).
