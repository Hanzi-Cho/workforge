#!/usr/bin/env bash
# Jira → state/issues.json 병합. 신규/변경 이슈 키를 stdout 에 뿌린다.
#
#   scan-issues.sh            델타 스캔 (마지막 성공 이후 updated 된 것만)
#   scan-issues.sh --full     전수 스캔 (담당 이슈 전부, 유실 대조용)
#
# 설계상 중요한 것 둘:
#
#  1) 변경 판별은 AI 가 아니라 `updated` 타임스탬프 비교로 한다. 결정론적이고 공짜다.
#
#  2) 스캔은 **프로젝트별 별도 세션**으로 돈다.
#     실측: 59건을 한 세션에서 12페이지 긁게 하면 에이전트가 빈 출력을 내고 죽었다.
#     그 전에는 2페이지(10건)에서 멈추고 truncated=false 로 "전부 가져왔다"고
#     거짓 보고했다. 프로젝트당 3페이지 안쪽이면 안정적이다.
#     그리고 count 조회로 기대값을 먼저 구해 수집량을 대조한다 —
#     AI 의 기계적 작업을 코드가 검증하는 것이 이 스크립트의 핵심이다.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/config.sh" ]] || { echo "config.sh 가 없다. \`cp config.example.sh config.sh\` 후 값을 채워라." >&2; exit 1; }
source "$HERE/config.sh"; source "$LIB_DIR/common.sh"

MODE="delta"; [[ "${1:-}" == "--full" ]] && MODE="full"

DELTA_CLAUSE=""
if [[ "$MODE" == "delta" ]]; then
  SINCE="$(python3 -c '
import json,sys,datetime
try:
    print(json.load(open(sys.argv[1]))["last_success"][:16].replace("T"," "))
except Exception:
    print((datetime.datetime.now()-datetime.timedelta(days=14)).strftime("%Y-%m-%d %H:%M"))
' "$LAST_RUN")"
  DELTA_CLAUSE="AND updated >= \"$SINCE\""
  log "델타 스캔 — updated >= $SINCE"
else
  log "전수 스캔 — 담당 이슈 전부"
fi

COMBINED="$STATE_DIR/.scan.combined.json"
echo '[]' > "$COMBINED"
OK_PROJECTS=()
FAILED_PROJECTS=()

for P in $PROJECTS; do
  JQL="assignee = \"$ASSIGNEE_ID\" $STATUS_FILTER AND project = $P $DELTA_CLAUSE ORDER BY updated DESC"

  # ── 기대 건수 (독립 검증의 기준값) ────────────────────────────────────
  CRENDER="$STATE_DIR/.count.$P.md"
  sed -e "s|__CLOUD_ID__|$CLOUD_ID|g" -e "s|__JQL__|$JQL|g" \
      "$PROMPT_DIR/count.md" > "$CRENDER"
  if ! run_ai "$TIMEOUT_CLASSIFY" "$MODEL_SCAN" "$CRENDER" "${JIRA_TOOLS[@]}" \
        > "$STATE_DIR/.count.$P.raw"; then
    log "[$P] count 실패 — 이 프로젝트를 건너뛴다"
    FAILED_PROJECTS+=("$P"); continue
  fi
  EXPECTED="$(json_from_ai "$STATE_DIR/.count.$P.raw" \
    | python3 -c 'import json,sys; print(int(json.load(sys.stdin)["total"]))')"

  if (( EXPECTED == 0 )); then
    log "[$P] 대상 0건 — 건너뜀"
    OK_PROJECTS+=("$P"); continue
  fi
  EXPECTED_PAGES=$(( (EXPECTED + 4) / 5 ))
  MAX_PAGES=$(( EXPECTED_PAGES + 3 ))
  log "[$P] 기대 ${EXPECTED}건 (약 ${EXPECTED_PAGES}페이지)"

  # ── 수집 ──────────────────────────────────────────────────────────────
  RENDER="$STATE_DIR/.scan.$P.md"
  sed -e "s|__CLOUD_ID__|$CLOUD_ID|g" \
      -e "s|__JQL__|$JQL|g" \
      -e "s|__MAX_PAGES__|$MAX_PAGES|g" \
      -e "s|__EXPECTED_TOTAL__|$EXPECTED|g" \
      -e "s|__EXPECTED_PAGES__|$EXPECTED_PAGES|g" \
      "$PROMPT_DIR/scan.md" > "$RENDER"

  if ! run_ai "$TIMEOUT_SCAN" "$MODEL_SCAN" "$RENDER" "${JIRA_TOOLS[@]}" \
        > "$STATE_DIR/.scan.$P.raw"; then
    log "[$P] 수집 실패 — 이 프로젝트를 건너뛴다"
    FAILED_PROJECTS+=("$P"); continue
  fi
  json_from_ai "$STATE_DIR/.scan.$P.raw" > "$STATE_DIR/.scan.$P.json" || {
    log "[$P] JSON 파싱 실패 — 건너뜀"; FAILED_PROJECTS+=("$P"); continue; }

  # ── 검증: AI 의 수집량을 코드가 대조 ──────────────────────────────────
  if ! python3 - "$STATE_DIR/.scan.$P.json" "$EXPECTED" "$P" "$COMBINED" <<'PY'
import json, sys
scan_p, exp, proj, comb_p = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
scan = json.load(open(scan_p))
items = scan.get("issues", [])
keys = [i.get("key") for i in items]
if len(set(keys)) != len(keys):
    sys.exit(f"[{proj}] 중복 키: {len(keys)}건 중 고유 {len(set(keys))}건")
