# Valhalla — the OSM map-matching service the nightly pipeline calls (docs/M1/03-backend-gcp.md §5).
#
# GCE, not Cloud Run, per §5: "start with GCE for predictability". Valhalla wants its tile cache warm,
# and a scale-to-zero service would cold-start a multi-GB tile load on the first call of the night —
# exactly when the job is waiting on it.
#
# Everything here is gated on enable_valhalla, because a VM bills continuously whether the nightly
# runs or not. It stays off until Checkpoint 2 needs a real matcher.
#
# Reachability is the crux: the nightly job is serverless and Valhalla is a VM. The VM gets NO
# external IP and the job reaches it over Direct VPC egress. An OSS routing engine on a public IP is
# free compute for anyone who finds it, and Valhalla has no auth of its own.

locals {
  valhalla_zone = var.valhalla_zone != "" ? var.valhalla_zone : "${var.region}-a"

  # The job's VALHALLA_URL. Derived from the instance rather than hand-configured, so it can't drift
  # from the machine actually serving; falls back to the override when Valhalla isn't managed here.
  valhalla_url = var.enable_valhalla ? "http://${google_compute_instance.valhalla[0].network_interface[0].network_ip}:8002" : var.valhalla_url

  # `one(...)` rather than [0]: a splat on a count-0 resource is [] and one([]) is null, whereas
  # indexing would blow up when Valhalla is disabled.
  ghcr_mirror_repo = one(google_artifact_registry_repository.ghcr_mirror[*].repository_id)

  # The image the VM actually pulls. It MUST be a *.pkg.dev address, not ghcr.io: the VM has no
  # external IP, and Private Google Access reaches Google endpoints only. See the mirror below.
  valhalla_image = (
    var.valhalla_image != "" ? var.valhalla_image :
    local.ghcr_mirror_repo != null ?
    "${var.region}-docker.pkg.dev/${var.project}/${local.ghcr_mirror_repo}/${var.valhalla_upstream_image}" : ""
  )
}

# A pull-through cache of ghcr.io.
#
# Without this the VM cannot start: its startup script pulls the Valhalla image, but the box has no
# external IP by design and Private Google Access resolves *Google* endpoints only — ghcr.io is
# GitHub. The alternatives were worse: a Cloud NAT gateway costs ~$33/month to fetch one image, and
# an external IP would put an unauthenticated routing engine on the public internet.
#
# Artifact Registry does the fetching (it has internet access), the VM pulls from *.pkg.dev, and the
# upstream tag keeps working without anyone mirroring images by hand.
resource "google_artifact_registry_repository" "ghcr_mirror" {
  count         = var.enable_valhalla ? 1 : 0
  repository_id = "ghcr-remote"
  location      = var.region
  format        = "DOCKER"
  description   = "Pull-through cache of ghcr.io, so the no-external-IP Valhalla VM can pull its image"
  mode          = "REMOTE_REPOSITORY"

  remote_repository_config {
    description = "ghcr.io"
    docker_repository {
      custom_repository {
        uri = "https://ghcr.io"
      }
    }
  }
}

# The VM pulls from the mirror, so it needs read on Artifact Registry.
resource "google_artifact_registry_repository_iam_member" "valhalla_puller" {
  count      = var.enable_valhalla ? 1 : 0
  location   = google_artifact_registry_repository.ghcr_mirror[0].location
  repository = google_artifact_registry_repository.ghcr_mirror[0].name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.valhalla[0].email}"
}

