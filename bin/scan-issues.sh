#!/usr/bin/env bash
# Jira → state/issues.json 병합. 신규/변경 이슈 키를 stdout 에 뿌린다.
#
#   scan-issues.sh            델타 스캔 (마지막 성공 이후 updated 된 것만)
#   scan-issues.sh --full     전수 스캔 (담당 이슈 전부, 유실 대조용)
#
# 설계상 중요한 것 넷:
#
#  1) 변경 판별은 AI 가 아니라 `updated` 타임스탬프 비교로 한다. 결정론적이고 공짜다.
#
#  2) 스캔은 **2단계**다. 이게 비용의 핵심이다.
#       Phase A  키+summary+status+updated 만 훑는다. 건당 4필드라 응답이 가볍다.
#       Phase B  A 를 정본과 비교해 **바뀐 것만** 본문까지 가져온다.
#     예전에는 매 실행마다 전 건의 description 을 긁었다. 응답이 툴 결과 한도를
#     넘겨 파일로 덤프되고, 에이전트가 그걸 Grep/Read 로 되짚느라 107턴을 쓰고
#     600초 타임아웃으로 죽었다(2026-08-24 DE, 13건). 같은 회차의 EST(20건)는
#     535/600초로 겨우 통과했다 — 둘 다 절벽 끝이었다.
#     안 바뀐 이슈는 이제 조회조차 하지 않는다.
#
#  3) 스캔은 **프로젝트별 별도 세션**으로 돈다.
#     실측: 59건을 한 세션에서 12페이지 긁게 하면 에이전트가 빈 출력을 내고 죽었다.
#     그 전에는 2페이지(10건)에서 멈추고 truncated=false 로 "전부 가져왔다"고
#     거짓 보고했다. 프로젝트당 3페이지 안쪽이면 안정적이다.
#     그리고 count 조회로 기대값을 먼저 구해 수집량을 대조한다 —
#     AI 의 기계적 작업을 코드가 검증하는 것이 이 스크립트의 핵심이다.
#
#  4) Phase B 는 MAX_DETAIL_PER_RUN 으로 **전체 예산**이 걸려 있다.
#     정본이 비었을 때 전 건이 "신규" 로 잡혀 예전 비용이 되살아나는 것을 막는다.
#     상한에 걸려 못 받은 이슈는 정본에 넣지 않으므로 다음 실행에서 다시 대상이 된다.
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

COMBINED="$STATE_DIR/.scan.combined.json"   # Phase B 상세 레코드 (정본 갱신용)
SEEN="$STATE_DIR/.scan.seen.json"           # Phase A 전체 키 (이탈 판정용)
RELMETA="$STATE_DIR/.scan.releases.json"    # Phase B 에서 본 Fix Version 메타
echo '[]' > "$COMBINED"
echo '{}' > "$SEEN"
echo '{}' > "$RELMETA"
OK_PROJECTS=()
FAILED_PROJECTS=()
DETAIL_BUDGET="$MAX_DETAIL_PER_RUN"
DEFERRED_TOTAL=0

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

  # ── Phase A: 키 + updated 만 훑는다 (본문 없음) ───────────────────────
  KRENDER="$STATE_DIR/.keys.$P.md"
  sed -e "s|__CLOUD_ID__|$CLOUD_ID|g" \
      -e "s|__JQL__|$JQL|g" \
      -e "s|__MAX_PAGES__|$MAX_PAGES|g" \
      -e "s|__EXPECTED_TOTAL__|$EXPECTED|g" \
      -e "s|__EXPECTED_PAGES__|$EXPECTED_PAGES|g" \
      "$PROMPT_DIR/scan-keys.md" > "$KRENDER"

  if ! run_ai "$TIMEOUT_SCAN" "$MODEL_SCAN" "$KRENDER" "${JIRA_TOOLS[@]}" \
        > "$STATE_DIR/.keys.$P.raw"; then
    log "[$P] Phase A(키 열거) 실패 — 이 프로젝트를 건너뛴다"
    FAILED_PROJECTS+=("$P"); continue
  fi
  json_from_ai "$STATE_DIR/.keys.$P.raw" > "$STATE_DIR/.keys.$P.json" || {
    log "[$P] Phase A JSON 파싱 실패 — 건너뜀"; FAILED_PROJECTS+=("$P"); continue; }

  # ── 검증 + 변경분 선별 ────────────────────────────────────────────────
  # 수집량 대조를 값싼 Phase A 에서 한다. 여기서 통과하면 목록은 완전하다.
  DEFER_OUT="$STATE_DIR/.defer.$P"
  if python3 - "$STATE_DIR/.keys.$P.json" "$EXPECTED" "$P" "$SEEN" \
        "$ISSUES_JSON" "$DETAIL_BUDGET" "$STATE_DIR/.targets.$P" > "$DEFER_OUT" <<'PY'
