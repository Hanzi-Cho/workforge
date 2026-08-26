#!/usr/bin/env bash
# 진입점. cron 이 월~금 06:00 에 이걸 실행한다.
#
#   nightly_scheduler.sh           오늘 요일에 맞춰 (월요일=전수, 그 외=델타)
#   nightly_scheduler.sh --full    전수 스캔 강제
#   nightly_scheduler.sh --scan-only   스캔+테이블까지만 (AI 작성 단계 생략)
#
# 흐름:  스캔 → 릴리스 포커스 → 테이블 → 분류 → 구조/문서 생성
#         → 워크트리 준비 → AI 작성 → 요약
#
# 설계 원칙:
#   - 정본은 state/issues.json. ISSUE_TABLE.md 와 projects/ 문서는 생성물이다.
#   - 변경 판별은 코드가 한다(updated 비교). AI 는 분류와 작성만 한다.
#   - AI 는 파일을 쓰지 않는다. stdout 만 내고, 파일 쓰기는 셸/파이썬이 한다.
#   - 사람이 쓴 내용은 절대 덮어쓰지 않는다.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/config.sh" ]] || { echo "config.sh 가 없다. \`cp config.example.sh config.sh\` 후 값을 채워라." >&2; exit 1; }
source "$HERE/config.sh"; source "$LIB_DIR/common.sh"

DATE="$(date +%F)"
LOG="$LOG_DIR/$DATE.log"
mkdir -p "$LOG_DIR" "$STATE_DIR" "$PROJ_DIR"
exec > >(tee -a "$LOG") 2>&1

SCAN_ARGS=(); SCAN_ONLY=""
for a in "$@"; do
  case "$a" in
    --full)      SCAN_ARGS=(--full) ;;
    --scan-only) SCAN_ONLY=1 ;;
    *) die "알 수 없는 인자: $a" ;;
  esac
