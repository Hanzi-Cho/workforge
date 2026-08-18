# 공통 함수. bin/ 스크립트가 config.sh 다음에 source 한다.
# shellcheck shell=bash

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "!! $*"; exit 1; }

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

  if ! timeout "$to" claude -p \
        --model "$model" \
        --allowedTools "${READ_TOOLS[@]}" "${extra[@]}" \
        "${READONLY_DENY[@]}" \
        "${mcp_args[@]}" \
        --output-format json \
        < "$prompt" > "$env_json"
  then
    local code=$?
    # 진단용으로 남긴다. 지워버리면 왜 실패했는지 알 수 없다.
    local keep="$STATE_DIR/.failed.$(basename "$prompt").json"
    mv -f "$env_json" "$keep" 2>/dev/null || true
    log "claude 실행 실패 (exit=$code, timeout=${to}s, prompt=$(basename "$prompt"))"
    log "  진단: $keep"
    python3 - "$keep" 2>/dev/null <<'PY' || true
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit()
for k in ("is_error", "terminal_reason", "subtype", "num_turns",
          "api_error_status", "stop_reason"):
    if d.get(k) is not None:
        print(f"    {k}: {d[k]}", file=sys.stderr)
print(f"    result: {str(d.get('result'))[:400]}", file=sys.stderr)
PY
    return "${code:-1}"
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
