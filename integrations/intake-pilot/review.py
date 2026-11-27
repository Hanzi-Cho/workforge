"""Build offline destination drafts and a human-readable review from actual routes."""
import html
import json
import os
import sqlite3
import subprocess
import tempfile
from pathlib import Path
from xml.etree import ElementTree as ET

from case_trace import TRACE_SCRIPT, case_panels, relations
from til_delivery import deliver


LABELS = {
    "draft_issue": "신규 Jira 티켓 초안", "draft_update": "기존 Jira 티켓 보완",
    "daily_draft": "Confluence 업무일지", "needs_input": "정보 보완 요청",
    "evidence_candidate": "Hookboard 검증 근거", "private_candidate": "TIL 비공개 학습 후보",
    "review_receipt": "사람 검토 근거", "request_revision": "수정 요청",
    "duplicate": "같은 배치에서 건너뜀", "blocked": "처리 차단",
}
FIELDS = {"app_version": "앱 버전", "device_os": "기기·OS", "observed": "관찰한 증상", "expected": "기대 동작",
          "frequency": "발생 빈도", "steps": "재현 순서", "evidence_ref": "근거 참조",
          "missing": "보완할 필드", "code": "판정 코드", "channel": "접수 채널", "issue_key": "기존 티켓", "gate_id": "게이트", "artifact_id": "산출물",
          "artifact_revision": "산출물 버전", "verification_ref": "검증 근거", "human_review_ref": "사람 검토 참조",
          "decision": "검토 결정", "case_id": "업무 ID", "work": "작업", "result": "결과", "next_step": "다음 작업"}


def draft(route):
    action, payload = route["action"], route["payload"]
    if action in {"draft_issue", "draft_update"}:
        lines = [f"{label}: {payload[key]}" for key, label in FIELDS.items() if key in payload]
        paragraphs = [{"type": "paragraph", "content": [{"type": "text", "text": line}]} for line in lines]
        doc = {"type": "doc", "version": 1, "content": paragraphs}
        if action == "draft_update":
            return {"issue_key": payload["issue_key"], "comment": {"body": doc}}
        return {"fields": {"summary": payload["observed"][:255], "description": doc}}
    if action == "daily_draft":
        table = ET.Element("table")
        body = ET.SubElement(table, "tbody")
        keys = ("case_id", "work", "result", "evidence_ref", "next_step")
        header = ET.SubElement(body, "tr")
        for key in keys:
            ET.SubElement(header, "th").text = FIELDS[key]
        for entry in payload["entries"]:
            row = ET.SubElement(body, "tr")
            for key in keys:
                ET.SubElement(row, "td").text = entry[key]
        storage = ET.tostring(table, encoding="unicode")
        # Reject text that cannot be represented in XML (for example a NUL).
        ET.fromstring(storage)
        return {"title": payload["work_date"] + " 업무일지", "body": {"representation": "storage", "value": storage}}
    return payload


def prepare(routes, til_root=None, day=None):
    records = []
    for route in routes:
        row = {"case_id": route.get("case_id"), "event_id": route.get("event_id"), "revision": route.get("revision"),
               "classification": route.get("classification"), "key": route.get("key"),
               "target": route["target"], "action": route["action"], "status": "preview"}
        if "ontology" in route:
            row["ontology"] = route["ontology"]
        try:
            row["draft"] = draft(route)
            if route["action"] == "private_candidate" and til_root:
                if route.get("classification") == "synthetic":
                    row["receipt"] = deliver(route, til_root, day)
                    row["status"] = row["receipt"]["status"]
                else:
                    row["status"] = "pending_personal_review"
        except (ValueError, RuntimeError, OSError, ET.ParseError, sqlite3.Error, subprocess.TimeoutExpired) as exc:
            row.update(status="failed", error=str(exc))
        records.append(row)
    return records


