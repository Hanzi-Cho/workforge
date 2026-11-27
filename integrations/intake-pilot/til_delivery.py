"""Deliver synthetic TIL candidates through the destination's private importer."""
import hashlib
import json
import re
import sqlite3
import subprocess
import sys
import tempfile
from contextlib import closing
from datetime import date
from pathlib import Path


def identifier(value):
    return isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", value) is not None


def deliver(route, root, day):
    if route.get("classification") != "synthetic" or (
        route.get("schema"), route.get("target"), route.get("action")
    ) != ("work.route.v1", "til", "private_candidate"):
        raise ValueError("Expected a synthetic private TIL candidate")
    event = route.get("event_id")
    rev = route.get("revision")
    if not identifier(event) or not identifier(route.get("case_id")) or type(rev) is not int or not 1 <= rev <= 2147483647:
        raise ValueError("Invalid event, case or revision")
    key = f"{event}/{rev}/til/private_candidate"
    if route.get("key") != key:
        raise ValueError("Destination key does not match the event")
    if not isinstance(day, str) or date.fromisoformat(day).isoformat() != day:
        raise ValueError("Expected a calendar date in YYYY-MM-DD form")
    payload = route.get("payload")
    if not isinstance(payload, dict) or not identifier(payload.get("verification_ref")):
        raise ValueError("Missing verification reference")
    fact = payload.get("fact")
    if not isinstance(fact, dict) or set(fact) != {"id", "kind", "text"} or not identifier(fact["id"]) or fact["kind"] != "learning":
        raise ValueError("Invalid learning evidence")
    if not isinstance(fact["text"], str) or not fact["text"].strip() or len(fact["text"]) > 1000:
        raise ValueError("Invalid learning text")

    root = Path(root).resolve()
    importer = root / "scripts/daily_pipeline.py"
    if not importer.is_file():
        raise ValueError("TIL checkout needs scripts/daily_pipeline.py with import-agent-draft")
    state = root / ".til-state"
    state.mkdir(exist_ok=True, mode=0o700)
    # Bind the event to its first destination day before the importer can write.
    # The ontology describes the routing decision and can evolve independently
    # of a delivery. Keep the pre-ontology receipt identity on replay.
    delivery_fields = {key: value for key, value in route.items() if key != "ontology"}
    fingerprint = hashlib.sha256(json.dumps(delivery_fields, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    with closing(sqlite3.connect(state / "workforge-receipts.sqlite", timeout=40)) as db:
        db.execute("""CREATE TABLE IF NOT EXISTS receipts
                      (key TEXT PRIMARY KEY, digest TEXT NOT NULL, day TEXT NOT NULL,
                       case_id TEXT NOT NULL, verification_ref TEXT NOT NULL, verified INTEGER NOT NULL)""")
        with db:
            db.execute("INSERT OR IGNORE INTO receipts VALUES (?,?,?,?,?,0)",
                       (key, fingerprint, day, route["case_id"], payload["verification_ref"]))
        # The importer has its own file lock. Serialize our check, call and readback;
        # a crash releases this transaction and the previously reserved key survives.
        with db:
            db.execute("BEGIN IMMEDIATE")
            prior_digest, bound_day, verified = db.execute(
                "SELECT digest, day, verified FROM receipts WHERE key=?", (key,)
            ).fetchone()
            if prior_digest != fingerprint:
                raise ValueError("Existing event revision has different content")
            target = state / bound_day / "agent-drafts" / f"{event}.{rev}.json"
            candidate = {"event_id": event, "revision": rev, "classification": "synthetic",
                         "status": "draft", "facts": [fact], "questions": []}
            existed = target.exists()
            if not existed:
                bundle = {"schema": "workforge.drafts.v1", "status": "draft", "classification": "synthetic",
                          "event_id": event, "revision": rev, "drafts": {"til": [fact], "questions": []}}
                with tempfile.NamedTemporaryFile(mode="w", encoding="utf8") as temp:
                    json.dump(bundle, temp)
                    temp.flush()
                    run = subprocess.run([sys.executable, str(importer), "import-agent-draft",
                                          "--date", bound_day, "--file", temp.name],
                                         cwd=root, capture_output=True, timeout=30)
                if run.returncode:
                    raise RuntimeError("Private importer failed; retry the same event after checking the TIL pipeline")
            try:
                saved = json.loads(target.read_text(encoding="utf8"))
            except (OSError, ValueError) as error:
                raise RuntimeError("Could not read back the private candidate") from error
            if saved != candidate:
                raise ValueError("Private candidate differs; resolve the conflict before retrying")
            db.execute("UPDATE receipts SET verified=1 WHERE key=?", (key,))
    return {"key": key, "date": bound_day, "case_id": route["case_id"],
            "verification_ref": payload["verification_ref"], "path": target.relative_to(root).as_posix(),
            "status": "already_verified" if verified and existed else "verified"}