if len(items) < exp:
    sys.exit(f"[{proj}] 수집 누락 {len(items)}/{exp}건 "
             f"(에이전트 보고: truncated={scan.get('truncated')}, "
             f"pages={scan.get('pages_fetched')})")
bad = [k for k in keys if not str(k).startswith(proj + "-")]
if bad:
    sys.exit(f"[{proj}] 다른 프로젝트 키가 섞였다: {bad[:5]}")
comb = json.load(open(comb_p))
comb.extend(items)
json.dump(comb, open(comb_p, "w"), ensure_ascii=False)
print(f"[{proj}] 검증 통과 {len(items)}/{exp}건", file=sys.stderr)
PY
  then
    log "[$P] 검증 실패 — 이 프로젝트를 건너뛴다"
    FAILED_PROJECTS+=("$P"); continue
  fi
  OK_PROJECTS+=("$P")
done

if [[ ${#OK_PROJECTS[@]} -eq 0 ]]; then
  die "모든 프로젝트 스캔이 실패했다. 정본을 건드리지 않는다."
fi
[[ ${#FAILED_PROJECTS[@]} -gt 0 ]] && \
  log "!! 실패한 프로젝트: ${FAILED_PROJECTS[*]} — 이번 회차에서 제외한다"

# ── 병합 ────────────────────────────────────────────────────────────────
# 분류 결과(kind/feature)와 문서 상태는 보존한다. 매일 다시 판단하면
# 분류가 흔들리고(어제 network-status, 오늘 net-ui) 비용도 두 번 낸다.
python3 - "$COMBINED" "$ISSUES_JSON" "$MODE" "${OK_PROJECTS[*]}" <<'PY'
import json, os, sys, datetime
comb_p, store_p, mode, ok_projects = sys.argv[1:5]
scanned = set(ok_projects.split())
items = json.load(open(comb_p))
store = {}
if os.path.exists(store_p):
    store = {i["key"]: i for i in json.load(open(store_p))["issues"]}

now = datetime.datetime.now().isoformat(timespec="seconds")
new_keys, changed_keys = [], []
# 분류 결과·문서 상태·누적 이력은 스캔이 덮어쓰지 않는다.
KEEP = ("first_seen", "kind", "feature", "feature_title",
        "doc", "classified_at", "filled_at", "recommendation", "confidence",
        "status_history", "changelog")
today = now[:10]

for it in items:
    k = it.get("key")
    if not k:
        continue
    prev = store.get(k)
    if prev is None:
        it.update(first_seen=now, last_synced=now, kind=None, feature=None,
                  feature_title=None, doc=None, classified_at=None, filled_at=None,
                  status_history=[{"at": today, "from": None, "to": it.get("status")}],
                  changelog=[{"at": today, "event": "Jira 에서 신규 수집"}])
        store[k] = it
        new_keys.append(k)
    else:
        keep = {f: prev.get(f) for f in KEEP}
        keep["status_history"] = keep.get("status_history") or []
        keep["changelog"] = keep.get("changelog") or []
        changed = prev.get("updated") != it.get("updated")

        # 상태 전이는 여기서만 기록한다. 리포트의 "검토 → 종결" 표기가 이걸 읽는다.
        if prev.get("status") != it.get("status"):
            keep["status_history"] += [{"at": today, "from": prev.get("status"),
                                        "to": it.get("status")}]
            keep["changelog"] += [{"at": today,
                "event": f"상태 전이: {prev.get('status')} → {it.get('status')}"}]

        # 제목이 바뀌면 feature 판단 근거가 무너지므로 재분류 대상으로 되돌린다.
        if prev.get("summary") != it.get("summary"):
            keep["classified_at"] = None
            keep["changelog"] += [{"at": today, "event": "제목 변경 — 재분류 대상"}]

        # 본문이 새로 채워졌으면 다시 분석할 가치가 있다. 이게 이 도구의 최대 병목이다.
        po = (prev.get("description") or "").strip()
        no_ = (it.get("description") or "").strip()
        if po != no_:
            if not po and no_:
                keep["filled_at"] = None
                keep["changelog"] += [{"at": today, "event": "Jira 본문이 채워짐 — 재분석 대상"}]
            else:
                keep["changelog"] += [{"at": today, "event": "Jira 본문 변경"}]

        merged = dict(it); merged.update(keep); merged["last_synced"] = now
        merged.pop("gone_since", None)
        store[k] = merged
        if changed:
            changed_keys.append(k)

# 이탈 판정은 **전수 스캔이 성공한 프로젝트에 한해서만** 한다.
# 델타 스캔은 전체를 보지 않았으므로 이 판단을 할 자격이 없고,
# 실패한 프로젝트도 마찬가지다. 이걸 안 지키면 멀쩡한 이슈가 표에서 사라진다.
gone = []
if mode == "full":
    seen = {i["key"] for i in items}
    for k, v in store.items():
        if v.get("project") in scanned and k not in seen and not v.get("gone_since"):
            v["gone_since"] = now
            gone.append(k)

out = {"generated_at": now, "last_scan_mode": mode,
       "scanned_projects": sorted(scanned),
       "issues": sorted(store.values(),
                        key=lambda i: i.get("updated") or "", reverse=True)}
json.dump(out, open(store_p, "w"), ensure_ascii=False, indent=1)

print(f"수집 {len(items)}건 → 정본 {len(store)}건 "
      f"(신규 {len(new_keys)}, 변경 {len(changed_keys)}, 이탈 {len(gone)})",
      file=sys.stderr)
for k in dict.fromkeys(new_keys + changed_keys):
    print(k)
PY
