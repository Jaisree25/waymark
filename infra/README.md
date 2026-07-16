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
| **Cloud Run job `fsd-aggregate`** | `google_cloud_run_v2_job.aggregate` | Nightly pipeline: attribute → exposure → score (Person A's image). |
| **Cloud Scheduler** | `google_cloud_scheduler_job.nightly` | Triggers the nightly job at 03:00. |
| **Valhalla VM + VPC** | [`valhalla.tf`](./modules/stack/valhalla.tf) | OSM map-matching for the nightly. GCE (warm tile cache), **no external IP**; the job reaches it over Direct VPC egress. |

### Two things are off by default

Both cost money continuously and neither is needed until Checkpoint 2, so they're gated:

| Flag | Default | Turn on when |
|---|---|---|
| `enable_valhalla` | `false` | You need real map-matching. Creates a VM that bills whether the nightly runs or not. |
| `enable_aggregate` | `false` | A's job image is published **and** a matcher exists. |

They're coupled: the nightly map-matches before it scores, so `enable_aggregate` without a matcher is
a misconfiguration that would run at 03:00, gate every road, and look like a data problem. A
`precondition` on the job rejects it at **plan** time instead.

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

## Cost control

Two resources are ~95% of any bill: **Cloud SQL** and the **Valhalla VM**. Both bill 24/7 whether
you drive or not; everything else (Cloud Run, GCS, Artifact Registry, Scheduler) is cents at M1
volume. So cost control is really just "are those two running?"

### Park them between drives — [`park.sh`](./park.sh)

The single biggest lever. Data and the built tile cache survive; you pay only for disks:

```bash
./park.sh status      # what's running right now
./park.sh park        # ~$90/mo -> ~$7/mo
./park.sh unpark      # ...and back, waiting until the DB really accepts connections
```

It finds the instances from `terraform output` rather than hardcoding names, is idempotent, and
skips Valhalla when `enable_valhalla` is false.

Two things to know:

- **While parked the API answers `/healthz` but writes fail** (no database). B's uploader retries
  with backoff so queued data isn't lost — but don't park mid-drive.
- **Unpark before you set off, not as you get in the car.** Cloud SQL takes ~1–2 minutes to accept
  connections; `unpark` waits for it.

> `terraform apply` won't fight this. `activation_policy` and `desired_status` are both
> optional-but-not-computed, so an apply would otherwise read a stopped resource as drift and
> restart it — you'd believe you were parked and keep paying. Both sit under `ignore_changes`, which
> makes park.sh the owner of "is it running".

### The budget guard (set `billing_account` to enable)

A Cloud Billing budget → Pub/Sub → a function that **stops those same two resources** when spend
crosses `budget_shutoff_threshold`. Set `billing_account`; leave it empty and none of it is created.

```hcl
billing_account   = "0X0X0X-0X0X0X-0X0X0X"
budget_amount_usd = 50     # alerts at 50% / 90%, stops at 100%
```

**It stops resources; it does not disable billing.** That's deliberate: Google stops Cloud SQL
instances whose project loses billing and eventually *deletes* them. Real drive data costs a weekend
in a car and can't be regenerated — a surprise invoice is the cheaper mistake.

> **If the guard fires, your stack is stopped, not broken.** Raise `budget_amount_usd` (or fix
> whatever was burning money), then run the unpark commands above. Nothing is lost.

**Know its limit:** billing data lags real spend by hours, so this is a safety net for *"I forgot dev
was running for three weeks"* — **not** a real-time cap. It cannot stop a runaway as it happens.

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
