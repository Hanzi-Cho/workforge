# 공통 함수. bin/ 스크립트가 config.sh 다음에 source 한다.
# shellcheck shell=bash

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "!! $*"; exit 1; }

# ── Windows 저장소 다루기 ───────────────────────────────────────────────
# winpath — WSL 경로를 Windows 표기로. /mnt/d/x → D:/x
winpath() {
  local p="$1"
  if [[ "$p" =~ ^/mnt/([a-zA-Z])(/.*)?$ ]]; then
    printf '%s:%s' \
      "$(tr '[:lower:]' '[:upper:]' <<<"${BASH_REMATCH[1]}")" \
      "${BASH_REMATCH[2]:-/}"
  else
    printf '%s' "$p"
  fi
}

# git_win <저장소경로> <git 인자...> — /mnt/d 저장소는 반드시 이걸로 다룬다.
#
# 실측(2026-08-26, blaster-launcher):
#   WSL git 은 워킹트리를 "187개 파일 수정" 으로 본다. 같은 시점에 git.exe 는
#   clean 으로 본다. 원인은 Windows git 의 global core.autocrlf=true —
#   체크아웃은 CRLF 로 됐는데 WSL git 은 autocrlf 가 없어 LF 블롭과 비교한다.
#   `git diff --ignore-cr-at-eol` 로 세어보면 실제 변경은 0건이다.
#
#   이 유령 변경 때문에 WSL git 으로는 머지·체크아웃이 거부된다. 억지로
#   밀어붙이면(checkout -- . / reset --hard) 187개 파일이 LF 로 덮어써져
#   Windows 쪽 빌드와 diff 가 전부 깨진다. 그래서 쓰기 작업은 git.exe 로만 한다.
#
#   워크트리도 같다. git.exe 가 만든 워크트리의 gitdir 는 `D:/...` 표기라
#   WSL 의 `git worktree list` 에 prunable 로 나온다. **정상이다.**
#   여기서 prune 을 돌리면 살아있는 워크트리의 등록이 날아간다.
git_win() {
  local repo="$1"; shift
  [[ -x "$GIT_WIN" ]] || die "Windows git 을 찾을 수 없다: $GIT_WIN (config.sh 의 GIT_WIN)"
  "$GIT_WIN" -C "$(winpath "$repo")" "$@"
}

# ── claude 호출 가드 ────────────────────────────────────────────────────
# 아래 3개는 모두 실측으로 확인한 동작이다(2026-08-14, claude 2.1.232).
#
#  1) --allowedTools 는 샌드박스가 아니다.
#     `--allowedTools Read` 만 줘도 Bash 가 그대로 실행됐다.
#     settings.json 의 기존 허용 규칙이 살아있기 때문이다.
#
#  2) --disallowedTools Write 는 우회된다.
#     Write 를 막으면 에이전트가 Bash 로 같은 파일을 만들었다.
#     → Bash 까지 막아야 진짜 읽기 전용이 된다.
#     → 그래서 이 툴킷에서 AI 는 절대 파일을 쓰지 않는다. stdout 만 낸다.
#        파일 쓰기는 전부 셸/파이썬이 한다.
#
#  3) headless(-p) 에서 MCP 도구는 기본 거부다.
#     TTY 가 없어 자동 거부되고, 에이전트는 그 사실을 숨기고 "0건"이라 보고한다.
#     이 조용한 실패가 "오늘은 이슈가 없네"로 오해되는 게 최악이므로
#     run_ai() 가 permission_denials 를 검사해 죽인다.
READONLY_DENY=(--disallowedTools Write Edit NotebookEdit Bash)
READ_TOOLS=(Read Grep Glob)
JIRA_TOOLS=(
  mcp__atlassian__searchJiraIssuesUsingJql
  mcp__atlassian__getJiraIssue
)

# MCP 를 아예 떼는 플래그. Jira 가 필요 없는 단계에서 쓰면
# 스키마 토큰이 크게 줄고, Jira 에 실수로 쓰는 경로도 사라진다.
NO_MCP=(--mcp-config '{"mcpServers":{}}' --strict-mcp-config)

