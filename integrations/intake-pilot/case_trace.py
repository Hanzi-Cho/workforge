"""Render case-level navigation from validated n8n ontology fragments."""
from collections import defaultdict
from html import escape

EVENTS = {
    "issue.received": "문의 접수", "work.completed": "작업 검증 완료",
    "review.decided": "사람의 검토 결정", "workday.closed": "하루 마감",
}
CHANNELS = {"email": "메일", "phone": "전화", "in_person": "대면", "jira": "Jira"}
TYPES = {
    "channel": "채널", "event": "입력 이벤트", "case": "업무", "evidence": "근거", "artifact": "산출물",
    "gate": "게이트", "review": "검토", "destination": "목적지", "output": "출력", "requirement": "요구사항",
    "journal_entry": "일지 행", "learning": "학습 근거", "ticket": "티켓", "outcome": "판정",
}
EDGES = {
    "received": "접수", "about_case": "해당 업무", "yields": "생성", "routed_to": "전달 대상",
    "disposition": "처리 판정", "requires": "필요 항목", "cites": "근거 참조", "supports": "뒷받침",
    "concerns_artifact": "대상 산출물", "verifies": "검증", "at_gate": "검증 단계",
    "reviewed_artifact": "검토한 산출물", "refers_to_ticket": "기존 티켓", "describes_learning": "학습 내용",
    "includes_entry": "일지에 포함", "contributes_to": "출력에 반영",
}
TARGETS = {"jira": "Jira", "confluence": "Confluence", "hookboard": "Hookboard", "til": "TIL", "local": "로컬"}
KINDS = {"synthetic": "합성", "personal": "개인", "unclassified": "분류 전"}
STATES = {"preview": "초안", "verified": "저장 확인", "already_verified": "기존 저장 확인",
          "failed": "반영 실패", "pending_personal_review": "개인 기록 검토 대기"}


def validate_graph(route):
    graph = route.get("ontology")
    if not isinstance(graph, dict) or graph.get("schema") != "work.ontology.v1":
        raise ValueError("Missing or unsupported work ontology")
    provenance = graph.get("provenance")
    if (graph.get("classification") != (route.get("classification") or "unclassified") or
            not isinstance(provenance, dict) or provenance.get("route_key") != route.get("key") or
            provenance.get("route_schema") != route.get("schema") or
            provenance.get("event_type") not in (*EVENTS, None)):
        raise ValueError("Ontology provenance differs from route")
    nodes, edges = graph.get("nodes"), graph.get("edges")
    if not isinstance(nodes, list) or not nodes or not isinstance(edges, list) or not edges:
        raise ValueError("Missing ontology nodes or edges")
    ids = set()
    for node in nodes:
        if (not isinstance(node, dict) or not all(isinstance(node.get(k), str) for k in ("id", "type", "label"))
                or node["id"] in ids):
            raise ValueError("Invalid ontology node")
        ids.add(node["id"])
    for edge in edges:
        if (not isinstance(edge, dict) or not all(isinstance(edge.get(k), str) for k in ("from", "to", "type"))
                or edge["from"] not in ids or edge["to"] not in ids):
            raise ValueError("Invalid ontology edge")


def node_text(node):
    value = node["label"]
    if node["type"] == "channel":
        value = CHANNELS.get(value, value)
    return f'{TYPES.get(node["type"], node["type"])} · {value}'


def relations(graph):
    """Keep the graph usable as labelled triples without executing any input."""
    if not graph:
        return ""
    nodes = {node["id"]: node for node in graph["nodes"]}
    lines = []
    for edge in graph["edges"]:
        left = nodes[edge["from"]]
        right = nodes[edge["to"]]
        name = EDGES.get(edge["type"], edge["type"])
        lines.append(f'<tr><td>{escape(node_text(left))}</td><td>{escape(name)}</td>'
                     f'<td>{escape(node_text(right))}</td></tr>')
    return ('<details class="ontology"><summary>업무 개념 간 관계</summary><div class="scroll"><table>'
            '<thead><tr><th>출발</th><th>관계</th><th>도착</th></tr></thead><tbody>' +
            ''.join(lines) + '</tbody></table></div></details>')


