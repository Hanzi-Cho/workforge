#!/usr/bin/env bash
# 이슈 문서의 AI 블록(코멘트 / 수정 계획)을 채운다. 가장 비싼 단계다.
#
#   fill-issue-doc.sh                미작성 문서를 MAX_FILL_PER_RUN 개까지
#   fill-issue-doc.sh PROJ-123        지정 이슈만
#   FORCE=1 fill-issue-doc.sh PROJ-123   이미 채워진 것도 다시
#
# AI 는 stdout 으로만 출력하고, 파일 쓰기는 이 스크립트가 한다.
# AI:BEGIN~AI:END 블록만 교체하므로 사람이 문서에 쓴 검토 메모는 보존된다.
# 이미 채워진 문서는 FORCE 없이는 건드리지 않는다 — 사람 수정을 덮으면 안 된다.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/config.sh" ]] || { echo "config.sh 가 없다. \`cp config.example.sh config.sh\` 후 값을 채워라." >&2; exit 1; }
source "$HERE/config.sh"; source "$LIB_DIR/common.sh"

[[ -f "$ISSUES_JSON" ]] || die "정본이 없다: $ISSUES_JSON"

LIMIT="$MAX_FILL_PER_RUN"; [[ $# -gt 0 ]] && LIMIT=$#
mapfile -t KEYS < <(FORCE="${FORCE:-}" python3 - "$ISSUES_JSON" "$LIMIT" "$@" <<'PY'
import json, os, sys
store = json.load(open(sys.argv[1]))["issues"]
limit = int(sys.argv[2]); want = set(sys.argv[3:])
force = bool(os.environ.get("FORCE"))
out = []
for i in store:
    if i.get("gone_since") or not i.get("doc"):
        continue
    if want:
        if i["key"] in want:
            out.append(i["key"])
        continue
    if i.get("filled_at") and not force:
        continue
    out.append(i["key"])
for k in out[:limit]:
    print(k)
PY
)

if [[ ${#KEYS[@]} -eq 0 ]]; then
  log "채울 문서가 없다."
  exit 0
fi
log "문서 작성 ${#KEYS[@]}건 (model=$MODEL_FILL, 상한 $MAX_FILL_PER_RUN)"

for KEY in "${KEYS[@]}"; do
  # 이 이슈의 프로젝트에 저장소 매핑이 있으면 코드 읽기를 허용한다.
  PROJECT="$(python3 -c '
import json,sys
print(next(i["project"] for i in json.load(open(sys.argv[1]))["issues"]
          if i["key"]==sys.argv[2]))' "$ISSUES_JSON" "$KEY")"
  # 매핑은 공백으로 구분된 여러 경로일 수 있다. 존재하는 것만 연다.
  ADD_DIR=(); REPOS=()
  for r in ${REPO_MAP[$PROJECT]:-}; do
    if [[ -d "$r" ]]; then
      ADD_DIR+=(--add-dir "$r"); REPOS+=("$r")
    else
      log "    !! 매핑된 저장소가 없다: $r (건너뜀)"
    fi
  done
  REPO="${REPOS[*]:-}"

  log "  → $KEY${REPO:+  (repo ${#REPOS[@]}개)}"

  RENDER="$STATE_DIR/.fill.$KEY.md"
  python3 - "$PROMPT_DIR/fill-issue.md" "$ISSUES_JSON" "$KEY" "$REPO" > "$RENDER" <<'PY'
import json, sys
tpl, store_p, key, repo = sys.argv[1:5]
issue = next(i for i in json.load(open(store_p))["issues"] if i["key"] == key)
slim = {k: issue.get(k) for k in
        ("key", "summary", "description", "kind", "issuetype", "status",
         "priority", "project", "components", "labels", "parent", "updated")}
if repo:
    paths = repo.split()
    lst = "\n".join(f"- `{p}`" for p in paths)
    sec = ("## 코드\n\n아래 저장소를 읽을 수 있다(읽기 전용):\n\n" + lst + "\n\n"
           "이슈가 어느 저장소 것인지는 **정해져 있지 않다.** 제목만 보고 단정하지 말고,\n"
           "관련 심볼/문자열을 여러 저장소에서 실제로 검색해 확인하라.\n"
           "(흔한 함정: 프론트엔드 화면 버그로 등록된 이슈의 원인이 백엔드 서비스에\n"
           " 있는 경우. 한 저장소만 보면 '관련 코드 없음'이라는 오답이 나온다.)\n\n"
           "- 인용은 **어느 저장소인지 함께** `저장소/경로:줄번호` 로 쓴다.\n"
           "- 실제로 열어 확인한 것만 인용한다. 추측한 경로는 쓰지 마라.\n"
           "- 어느 저장소에도 관련 코드가 없으면 그렇다고 쓰고,\n"
           "  이슈가 잘못 배정된 것일 수 있음을 「확인 필요」에 적어라.")
else:
    sec = ("## 코드\n\n저장소 접근이 없다. Jira 본문만으로 판단하라.\n"
           "따라서 구체적인 파일 경로를 추측해 쓰지 마라. "
           "계획은 '무엇을 해야 하는지' 수준으로 쓰고, "
           "코드 확인이 필요한 지점은 「코드 확인 필요」로 표시하라.")
t = open(tpl, encoding="utf-8").read()
t = t.replace("__ISSUE_JSON__", json.dumps(slim, ensure_ascii=False, indent=1))
t = t.replace("__REPO_SECTION__", sec)
sys.stdout.write(t)
PY

  OUT="$STATE_DIR/.fill.$KEY.out.md"
  if ! run_ai "$TIMEOUT_FILL" "$MODEL_FILL" "$RENDER" "${ADD_DIR[@]}" > "$OUT"; then
    log "    실패 — 건너뜀 (다음 실행에서 재시도한다)"
    continue
  fi

  # AI 블록만 교체한다. 사람이 쓴 「사람 검토」 절은 손대지 않는다.
  python3 - "$ISSUES_JSON" "$KEY" "$OUT" "$JIRA_DIR" <<'PY'
import json, re, sys, datetime, os
store_p, key, out_p, root = sys.argv[1:5]
d = json.load(open(store_p))
issue = next(i for i in d["issues"] if i["key"] == key)
doc = os.path.join(root, issue["doc"])
body = open(out_p, encoding="utf-8").read().strip()
body = re.sub(r"^```(?:markdown)?\s*|\s*```$", "", body).strip()

if "## 수정 계획" not in body:
    sys.exit(f"{key}: 출력에 '## 수정 계획' 절이 없다 — 반영하지 않는다")

txt = open(doc, encoding="utf-8").read()
block = ("<!-- AI:BEGIN 아래는 AI 가 채운다. 사람이 검토 후 고쳐도 된다"
         "(다음 실행이 덮어쓰지 않는다). -->\n\n" + body + "\n\n<!-- AI:END -->")
new, n = re.subn(r"<!-- AI:BEGIN.*?AI:END -->", lambda _: block, txt, flags=re.S)
if n != 1:
    sys.exit(f"{key}: 문서에서 AI 블록을 찾지 못했다 ({doc})")
open(doc, "w", encoding="utf-8").write(new)

issue["filled_at"] = datetime.datetime.now().isoformat(timespec="seconds")
issue.setdefault("changelog", []).append(
    {"at": issue["filled_at"][:10], "event": "AI 분석·수정 계획 작성"})
m = re.search(r"Recommendation:\s*([A-Z_]+)", body)
issue["recommendation"] = m.group(1) if m else None
m = re.search(r"Confidence:\s*([0-9.]+)", body)
issue["confidence"] = float(m.group(1)) if m else None
json.dump(d, open(store_p, "w"), ensure_ascii=False, indent=1)
print(f"    작성 완료 → {issue['doc']}  "
      f"[{issue.get('recommendation')}] conf={issue.get('confidence')}", file=sys.stderr)
PY
done
