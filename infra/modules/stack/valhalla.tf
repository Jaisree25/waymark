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

      if [ ! -f "$DATA/.tiles-fetched" ]; then
        docker run --rm -v "$DATA":/data \
          gcr.io/google.com/cloudsdktool/google-cloud-cli:slim \
          gsutil -m cp -r "gs://${google_storage_bucket.osm.name}/*" /data/ || true
        touch "$DATA/.tiles-fetched"
      fi

      # --restart always: the box exists to serve the nightly; it must come back by itself after a
      # host maintenance event without anyone noticing at 03:00.
      docker run -d --name valhalla --restart always \
        -p 8002:8002 -v "$DATA":/custom_files \
        ${var.valhalla_image}
    EOT
  }

  # The tile cache is the whole reason this is a VM; don't let a config tweak silently rebuild it.
  lifecycle {
    ignore_changes = [metadata["startup-script"]]
  }
}