# run_ai <timeout> <model> <프롬프트파일> [추가 allowedTools...]
#   프롬프트를 stdin 으로 넣고, 에이전트의 최종 텍스트만 stdout 으로 돌려준다.
#   거부/에러/타임아웃은 0 이 아닌 종료코드로 알린다.
#   비용은 stderr 에 찍고 state/cost.log 에 누적한다.
run_ai() {
  local to="$1" model="$2" prompt="$3"; shift 3
  local extra=("$@") env_json
  env_json="$(mktemp)"

  local mcp_args=()
  if [[ " ${extra[*]} " == *" mcp__"* ]]; then
    mcp_args=()                     # Jira 필요 → 기본 MCP 설정 사용
  else
    mcp_args=("${NO_MCP[@]}")       # Jira 불필요 → MCP 제거
  fi

  # 종료코드는 `if ! cmd` 안에서 잡으면 안 된다. `! cmd` 가 성공(0)으로 뒤집혀
  # then 블록의 $? 가 항상 0 이 되고, 타임아웃의 124 가 사라진다.
  # (2026-08-24: 이 버그로 DE 스캔 타임아웃이 "exit=0" 으로 찍혀 원인 추적이 막혔다.)
  local code=0
  timeout "$to" claude -p \
        --model "$model" \
        --allowedTools "${READ_TOOLS[@]}" "${extra[@]}" \
        "${READONLY_DENY[@]}" \
        "${mcp_args[@]}" \
        --output-format json \
        < "$prompt" > "$env_json" || code=$?

  if (( code != 0 )); then
    # 진단용으로 남긴다. 지워버리면 왜 실패했는지 알 수 없다.
    local keep="$STATE_DIR/.failed.$(basename "$prompt").json"
    mv -f "$env_json" "$keep" 2>/dev/null || true
    log "claude 실행 실패 (exit=$code, timeout=${to}s, prompt=$(basename "$prompt"))"
    log "  진단: $keep"
    # `--output-format json` 은 JSON 을 맨 끝에 한 번만 뱉는다. timeout 이
    # SIGTERM 으로 죽이면 파일은 0바이트가 되므로, 빈 파일 자체가 증거다.
    if [[ ! -s "$keep" ]]; then
      if (( code == 124 )); then
        log "    진단: 출력 없음 + exit=124 → ${to}s 타임아웃으로 강제 종료됐다."
        log "    → 이 단계가 예산 안에 못 끝난다. 프롬프트 작업량을 줄이거나 타임아웃을 올려라."
      else
        log "    진단: 출력이 비어있다 (exit=$code). claude 가 JSON 을 내기 전에 죽었다."
      fi
    else
      python3 - "$keep" 2>/dev/null <<'PY' || true
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception:
    print("    진단: JSON 파싱 불가 — 출력이 잘렸다", file=sys.stderr); sys.exit()
for k in ("is_error", "terminal_reason", "subtype", "num_turns",
          "api_error_status", "stop_reason"):
    if d.get(k) is not None:
        print(f"    {k}: {d[k]}", file=sys.stderr)
print(f"    result: {str(d.get('result'))[:400]}", file=sys.stderr)
PY
    fi
    return "$code"
  fi

  python3 - "$env_json" "$STATE_DIR/cost.log" "$(basename "$prompt")" <<'PY'
import json, sys, datetime
env = json.load(open(sys.argv[1]))
cost = env.get("total_cost_usd") or 0.0
with open(sys.argv[2], "a") as f:
    f.write(f"{datetime.datetime.now():%F %T}\t{sys.argv[3]}\t{cost:.4f}\t"
            f"turns={env.get('num_turns')}\n")
print(f"    비용=${cost:.4f} turns={env.get('num_turns')}", file=sys.stderr)

den = env.get("permission_denials") or []
if den:
    names = sorted({d.get("tool_name", "?") for d in den})
    sys.exit("도구가 거부됐다: " + ", ".join(names) +
             "\n→ lib/common.sh 의 allowedTools 에 추가할 것.")
if env.get("is_error"):
    sys.exit(f"세션 실패: {str(env.get('result'))[:300]!r}")
body = (env.get("result") or "").strip()
if not body:
    sys.exit("빈 응답")
sys.stdout.write(body)
PY
  local rc=$?
  rm -f "$env_json"
  return $rc
}

# json_from_ai <원문파일> — 코드펜스/잡담이 섞여도 첫 JSON 값만 뽑아 검증한다.
json_from_ai() {
  python3 - "$1" <<'PY'
import json, re, sys
t = open(sys.argv[1], encoding="utf-8").read().strip()
t = re.sub(r"^```(?:json)?|```$", "", t, flags=re.M).strip()
s = min([i for i in (t.find("{"), t.find("[")) if i >= 0], default=-1)
e = max(t.rfind("}"), t.rfind("]"))
if s < 0 or e < 0:
    sys.exit(f"JSON 을 찾지 못했다: {t[:300]!r}")
json.dump(json.loads(t[s:e+1]), sys.stdout, ensure_ascii=False, indent=1)
PY
}

# preflight — Jira MCP 세션이 살아있는지 확인.
# OAuth 세션 만료가 이 파이프라인의 가장 흔한 실패 원인이다.
preflight_jira() {
  local out
  out="$(timeout 90 claude mcp list 2>&1 || true)"
  if ! grep -q 'atlassian.*✔' <<<"$out"; then
    log "Jira MCP 가 연결되지 않았다:"
    grep -i atlassian <<<"$out" >&2 || echo "$out" >&2
    log "재로그인은 TTY 가 필요하다:"
    log "  setsid script -qec 'claude mcp login atlassian' /dev/null"
    return 1
  fi
}