# An explicit VPC rather than the auto-created "default" network: default is click-ops we didn't
# declare, and its firewall rules vary by project age.
resource "google_compute_network" "fsd" {
  count                   = var.enable_valhalla ? 1 : 0
  name                    = "fsd-net"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "fsd" {
  count         = var.enable_valhalla ? 1 : 0
  name          = "fsd-subnet"
  region        = var.region
  network       = google_compute_network.fsd[0].id
  ip_cidr_range = var.valhalla_subnet_cidr
  # Required for Cloud Run Direct VPC egress to allocate interfaces in this subnet.
  private_ip_google_access = true
}

# Only workloads inside the subnet may reach Valhalla — that's the nightly job's egress, nothing else.
resource "google_compute_firewall" "valhalla" {
  count     = var.enable_valhalla ? 1 : 0
  name      = "fsd-allow-valhalla-internal"
  network   = google_compute_network.fsd[0].name
  direction = "INGRESS"

  source_ranges = [var.valhalla_subnet_cidr]
  target_tags   = ["fsd-valhalla"]

  allow {
    protocol = "tcp"
    ports    = ["8002"]
  }
}

# The VM's own identity, so it can pull tiles from the osm bucket without a key on disk.
resource "google_service_account" "valhalla" {
  count        = var.enable_valhalla ? 1 : 0
  account_id   = "fsd-valhalla"
  display_name = "FSD Valhalla map-matching VM"
}

# Read-only, and only the osm bucket: the VM consumes tiles, it never writes them or touches uploads.
resource "google_storage_bucket_iam_member" "valhalla_osm_reader" {
  count  = var.enable_valhalla ? 1 : 0
  bucket = google_storage_bucket.osm.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.valhalla[0].email}"
}

resource "google_compute_instance" "valhalla" {
  count        = var.enable_valhalla ? 1 : 0
  name         = "fsd-valhalla"
  machine_type = var.valhalla_machine_type
  zone         = local.valhalla_zone
  tags         = ["fsd-valhalla"] # what the firewall rule targets

  boot_disk {
    initialize_params {
      # Container-Optimized OS: docker is present and the image is maintained by Google, so there's
      # no package management to own on a box whose only job is running one container.
      image = "projects/cos-cloud/global/images/family/cos-stable"
      size  = var.valhalla_disk_gb # the norcal extract + built tiles need real room
    }
  }

  network_interface {
    network    = google_compute_network.fsd[0].id
    subnetwork = google_compute_subnetwork.fsd[0].id
    # No access_config block => NO external IP. Reachable only from inside the VPC, by design.
  }

  service_account {
    email  = google_service_account.valhalla[0].email
    scopes = ["cloud-platform"]
  }

  metadata = {
    google-logging-enabled = "true"
    # Tiles live in the osm bucket, not baked into an image: rebuilding tiles for a new OSM extract
    # is then a bucket upload + a VM restart, not an image build and redeploy.
    #
    # gsutil isn't on COS, so the cloud-sdk container does the copy. If no prebuilt tile archive is
    # present, the Valhalla image builds tiles from the .pbf on first boot (slow — tens of minutes —
    # but self-healing, and only once because /var/valhalla persists across restarts).
    startup-script = <<-EOT
      #!/bin/bash
      set -euo pipefail
      DATA=/var/valhalla
      mkdir -p "$DATA"

      # COS ships docker-credential-gcr but doesn't wire it to Artifact Registry, so an unconfigured
      # box gets 401 pulling from *.pkg.dev. The VM's service account supplies the token.
      docker-credential-gcr configure-docker --registries=${var.region}-docker.pkg.dev

      if [ ! -f "$DATA/.tiles-fetched" ]; then
        # gcr.io is a Google endpoint, so Private Google Access reaches it without an external IP.
        docker run --rm -v "$DATA":/data \
          gcr.io/google.com/cloudsdktool/google-cloud-cli:slim \
          gsutil -m cp -r "gs://${google_storage_bucket.osm.name}/*" /data/ || true
        touch "$DATA/.tiles-fetched"
      fi

      # --restart always: the box exists to serve the nightly; it must come back by itself after a
      # host maintenance event without anyone noticing at 03:00.
      docker run -d --name valhalla --restart always \
        -p 8002:8002 -v "$DATA":/custom_files \
        ${local.valhalla_image}
    EOT
  }

  lifecycle {
    ignore_changes = [
      # The tile cache is the whole reason this is a VM; don't let a config tweak silently rebuild it.
      metadata["startup-script"],
      # Same as Cloud SQL: park.sh and the budget guard stop this VM out-of-band, and an apply would
      # otherwise read TERMINATED as drift and restart it behind your back.
      desired_status,
    ]
  }
}
