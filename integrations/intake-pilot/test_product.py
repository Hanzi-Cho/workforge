import hashlib
import json
import re
import sqlite3
import subprocess
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from pathlib import Path
from unittest.mock import patch
from xml.etree import ElementTree as ET

from case_trace import validate_graph
from replay import execution, terminals
from review import draft, prepare, render
from til_delivery import deliver


def learning(event="demo-a"):
    return {"schema": "work.route.v1", "classification": "synthetic", "case_id": "demo-case",
            "event_id": event, "revision": 1, "key": f"{event}/1/til/private_candidate",
            "target": "til", "action": "private_candidate",
            "payload": {"fact": {"id": "lesson", "kind": "learning", "text": "A synthetic lesson"},
                        "verification_ref": "checked-1"}}


class PrivateDelivery(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / "scripts").mkdir()
        (self.root / "scripts/daily_pipeline.py").touch()
        self.day = "2026-11-26"
        self.calls = []
        self.lose_ack = False
        mock = patch("til_delivery.subprocess.run", side_effect=self.import_candidate)
        mock.start()
        self.addCleanup(mock.stop)

    def import_candidate(self, args, **kwargs):
        self.assertEqual(args[2], "import-agent-draft")
        self.assertEqual(kwargs["cwd"], self.root)
        doc = json.loads(Path(args[-1]).read_text())
        self.assertEqual(doc["classification"], "synthetic")
        self.assertEqual(doc["schema"], "workforge.drafts.v1")
        self.calls.append(doc["event_id"])
        target = self.root / ".til-state" / args[4] / "agent-drafts" / (doc["event_id"] + ".1.json")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps({"event_id": doc["event_id"], "revision": 1, "classification": "synthetic",
                                     "status": "draft", "facts": doc["drafts"]["til"], "questions": []}))
        return subprocess.CompletedProcess(args, int(self.lose_ack))

    def test_retry_after_ack_loss_reuses_saved_candidate_and_original_date(self):
        self.lose_ack = True
        first = prepare([learning()], self.root, self.day)
        self.assertEqual(first[0]["status"], "failed")
        self.lose_ack = False
        receipt = deliver(learning(), self.root, "2026-11-27")
        self.assertEqual(receipt["date"], self.day)
        self.assertEqual(receipt["status"], "verified")
        self.assertEqual(deliver(learning(), self.root, self.day)["status"], "already_verified")
        self.assertEqual(self.calls, ["demo-a"])
        self.assertEqual(len(list(self.root.rglob("agent-drafts/*.json"))), 1)

    def test_partial_failure_keeps_other_routes_and_refuses_changed_revision(self):
        confirmed = deliver(learning(), self.root, self.day)
        changed = learning()
        changed["payload"]["verification_ref"] = "different-proof"
        rows = prepare([changed, learning("demo-b")], self.root, self.day)
        self.assertEqual([r["status"] for r in rows], ["failed", "verified"])
        self.assertEqual(deliver(learning(), self.root, self.day)["path"], confirmed["path"])
        self.assertEqual(self.calls, ["demo-a", "demo-b"])

    def test_pre_ontology_receipt_matches_enriched_route(self):
        route = learning()
        old_digest = hashlib.sha256(json.dumps(route, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        first = deliver(route, self.root, self.day)
        with closing(sqlite3.connect(self.root / ".til-state/workforge-receipts.sqlite")) as db:
            saved = db.execute("SELECT digest FROM receipts WHERE key = ?", (route["key"],)).fetchone()
        self.assertEqual(saved, (old_digest,))
        enriched = {**route, "ontology": {"schema": "work.ontology.v1", "nodes": [], "edges": []}}
        retried = deliver(enriched, self.root, "2026-11-27")
        self.assertEqual({**first, "status": "already_verified"}, retried)
        self.assertEqual(self.calls, ["demo-a"])
        with self.assertRaisesRegex(ValueError, "different content"):
            deliver({**enriched, "case_id": "another-case"}, self.root, self.day)

    def test_target_drift_is_reported_without_overwriting_user_edit(self):
        info = deliver(learning(), self.root, self.day)
        target = self.root / info["path"]
        target.write_text('{"edited":true}')
        with self.assertRaisesRegex(ValueError, "conflict"):
            deliver(learning(), self.root, self.day)
        self.assertEqual(target.read_text(), '{"edited":true}')
        self.assertEqual(self.calls, ["demo-a"])

    def test_two_workers_create_one_candidate(self):
        with ThreadPoolExecutor(max_workers=2) as pool:
            statuses = list(pool.map(lambda _: deliver(learning(), self.root, self.day)["status"], range(2)))
        self.assertCountEqual(statuses, ["verified", "already_verified"])
        self.assertEqual(self.calls, ["demo-a"])

    def test_personal_content_and_bad_ids_never_reach_importer(self):
        personal = {**learning(), "classification": "personal"}
        self.assertEqual(prepare([personal], self.root, self.day)[0]["status"], "pending_personal_review")
        for change in [{"event_id": "../no"}, {"revision": True}, {"key": "other-key"}]:
            with self.assertRaises(ValueError):
                deliver({**learning(), **change}, self.root, self.day)
        self.assertFalse(self.calls)
        self.assertFalse((self.root / ".til-state").exists())


class DraftFormats(unittest.TestCase):
    def test_n8n_projection_drives_case_links_without_mixing_journal_evidence(self):
        demo = json.loads(Path(__file__).with_name("case-demo.json").read_text())
        disputed = {**demo[0], "event_id": "disputed", "case_id": "unconfirmed-a"}
        demo.extend([disputed, {**disputed, "case_id": "unconfirmed-b"}])
        js = ("import {routeBatch} from './route.mjs'; import {readFileSync} from 'node:fs'; "
              "console.log(JSON.stringify(routeBatch(JSON.parse(readFileSync(0, 'utf8')))))")
        proc = subprocess.run(["node", "--input-type=module", "--eval", js], cwd=Path(__file__).parent,
                              input=json.dumps(demo), capture_output=True, check=True, text=True)
        routes = json.loads(proc.stdout)
        for route in routes:
            validate_graph(route)
        records = prepare(routes)
        self.assertEqual([r["ontology"] for r in records], [r["ontology"] for r in routes])
        page = render(records)
        articles = dict(re.findall(r'<article[^>]*><h3>([^<]*)</h3>(.*?)</article>', page, re.S))
        notes = articles["offline-notes · 합성"]
        pdf = articles["pdf-export · 합성"]
        self.assertIn("정보 보완 요청", notes)
        self.assertIn("앱 버전, 발생 빈도", notes)
        self.assertIn("TIL · 초안", notes)
        self.assertIn("day-close · v1", notes)
        self.assertIn("day-close · v1", pdf)
        self.assertIn("근거 · replay-notes-v2", notes)
        self.assertNotIn("fixture-title", notes)
        self.assertIn("근거 · fixture-title", pdf)
        self.assertNotIn("replay-notes-v2", pdf)
        self.assertIn("revision_conflict", articles["업무 미확정 · 합성"])
        self.assertNotIn("unconfirmed-a · 합성", articles)
        self.assertNotIn("unconfirmed-b · 합성", articles)
        links = {int(i) for i in re.findall(r'href="#route-(\d+)"', page)}
        self.assertEqual(links, set(range(len(routes))))
        self.assertEqual(page.count('<details id="route-'), len(routes))
        first_graph = records[0]["ontology"]
        first_graph["nodes"][0]["label"] = '<img src=x onerror="marker()">'
        self.assertNotIn("<img", render(records))
        self.assertIn("&lt;img", render(records))
        first_graph["edges"][0]["to"] = "missing-node"
        with self.assertRaisesRegex(ValueError, "Invalid ontology edge"):
            validate_graph(routes[0])

    def test_jira_update_keeps_the_existing_issue_and_uses_comment_adf(self):
        payload = {"observed": "x < y", "issue_key": "DEMO-13", "steps": "Try sample"}
        result = draft({"action": "draft_update", "payload": payload})
        self.assertEqual(result["issue_key"], "DEMO-13")
        self.assertNotIn("fields", result)
        adf = result["comment"]["body"]
        self.assertEqual((adf["type"], adf["version"]), ("doc", 1))
        self.assertIn("관찰한 증상: x < y", [p["content"][0]["text"] for p in adf["content"]])
        self.assertEqual(draft({"action": "draft_issue", "payload": payload})["fields"]["summary"], "x < y")

    def test_journal_escapes_markup_and_preserves_order(self):
        raw = "<script>alert(1)</script> &"
        row = dict(case_id="demo", work=raw, result="ok", evidence_ref="fixture", next_step="review")
        route = {"action":"daily_draft","target":"confluence","payload":{"work_date":"2026-11-26","entries":[row,row]}}
        generated = draft(route)
        tree = ET.fromstring(generated["body"]["value"])
        self.assertEqual(tree.findall(".//tr")[1].findall("td")[1].text, raw)
        self.assertEqual(len(tree.findall(".//tr")), 3)
        self.assertNotIn("<script>", render(prepare([route])))
        route["payload"]["entries"][0]["work"] = "x\x00y"
        self.assertEqual(prepare([route])[0]["status"], "failed")

    def test_failure_and_missing_terminal_never_become_success(self):
        data = {"status": "error", "data": {"resultData": {"error": "stopped"}}}
        self.assertEqual(execution("runner ready\n" + json.dumps(data, indent=2)), data)
        with self.assertRaises(ValueError):
            terminals({}, data)
        flow = json.loads(Path(__file__).with_name("n8n-workflow.json").read_text())
        routed = {"action": "draft_issue", "schema": "work.route.v1"}
        run = {"executionStatus":"success", "data":{"main":[[{"json":routed}]]}}
        with self.assertRaisesRegex(ValueError, "Terminal differs"):
            terminals(flow, {"status":"success","data":{"resultData":{"runData":{"계약 검증과 출력 생성":[run]}}}})


if __name__ == "__main__":
    unittest.main()
