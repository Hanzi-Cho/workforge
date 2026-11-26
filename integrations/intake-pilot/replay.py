#!/usr/bin/env python3
"""Replay the event router in an isolated n8n instance and prepare local drafts."""
import argparse
from datetime import date
from collections import Counter
import json
import os
import re
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile

from review import prepare, render, save

HERE = Path(__file__).resolve().parent


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return str(sock.getsockname()[1])


def run(args, env, label):
    proc = subprocess.run(args, cwd=HERE, env=env, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True, timeout=150)
    if proc.returncode:
        raise RuntimeError(f"{label} failed (exit {proc.returncode})")
    return proc.stdout


def execution(stdout):
    decoder = json.JSONDecoder()
    # Some n8n CLI versions emit runner diagnostics before or after the JSON.
    for start in re.finditer(r"^\s*(?=\{)", stdout, re.MULTILINE):
        try:
            parsed, _ = decoder.raw_decode(stdout[start.end():])
            if isinstance(parsed, dict) and "status" in parsed and "data" in parsed:
                return parsed
        except ValueError:
            continue
    raise ValueError("n8n did not return an execution record")


def terminals(workflow, result):
    if result.get("status") != "success" or result["data"]["resultData"].get("error"):
        raise ValueError("n8n execution was unsuccessful")
    traces = result["data"]["resultData"]["runData"]
    def outputs(name):
        rows = []
        for attempt in traces.get(name, []):
            if attempt.get("executionStatus") != "success":
                raise ValueError(f"Incomplete node: {name}")
            rows.extend(item["json"] for item in attempt["data"]["main"][0])
        return rows
    router = next(node for node in workflow["nodes"] if node["name"] == "계약 검증과 출력 생성")
    routed = outputs(router["name"])
    if not routed:
        raise ValueError("No router outputs recorded")
    switch = next(node for node in workflow["nodes"] if node["type"] == "n8n-nodes-base.switch")
    connections = workflow["connections"][switch["name"]]["main"]
    actions = set()
    for rule, links in zip(switch["parameters"]["rules"]["values"], connections, strict=True):
        action = rule["outputKey"]
        actions.add(action)
        if outputs(links[0]["node"]) != [r for r in routed if r["action"] == action]:
            raise ValueError(f"Terminal differs from router: {action}")
    if any(r.get("schema") != "work.route.v1" or r.get("action") not in actions for r in routed):
        raise ValueError("Unexpected output schema or unhandled branch")
    return routed


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--events", type=Path, help="Optional personal or synthetic JSON event array; defaults to bundled examples")
    p.add_argument("--out", type=Path, required=True, help="Private output directory for review.html and drafts.json")
    p.add_argument("--til-root", type=Path, help="Optional trusted local TIL checkout supporting import-agent-draft")
    p.add_argument("--date", help="Initial TIL destination date, YYYY-MM-DD")
    p.add_argument("--n8n", default="n8n", help="Installed n8n executable; Node 22+ must be on PATH")
    args = p.parse_args()
    if bool(args.til_root) != bool(args.date):
        p.error("--til-root and --date must be supplied together")
    if args.date:
        try:
            if date.fromisoformat(args.date).isoformat() != args.date:
                raise ValueError
        except ValueError:
            p.error("--date must be a calendar date in YYYY-MM-DD form")
    n8n = shutil.which(args.n8n)
    if not n8n:
        p.error("n8n executable was not found")
    # The preview has a private SQLite database and no connector credentials.
    with tempfile.TemporaryDirectory(prefix="workforge-n8n-") as folder:
        env = {k: os.environ[k] for k in ("PATH", "HOME", "LANG", "LC_ALL", "TZ") if k in os.environ}
        env.update(N8N_USER_FOLDER=folder, DB_TYPE="sqlite", N8N_RUNNERS_BROKER_PORT=free_port(),
                   N8N_DIAGNOSTICS_ENABLED="false", N8N_VERSION_NOTIFICATIONS_ENABLED="false",
                   N8N_TEMPLATES_ENABLED="false", N8N_PERSONALIZATION_ENABLED="false")
        export = Path(folder) / "workflow.json"
        build = ["node", "build.mjs", "--output", str(export)]
        if args.events:
            build.extend(["--input", str(args.events.resolve())])
        run(build, env, "Workflow build")
        workflow = json.loads(export.read_text(encoding="utf8"))
        run([n8n, "import:workflow", "--input=" + str(export)], env, "Workflow import")
        stdout = run([n8n, "execute", "--id=" + workflow["id"], "--rawOutput"], env, "Workflow execution")
        routes = terminals(workflow, execution(stdout))
    args.out.mkdir(mode=0o700, parents=True, exist_ok=True)
    records = prepare(routes, args.til_root, args.date)
    save(args.out / "drafts.json", json.dumps(records, ensure_ascii=False, indent=2) + "\n")
    save(args.out / "review.html", render(records))
    print(json.dumps({"outputs": len(records), "branches": len({r["action"] for r in records}),
                      "statuses": dict(Counter(r["status"] for r in records))}, ensure_ascii=False))
    return int(any(r["status"] == "failed" for r in records))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"Replay failed: {error}", file=sys.stderr)
        raise SystemExit(1)
