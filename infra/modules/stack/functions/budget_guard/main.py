"""Budget guard — stops the meter when spend crosses the threshold.

Triggered by Cloud Billing budget notifications on Pub/Sub. It STOPS the two resources that bill
continuously (Cloud SQL and the Valhalla VM) rather than disabling billing on the project.

Why not disable billing, which is the usual recipe? Because it's irreversible in the way that
matters: Google stops Cloud SQL instances whose project loses billing and eventually DELETES them.
Trading a surprise invoice for the loss of real drive data is a bad trade — that data cost someone a
weekend in a car and can't be regenerated. Stopping is reversible with one command and reclaims ~95%
of the spend anyway; the rest (buckets, images, disks) is cents.

Important limitation: budget data lags real spend by hours, so this is a safety net against
*forgetting something is running*, NOT a hard cap. It cannot stop a runaway in real time.
"""

from __future__ import annotations

import base64
import json
import logging
import os

import functions_framework
import googleapiclient.discovery

PROJECT_ID = os.environ["PROJECT_ID"]
SQL_INSTANCE = os.environ.get("SQL_INSTANCE", "")
VM_NAME = os.environ.get("VM_NAME", "")
VM_ZONE = os.environ.get("VM_ZONE", "")
THRESHOLD = float(os.environ.get("SHUTOFF_THRESHOLD", "1.0"))

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("budget_guard")


def _stop_sql() -> None:
    """Park Cloud SQL: activation_policy NEVER stops the instance but keeps the data and its disk."""
    sql = googleapiclient.discovery.build("sqladmin", "v1beta4", cache_discovery=False)
    current = sql.instances().get(project=PROJECT_ID, instance=SQL_INSTANCE).execute()
    if current.get("settings", {}).get("activationPolicy") == "NEVER":
        log.info("cloud sql %s already stopped", SQL_INSTANCE)
        return
    sql.instances().patch(
        project=PROJECT_ID,
        instance=SQL_INSTANCE,
        body={"settings": {"activationPolicy": "NEVER"}},
    ).execute()
    log.warning("STOPPED cloud sql %s", SQL_INSTANCE)


def _stop_vm() -> None:
    compute = googleapiclient.discovery.build("compute", "v1", cache_discovery=False)
    current = compute.instances().get(project=PROJECT_ID, zone=VM_ZONE, instance=VM_NAME).execute()
    if current.get("status") in ("TERMINATED", "STOPPING", "SUSPENDED"):
        log.info("vm %s already stopped", VM_NAME)
        return
    compute.instances().stop(project=PROJECT_ID, zone=VM_ZONE, instance=VM_NAME).execute()
    log.warning("STOPPED vm %s", VM_NAME)


@functions_framework.cloud_event
def handle(cloud_event) -> None:
    payload = json.loads(base64.b64decode(cloud_event.data["message"]["data"]))

    cost = float(payload.get("costAmount", 0))
    budget = float(payload.get("budgetAmount", 0))
    if not budget:
        return

    ratio = cost / budget
    log.info("budget notification: %.2f of %.2f (%.0f%%)", cost, budget, ratio * 100)

    # Budgets notify on every spend update, several times a day — most are well under threshold and
    # must be a no-op, or the guard would stop the stack the moment it's turned on.
    if ratio < THRESHOLD:
        return

    log.warning("threshold %.0f%% crossed at %.2f/%.2f — stopping billable resources",
                THRESHOLD * 100, cost, budget)

    # Each resource is guarded separately: if the VM stop fails, the database must still be stopped.
    # Half a shutdown beats none when the point is to stop the meter.
    for name, stop, enabled in (
        ("cloud sql", _stop_sql, bool(SQL_INSTANCE)),
        ("valhalla vm", _stop_vm, bool(VM_NAME and VM_ZONE)),
    ):
        if not enabled:
            continue
        try:
            stop()
        except Exception:
            log.exception("failed to stop %s", name)
