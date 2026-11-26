import json
import subprocess
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch
from xml.etree import ElementTree as ET

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
