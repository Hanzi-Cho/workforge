#!/usr/bin/env bash
# 진입점. cron 이 월~금 06:00 에 이걸 실행한다.
#
#   nightly_scheduler.sh           오늘 요일에 맞춰 (월요일=전수, 그 외=델타)
#   nightly_scheduler.sh --full    전수 스캔 강제
#   nightly_scheduler.sh --scan-only   스캔+테이블까지만 (AI 작성 단계 생략)
#
# 흐름:  스캔 → 테이블 → 분류 → 구조/문서 생성 → AI 작성 → 요약
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
log "1/5 스캔"
# `mapfile < <(cmd)` 는 프로세스 치환이라 cmd 의 실패가 부모로 전파되지 않는다.
# 실측: 스캔이 죽었는데도 파이프라인이 다음 단계로 계속 진행했다.
# 종료코드를 명시적으로 확인해야 한다.
TOUCHED_FILE="$STATE_DIR/.touched"
"$BIN_DIR/scan-issues.sh" "${SCAN_ARGS[@]}" > "$TOUCHED_FILE" \
  || die "스캔 실패 — 이후 단계를 진행하지 않는다. 불완전한 정본으로 문서를 만들면 안 된다."
mapfile -t TOUCHED < "$TOUCHED_FILE"
log "    신규/변경 ${#TOUCHED[@]}건${TOUCHED:+: ${TOUCHED[*]}}"

STAGE="table"
log "2/5 테이블 렌더"
"$BIN_DIR/render-table.sh"

if [[ -n "$SCAN_ONLY" ]]; then
  log "--scan-only — 여기서 멈춘다."
else
  STAGE="classify"
  log "3/5 분류"
  "$BIN_DIR/classify-issues.sh"

  STAGE="structure"
  log "4/5 구조/문서 골격 생성"
  "$BIN_DIR/make-feature.sh"

  STAGE="fill"
  log "5/5 AI 작성 (상한 $MAX_FILL_PER_RUN건)"
  "$BIN_DIR/fill-issue-doc.sh"

  # 문서가 생기고 recommendation 이 붙었으니 테이블을 다시 렌더한다.
  "$BIN_DIR/render-table.sh"
fi

STAGE="summary"
python3 - "$LAST_RUN" "$ISSUES_JSON" "$STATE_DIR/cost.log" "$DATE" <<'PY'
import json, os, sys, datetime
run_p, store_p, cost_p, date = sys.argv[1:5]
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
print(f"    오늘 누적 비용: ${today_cost:.2f}")
PY

trap - ERR
log "완료 → $TABLE_MD"