done
# 인자가 없으면 요일로 결정한다. 주 1회 전수 대조로 델타가 놓친 것을 잡는다.
if [[ ${#SCAN_ARGS[@]} -eq 0 && "$(date +%u)" == "$FULL_SCAN_DOW" ]]; then
  SCAN_ARGS=(--full)
fi

# 겹쳐 돌면 Jira 호출과 요금제 한도를 두 배로 태운다.
exec 9>"$STATE_DIR/.lock"
flock -n 9 || die "다른 실행이 진행 중이다."

STAGE=""
on_err() {
  local code=$?
  log "!! 실패: stage=$STAGE exit=$code  (로그: $LOG)"
  python3 - "$LAST_RUN" "$STAGE" "$code" <<'PY'
import json, os, sys, datetime
p, stage, code = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(p)) if os.path.exists(p) else {}
d["last_failure"] = {"at": datetime.datetime.now().isoformat(timespec="seconds"),
                     "stage": stage, "exit": int(code)}
json.dump(d, open(p, "w"), ensure_ascii=False, indent=1)
PY
  exit "$code"
}
trap on_err ERR

log "═══ nightly_scheduler $DATE  mode=${SCAN_ARGS[*]:-delta} ═══"

STAGE="preflight"
preflight_jira || die "Jira MCP 세션이 죽어 있다. 재로그인 후 다시 실행할 것."

STAGE="scan"
log "1/7 스캔"
# `mapfile < <(cmd)` 는 프로세스 치환이라 cmd 의 실패가 부모로 전파되지 않는다.
# 실측: 스캔이 죽었는데도 파이프라인이 다음 단계로 계속 진행했다.
# 종료코드를 명시적으로 확인해야 한다.
TOUCHED_FILE="$STATE_DIR/.touched"
"$BIN_DIR/scan-issues.sh" "${SCAN_ARGS[@]}" > "$TOUCHED_FILE" \
  || die "스캔 실패 — 이후 단계를 진행하지 않는다. 불완전한 정본으로 문서를 만들면 안 된다."
mapfile -t TOUCHED < "$TOUCHED_FILE"
log "    신규/변경 ${#TOUCHED[@]}건${TOUCHED:+: ${TOUCHED[*]}}"

# 릴리스 판정은 스캔 직후에 한다. 뒤 단계(문서 우선순위·워크트리)와 리포트가
# 전부 이 결과를 축으로 쓰기 때문이다. AI 를 안 쓰므로 공짜다.
STAGE="release-focus"
log "2/7 릴리스 포커스"
"$BIN_DIR/release-focus.sh"

STAGE="table"
log "3/7 리포트 렌더(목록)"
# 브리핑은 마지막에 한 번만. 여기서 붙이면 fill 후 다시 렌더하며 두 번 과금된다.
# 그래도 여기서 목록은 만들어 둔다 — 이후 단계가 실패해도 읽을 리포트는 남는다.
NO_BRIEFING=1 "$BIN_DIR/render-report.sh"

if [[ -n "$SCAN_ONLY" ]]; then
  log "--scan-only — 여기서 멈춘다."
else
  STAGE="classify"
  log "4/7 분류"
  "$BIN_DIR/classify-issues.sh"

  STAGE="structure"
  log "5/7 구조/문서 골격 생성"
  "$BIN_DIR/make-feature.sh"

  # 분류(product)가 끝난 뒤여야 어느 저장소에 만들지 알 수 있다.
  # 실패해도 파이프라인을 세우지 않는다 — 워크트리가 없어도 리포트는 유효하다.
  STAGE="worktree"
  log "6/7 워크트리 준비"
  "$BIN_DIR/make-worktree.sh" || log "  !! 워크트리 준비 실패 — 리포트는 계속 만든다"

  STAGE="fill"
  log "7/7 AI 작성 (상한 $MAX_FILL_PER_RUN건, 활성 릴리스 우선)"
  "$BIN_DIR/fill-issue-doc.sh"

  # fill 이 정본에 남긴 체인지로그를 문서에 반영한다.
  # make-feature 는 AI 를 안 쓰고 멱등이라 다시 돌려도 공짜다.
  "$BIN_DIR/make-feature.sh"

  # 문서와 recommendation 이 붙은 뒤 브리핑까지 포함해 최종 렌더.
  "$BIN_DIR/render-report.sh"
fi

STAGE="summary"
python3 - "$LAST_RUN" "$ISSUES_JSON" "$STATE_DIR/cost.log" "$DATE" "$FOCUS_JSON" <<'PY'
import json, os, sys, datetime
run_p, store_p, cost_p, date, focus_p = sys.argv[1:6]
d = json.load(open(run_p)) if os.path.exists(run_p) else {}
now = datetime.datetime.now().isoformat(timespec="seconds")
d["last_success"] = now
d.pop("last_failure", None)
json.dump(d, open(run_p, "w"), ensure_ascii=False, indent=1)

s = json.load(open(store_p))
live = [i for i in s["issues"] if not i.get("gone_since")]
today_cost = 0.0
if os.path.exists(cost_p):
    for line in open(cost_p):
        parts = line.split("\t")
        if len(parts) > 2 and parts[0].startswith(date):
            try: today_cost += float(parts[2])
            except ValueError: pass

pend = [i for i in live if not i.get("filled_at")]
nodesc = [i for i in live if not (i.get("description") or "").strip()]
print(f"    이슈 {len(live)}건 / 문서 작성 완료 {len(live)-len(pend)}건 / 대기 {len(pend)}건")
print(f"    본문 없어 분석 불가: {len(nodesc)}건")

if os.path.exists(focus_p):
    f = json.load(open(focus_p))
    for r in f.get("releases") or []:
        keys = [x["key"] for x in r["issues"]]
        by = {i["key"]: i for i in live}
        wt = sum(1 for k in keys if (by.get(k) or {}).get("worktree"))
        print(f"    ◆ {r['name']} ({r['project']}) {len(keys)}건 / 워크트리 {wt}건")
    if f.get("entered_today"):
        print(f"    릴리스 신규 진입: {', '.join(f['entered_today'])}")

print(f"    오늘 누적 비용: ${today_cost:.2f}")
PY

trap - ERR
log "완료 → $REPORT_DIR/$DATE.md"
