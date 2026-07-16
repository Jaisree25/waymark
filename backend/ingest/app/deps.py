"""Composition root — holds the app's port implementations so tests can override them.

Unit tests replace `state.storage`, `state.auth`, and `state.repo` with fakes; production wiring
lives in create_app() / main.py. Keeping this separate is what lets units avoid the network.
"""

from __future__ import annotations

from dataclasses import dataclass

from .ports import AuthPort, ExportsPort, StoragePort
from .repository import Repository


@dataclass
class AppState:
    storage: StoragePort
    auth: AuthPort
    repo: Repository
    # A's export queries, behind a port. Optional: the ingest endpoints don't need it, so tests that
    # only exercise writes construct AppState without it. The inspect/export routes 503 when unset.
    exports: ExportsPort | None = None