def save(path, data):
    path = Path(path)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf8", dir=path.parent, delete=False) as stream:
        name = stream.name
        try:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        except BaseException:
            Path(name).unlink(missing_ok=True)
            raise
    try:
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def human_draft(record):
    """Show the text a reviewer would actually read, without rendering input markup."""
    data = record.get("draft")
    if not data:
        return ""
    esc = html.escape
    action = record["action"]
    if action in {"draft_issue", "draft_update"}:
        adf = data["fields"]["description"] if action == "draft_issue" else data["comment"]["body"]
        lines = [esc(p["content"][0]["text"]) for p in adf["content"]]
        return '<ul>' + "".join(f"<li>{line}</li>" for line in lines) + '</ul>'
    if action == "daily_draft":
        rows = []
        for row in ET.fromstring(data["body"]["value"]).findall(".//tr"):
            cells = []
            for cell in row:
                tag = "th" if cell.tag == "th" else "td"
                cells.append(f"<{tag}>{esc(cell.text or '')}</{tag}>")
            rows.append("<tr>" + "".join(cells) + "</tr>")
        return '<div class="scroll"><table>' + "".join(rows) + "</table></div>"
    if action == "private_candidate":
        return f'<p>{esc(data["fact"]["text"])}</p><p>검증 근거 · {esc(data["verification_ref"])}</p>'
    pairs = []
    for key, value in data.items():
        display = ", ".join(FIELDS.get(i, i) for i in value) if isinstance(value, list) else str(value)
        pairs.append(f"<dt>{esc(FIELDS.get(key, key))}</dt><dd>{esc(display)}</dd>")
    return '<dl>' + "".join(pairs) + '</dl>'


def render(records):
    esc = html.escape
    def fmt(value):
        return esc(json.dumps(value, ensure_ascii=False, indent=2))
    groups = []
    for target in ("jira", "confluence", "hookboard", "til", "local"):
        cards = []
        for index, record in enumerate(records):
            if record["target"] != target:
                continue
            action = record["action"]
            data = record.get("draft", {})
            if action == "draft_issue":
                title = data.get("fields", {}).get("summary", "")
            elif action == "draft_update":
                title = data.get("issue_key", "")
            elif action == "daily_draft":
                title = data.get("title", "")
            elif action == "private_candidate":
                title = data.get("fact", {}).get("text", "")
            else:
                title = str(data.get("code") or ", ".join(FIELDS.get(k, k) for k in data.get("missing", [])) or data.get("artifact_id", ""))
            status = {"preview": "로컬 미리보기", "verified": "저장·재조회 확인", "already_verified": "기존 저장 재확인",
                      "failed": "반영 실패", "pending_personal_review": "개인 기록 검토 대기"}[record["status"]]
            note = record.get("error") or record.get("receipt", {}).get("path", "")
            key = record.get("key") or record.get("event_id") or "식별 전"
            kind = {"synthetic": "합성 예제", "personal": "개인 입력"}.get(record.get("classification"), "분류 전")
            expanded = " open" if action in {"daily_draft", "private_candidate"} else ""
            cards.append(f'<details id="route-{index}"{expanded}><summary><strong>{esc(LABELS[action])}</strong> {esc(title)}'
                         f'<small>{esc(status)}</small></summary><p>{esc(kind)} · {esc(key)} {esc(note)}</p>'
                         f'{human_draft(record)}{relations(record.get("ontology"))}'
                         f'<details><summary>출력 JSON</summary><pre>{fmt(record)}</pre></details></details>')
        if cards:
            groups.append(f'<section class="destination"><h2>{esc(target.upper())}</h2>{"".join(cards)}</section>')
    return """<!doctype html><html lang="ko"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>업무 초안 검토</title><style>*{box-sizing:border-box}body{font:16px/1.6 "Malgun Gothic",sans-serif;color:#1c3430;background:#f6f8f7;max-width:980px;margin:auto;padding:30px}h1{margin:0}h2{font-size:17px;color:#25604f}
table{width:100%;border-collapse:collapse}th,td{text-align:left;border:1px solid #cbd7d2;padding:8px}th{background:#eef4f0}dt{font-weight:bold}dd{margin:0 0 6px}.scroll{overflow-x:auto}section{margin:26px 0}details{background:white;border:1px solid #cbd7d2;border-radius:8px;margin:5px 0;padding:12px}
summary{cursor:pointer}small{display:inline-block;color:#305e52;padding:0 8px}pre{white-space:pre-wrap;overflow-wrap:anywhere;font-size:13px}p,li,dd,summary,td{overflow-wrap:anywhere}
select{max-width:100%;padding:6px 10px;font:inherit}a{color:#12534a}h3{font-size:16px}.case-pane{margin-top:16px}.trace-table{background:white;font-size:15px}.trace-table th{white-space:nowrap}
details:target,a:focus-visible,select:focus-visible{outline:2px solid #23715b;outline-offset:2px}
@media(max-width:600px){body{padding:16px}.trace-table{min-width:580px}}
</style><h1>업무 초안 검토</h1><p>업무를 선택한 뒤 출력을 열면 해당 초안과 근거를 확인할 수 있습니다. Jira와 Confluence 항목은 전송 전 초안입니다.</p>""" + case_panels(records, LABELS, FIELDS) + "".join(groups) + TRACE_SCRIPT + "</html>\n"