import json, os, sys
keys_p, exp, proj, seen_p, store_p, budget, targets_p = sys.argv[1:8]
exp, budget = int(exp), int(budget)
scan = json.load(open(keys_p))
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

store = {}
if os.path.exists(store_p):
    store = {i["key"]: i for i in json.load(open(store_p))["issues"]}

# updated 문자열이 정본과 다르면(또는 정본에 없으면) 그것만 본문을 가져온다.
targets = [i["key"] for i in items
           if store.get(i["key"], {}).get("updated") != i.get("updated")]
take, defer = targets[:budget], targets[budget:]

# Phase A 결과 전체는 이탈 판정과 last_synced 갱신에 쓴다.
seen = json.load(open(seen_p))
for i in items:
    seen[i["key"]] = {"updated": i.get("updated"), "status": i.get("status"),
                      "summary": i.get("summary"), "project": proj}
json.dump(seen, open(seen_p, "w"), ensure_ascii=False)
open(targets_p, "w").write("\n".join(take))

print(f"[{proj}] 목록 검증 통과 {len(items)}/{exp}건 · "
      f"변경 {len(targets)}건 (수집 {len(take)}, 이월 {len(defer)})", file=sys.stderr)
print(len(defer))
PY
  then
    DEFER_N="$(cat "$DEFER_OUT")"
    DEFERRED_TOTAL=$(( DEFERRED_TOTAL + DEFER_N ))
  else
    log "[$P] Phase A 검증 실패 — 이 프로젝트를 건너뛴다"
    FAILED_PROJECTS+=("$P"); continue
  fi

  mapfile -t TARGETS < <(grep -v '^$' "$STATE_DIR/.targets.$P" || true)
  if [[ ${#TARGETS[@]} -eq 0 ]]; then
    # 변경이 없는 것과 예산이 없어 못 받은 것은 전혀 다른 상황이다. 뭉개지 않는다.
    if (( DEFER_N > 0 )); then
      log "[$P] !! 상세 수집 예산 소진 — 변경 ${DEFER_N}건을 다음 실행으로 넘긴다"
    else
      log "[$P] 변경 없음 — 본문 조회 생략"
    fi
    OK_PROJECTS+=("$P"); continue
  fi

  # ── Phase B: 변경분만 본문까지 ────────────────────────────────────────
  N=${#TARGETS[@]}
  D_PAGES=$(( (N + 4) / 5 ))
  KEY_LIST="$(IFS=,; echo "${TARGETS[*]}")"
  DJQL="key in ($KEY_LIST) ORDER BY updated DESC"

  DRENDER="$STATE_DIR/.detail.$P.md"
  # 대상 키 목록이 여러 줄이라 sed 로는 못 넣는다. 렌더는 python 이 한다.
  python3 - "$PROMPT_DIR/scan-detail.md" "$CLOUD_ID" "$DJQL" \
      $(( D_PAGES + 3 )) "$N" "$D_PAGES" "$STATE_DIR/.targets.$P" > "$DRENDER" <<'PY'
import sys
tpl, cloud, jql, maxp, total, pages, targets_p = sys.argv[1:8]
keys = [k for k in open(targets_p).read().split("\n") if k.strip()]
t = open(tpl, encoding="utf-8").read()
for a, b in (("__CLOUD_ID__", cloud), ("__JQL__", jql), ("__MAX_PAGES__", maxp),
             ("__EXPECTED_TOTAL__", total), ("__EXPECTED_PAGES__", pages),
             ("__TARGET_KEYS__", "\n".join(keys))):
    t = t.replace(a, b)
sys.stdout.write(t)
PY

  log "[$P] 본문 수집 ${N}건 (약 ${D_PAGES}페이지)"
  if ! run_ai "$TIMEOUT_SCAN" "$MODEL_SCAN" "$DRENDER" "${JIRA_TOOLS[@]}" \
        > "$STATE_DIR/.detail.$P.raw"; then
    log "[$P] Phase B(본문 수집) 실패 — 이 프로젝트를 건너뛴다"
    FAILED_PROJECTS+=("$P"); continue
  fi
  json_from_ai "$STATE_DIR/.detail.$P.raw" > "$STATE_DIR/.detail.$P.json" || {
    log "[$P] Phase B JSON 파싱 실패 — 건너뜀"; FAILED_PROJECTS+=("$P"); continue; }

  if ! python3 - "$STATE_DIR/.detail.$P.json" "$STATE_DIR/.targets.$P" "$P" "$COMBINED" "$RELMETA" <<'PY'
import json, sys
det_p, targets_p, proj, comb_p, rel_p = sys.argv[1:6]
want = [k for k in open(targets_p).read().split("\n") if k.strip()]
det = json.load(open(det_p))
items = det.get("issues", [])
got = {i.get("key") for i in items}
missing = [k for k in want if k not in got]
if missing:
    sys.exit(f"[{proj}] 본문 누락 {len(missing)}건: {missing[:5]} "
             f"(truncated={det.get('truncated')}, pages={det.get('pages_fetched')})")
extra = [k for k in got if k not in set(want)]
if extra:
    sys.exit(f"[{proj}] 요청하지 않은 키가 섞였다: {extra[:5]}")
comb = json.load(open(comb_p))
comb.extend(items)
json.dump(comb, open(comb_p, "w"), ensure_ascii=False)

# Fix Version 메타(released 여부)를 모은다. 릴리스 포커스 판정의 유일한 근거다.
# AI 가 `releases` 를 안 냈으면 이슈의 fix_versions 이름만으로라도 채운다 —
# released 는 모르는 채(null) 남고, 뒤 단계는 그걸 "미릴리즈로 간주" 로 다룬다.
rel = json.load(open(rel_p))
for v in det.get("releases") or []:
    name = (v or {}).get("name")
    if not name:
        continue
    rel[f"{v.get('project') or proj}|{name}"] = {
        "project": v.get("project") or proj, "name": name,
        "released": v.get("released"), "release_date": v.get("release_date")}
for it in items:
    for name in it.get("fix_versions") or []:
        rel.setdefault(f"{proj}|{name}",
                       {"project": proj, "name": name,
                        "released": None, "release_date": None})
json.dump(rel, open(rel_p, "w"), ensure_ascii=False)
print(f"[{proj}] 본문 검증 통과 {len(items)}/{len(want)}건", file=sys.stderr)
PY
  then
    log "[$P] Phase B 검증 실패 — 이 프로젝트를 건너뛴다"
    FAILED_PROJECTS+=("$P"); continue
  fi

  DETAIL_BUDGET=$(( DETAIL_BUDGET - N ))
  (( DETAIL_BUDGET < 0 )) && DETAIL_BUDGET=0
  OK_PROJECTS+=("$P")
done

if [[ ${#OK_PROJECTS[@]} -eq 0 ]]; then
  die "모든 프로젝트 스캔이 실패했다. 정본을 건드리지 않는다."
fi
[[ ${#FAILED_PROJECTS[@]} -gt 0 ]] && \
  log "!! 실패한 프로젝트: ${FAILED_PROJECTS[*]} — 이번 회차에서 제외한다"
(( DEFERRED_TOTAL > 0 )) && \
  log "!! 상한(MAX_DETAIL_PER_RUN=$MAX_DETAIL_PER_RUN)으로 ${DEFERRED_TOTAL}건을 다음 실행으로 넘겼다"

# ── 병합 ────────────────────────────────────────────────────────────────
# 분류 결과(kind/feature/product)와 문서 상태는 보존한다. 매일 다시 판단하면
# 분류가 흔들리고(어제 network-status, 오늘 net-ui) 비용도 두 번 낸다.
python3 - "$COMBINED" "$ISSUES_JSON" "$MODE" "${OK_PROJECTS[*]}" "$SEEN" "$RELMETA" <<'PY'
import json, os, sys, datetime, difflib
comb_p, store_p, mode, ok_projects, seen_p, rel_p = sys.argv[1:7]
scanned = set(ok_projects.split())
items = json.load(open(comb_p))          # Phase B 상세 = 신규/변경분만
seen = json.load(open(seen_p))           # Phase A 전체 목록
store = {}
releases = {}
if os.path.exists(store_p):
    prev_doc = json.load(open(store_p))
    store = {i["key"]: i for i in prev_doc["issues"]}
    releases = prev_doc.get("releases") or {}

# 릴리스 메타는 **누적**한다. Phase B 는 바뀐 이슈만 보므로, 오늘 아무 이슈도
# 안 바뀐 릴리스는 이번 응답에 안 나온다. 지우면 그 릴리스가 판정에서 사라진다.
# 단 released=true 로 바뀐 것은 갱신돼야 하므로, 값이 있는 쪽이 이긴다.
for k, v in json.load(open(rel_p)).items():
    old = releases.get(k) or {}
    if v.get("released") is None and old.get("released") is not None:
        v = dict(v, released=old["released"], release_date=old.get("release_date"))
    releases[k] = v

now = datetime.datetime.now().isoformat(timespec="seconds")
new_keys, changed_keys = [], []
# 분류 결과·문서 상태·누적 이력은 스캔이 덮어쓰지 않는다.
KEEP = ("first_seen", "kind", "product", "feature", "feature_title",
        "doc", "classified_at", "filled_at", "recommendation", "confidence",
        "status_history", "changelog")
today = now[:10]

def body_diff(old: str, new: str, max_lines: int = 40) -> str:
    """본문 변경분만 뽑는다. 사람이 아침에 훑을 분량으로 자른다."""
    d = list(difflib.unified_diff(old.splitlines(), new.splitlines(),
                                  lineterm="", n=1))[2:]   # ---/+++ 헤더 제거
    if len(d) > max_lines:
        d = d[:max_lines] + [f"... (이하 {len(d) - max_lines}줄 생략)"]
    return "\n".join(d)

for it in items:
    k = it.get("key")
    if not k:
        continue
    prev = store.get(k)
    if prev is None:
        it.update(first_seen=now, last_synced=now, kind=None, product=None, feature=None,
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

        # Fix Version 배정은 이 도구의 조직 축이다. 바뀌면 리포트에 올려야 한다.
        # (릴리스에 새로 들어왔는지/빠졌는지를 사람이 아침에 바로 봐야 한다.)
        pv = list(prev.get("fix_versions") or [])
        nv = list(it.get("fix_versions") or [])
        if pv != nv:
            keep["changelog"] += [{"at": today,
                "event": f"릴리스 배정 변경: {', '.join(pv) or '(없음)'}"
                         f" → {', '.join(nv) or '(없음)'}"}]

        # 제목이 바뀌면 feature 판단 근거가 무너지므로 재분류 대상으로 되돌린다.
        if prev.get("summary") != it.get("summary"):
            keep["classified_at"] = None
            keep["changelog"] += [{"at": today, "event": "제목 변경 — 재분류 대상",
                                   "diff": body_diff(prev.get("summary") or "",
                                                     it.get("summary") or "")}]

        # 본문이 새로 채워졌으면 다시 분석할 가치가 있다. 이게 이 도구의 최대 병목이다.
        po = (prev.get("description") or "").strip()
        no_ = (it.get("description") or "").strip()
        if po != no_:
            if not po and no_:
                keep["filled_at"] = None
                keep["changelog"] += [{"at": today,
                    "event": f"Jira 본문이 채워짐 — 재분석 대상 ({len(no_.splitlines())}줄)"}]
            else:
                # diff 는 여기서 코드가 만든다. AI 를 다시 부르지 않는다(공짜).
                dt = body_diff(po, no_)
                plus = sum(1 for l in dt.splitlines() if l.startswith("+"))
                minus = sum(1 for l in dt.splitlines() if l.startswith("-"))
                keep["changelog"] += [{"at": today,
                    "event": f"Jira 본문 변경 (+{plus}/-{minus}줄)", "diff": dt}]

        merged = dict(it); merged.update(keep); merged["last_synced"] = now
        merged.pop("gone_since", None)
        store[k] = merged
        if changed:
            changed_keys.append(k)

# Phase A 에서 본 이슈는 본문을 안 받았어도 "아직 있다"는 사실은 확인된 것이다.
# 이 표시가 없으면 아래 이탈 판정이 멀쩡한 이슈를 사라진 것으로 오해한다.
fresh = set(new_keys)
for k in seen:
    if k in store and k not in fresh:
        store[k]["last_synced"] = now
        store[k].pop("gone_since", None)

# 이탈 판정은 **전수 스캔이 성공한 프로젝트에 한해서만** 한다.
# 델타 스캔은 전체를 보지 않았으므로 이 판단을 할 자격이 없고,
# 실패한 프로젝트도 마찬가지다. 이걸 안 지키면 멀쩡한 이슈가 표에서 사라진다.
# 기준은 Phase B(변경분)가 아니라 **Phase A 전체 목록**이어야 한다 —
# 안 바뀐 이슈는 Phase B 에 아예 없기 때문이다.
gone = []
if mode == "full":
    for k, v in store.items():
        if v.get("project") in scanned and k not in seen and not v.get("gone_since"):
            v["gone_since"] = now
            gone.append(k)

out = {"generated_at": now, "last_scan_mode": mode,
       "scanned_projects": sorted(scanned),
       "releases": releases,
       "issues": sorted(store.values(),
                        key=lambda i: i.get("updated") or "", reverse=True)}
json.dump(out, open(store_p, "w"), ensure_ascii=False, indent=1)

print(f"목록 {len(seen)}건 확인 · 본문 수집 {len(items)}건 → 정본 {len(store)}건 "
      f"(신규 {len(new_keys)}, 변경 {len(changed_keys)}, 이탈 {len(gone)})",
      file=sys.stderr)
for k in dict.fromkeys(new_keys + changed_keys):
    print(k)
PY