def source_refs(graph, linked_case=None):
    nodes = {node["id"]: node for node in graph.get("nodes", [])}
    if linked_case:
        entries = {edge["from"] for edge in graph["edges"] if edge["type"] == "about_case"
                   and edge["to"] == linked_case and nodes[edge["from"]]["type"] == "journal_entry"}
        relevant = {edge["to"] for edge in graph["edges"] if edge["type"] == "cites" and edge["from"] in entries}
    else:
        relevant = set(nodes)
    types = {"channel", "ticket", "artifact", "evidence", "review", "gate", "learning"}
    return [node_text(node) for key, node in nodes.items() if key in relevant and node["type"] in types]


def case_panels(records, labels, fields):
    cases = defaultdict(list)
    for index, row in enumerate(records):
        kind = row.get("classification") or "unclassified"
        own = row.get("case_id")
        graph = row.get("ontology", {})
        nodes = {item["id"]: item for item in graph.get("nodes", [])}
        case_links = [edge for edge in graph.get("edges", []) if edge["type"] == "about_case"]
        if graph:
            # A revision conflict has a claimed envelope case but no verified
            # event → case relation. Keep it out of both disputed case histories.
            own = next((nodes[link["to"]]["label"] for link in case_links
                        if nodes[link["from"]]["type"] == "event"), None)
        cases[kind, own].append((index, row, None))
        # A daily event belongs to its day case and also cites each work case
        # included in its journal. Keep each secondary case's evidence separate.
        journals = dict.fromkeys(link["to"] for link in case_links if nodes[link["from"]]["type"] == "journal_entry")
        for case_node in journals:
            linked = nodes[case_node]["label"]
            if linked != own:
                cases[kind, linked].append((index, row, case_node))
    if not cases:
        return ""
    options = []
    panels = []
    for i, ((kind, case), items) in enumerate(cases.items()):
        heading = f"{case or '업무 미확정'} · {KINDS.get(kind, kind)}"
        options.append(f'<option value="trace-{i}">{escape(heading)}</option>')
        lines = []
        for index, row, linked_case in items:
            graph = row.get("ontology", {})
            event_type = (graph.get("provenance") or {}).get("event_type")
            action = row["action"]
            entry = row.get("event_id") or "식별 전 입력"
            if row.get("revision") is not None:
                entry += f' · v{row["revision"]}'
            refs = source_refs(graph, linked_case)
            data = row.get("draft") or {}
            reason = ""
            if action == "needs_input":
                reason = ", ".join(fields.get(key, key) for key in data.get("missing", []))
            elif action in {"blocked", "duplicate"}:
                reason = data.get("code", "")
            decision = labels[action]
            target = TARGETS.get(row["target"], row["target"])
            state = STATES.get(row["status"], row["status"])
            lines.append('<tr><td><strong>' + escape(EVENTS.get(event_type, event_type or '입력')) +
                         '</strong><br>' + escape(entry) + '</td><td>' +
                         ('<br>'.join(map(escape, refs)) if refs else '—') +
                         '</td><td>' + escape(decision) + ('<br>' + escape(reason) if reason else '') +
                         f'</td><td><a href="#route-{index}">{escape(target)} · {escape(state)}</a></td></tr>')
        panels.append(f'<article id="trace-{i}" class="case-pane"><h3>{escape(heading)}</h3>'
                      '<div class="scroll"><table class="trace-table"><thead><tr><th>입력 이벤트</th><th>참조 근거</th>'
                      '<th>검증 후 분기</th><th>출력 열기</th></tr></thead><tbody>' + ''.join(lines) +
                      '</tbody></table></div></article>')
    return ('<section id="case-trace"><h2>업무별 추적</h2><label for="case-filter">업무 선택</label> '
            '<select id="case-filter">' + ''.join(options) + '</select>' + ''.join(panels) + '</section>')


TRACE_SCRIPT = """<script type="text/javascript">
const caseFilter = document.getElementById('case-filter');
if (caseFilter) {
  const showCase = () => {
    for (const panel of document.querySelectorAll('.case-pane')) panel.hidden = panel.id !== caseFilter.value;
  };
  caseFilter.addEventListener('change', showCase);
  showCase();
}
const openOutput = () => {
  if (!/^#route-[0-9]+$/.test(location.hash)) return;
  const node = document.getElementById(location.hash.slice(1));
  if (node instanceof HTMLDetailsElement) node.open = true;
};
document.addEventListener('click', event => {
  const link = event.target.closest?.('.case-pane a');
  if (link) document.getElementById(link.hash.slice(1)).open = true;
});
window.addEventListener('hashchange', openOutput);
openOutput();
</script>"""
