#!/usr/bin/env bash
# 분류가 안 된 이슈를 AI 로 판정해 정본에 기록한다(kind / feature).
# 키를 인자로 주면 그 이슈만, 없으면 classified_at 이 비어있는 것 전부.
#
#   classify-issues.sh            미분류 전부
#   classify-issues.sh PROJ-123   지정 이슈만
#
# 한 번 정해진 분류는 재실행해도 유지된다(summary 가 바뀌면 scan 이 무효화한다).
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/config.sh" ]] || { echo "config.sh 가 없다. \`cp config.example.sh config.sh\` 후 값을 채워라." >&2; exit 1; }
source "$HERE/config.sh"; source "$LIB_DIR/common.sh"

[[ -f "$ISSUES_JSON" ]] || die "정본이 없다: $ISSUES_JSON"

TARGETS_FILE="$STATE_DIR/.classify.targets"
printf '%s\n' "$@" | sed '/^$/d' > "$TARGETS_FILE"

# 대상 이슈와 기존 feature 목록을 프롬프트에 렌더한다.
PAYLOAD="$STATE_DIR/.classify.payload.json"
FEATURES="$STATE_DIR/.classify.features.txt"
python3 - "$ISSUES_JSON" "$TARGETS_FILE" "$PAYLOAD" "$FEATURES" <<'PY'
import json, sys
store = json.load(open(sys.argv[1]))["issues"]
want = {l.strip() for l in open(sys.argv[2]) if l.strip()}

if want:
    targets = [i for i in store if i["key"] in want]
else:
    targets = [i for i in store if not i.get("classified_at") and not i.get("gone_since")]

feats = sorted({(i.get("project"), i.get("feature"), i.get("feature_title"))
                for i in store if i.get("feature")})
with open(sys.argv[4], "w") as f:
    if feats:
        for p, s, t in feats:
            f.write(f"- {p} / {s} — {t or ''}\n")
    else:
        f.write("(아직 없음 — 필요하면 새로 만들어라)\n")

slim = [{k: i.get(k) for k in
         ("key", "summary", "description", "issuetype", "status",
          "project", "components", "labels", "parent")} for i in targets]
json.dump(slim, open(sys.argv[3], "w"), ensure_ascii=False, indent=1)
print(len(targets))
PY
COUNT="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$PAYLOAD")"

if [[ "$COUNT" == "0" ]]; then
  log "분류할 이슈가 없다."
  exit 0
fi
log "분류 $COUNT건 (model=$MODEL_CLASSIFY)"

RENDER="$STATE_DIR/.classify.prompt.md"
python3 - "$PROMPT_DIR/classify.md" "$PAYLOAD" "$FEATURES" > "$RENDER" <<'PY'
import json, sys
t = open(sys.argv[1], encoding="utf-8").read()
t = t.replace("__ISSUES_JSON__", open(sys.argv[2], encoding="utf-8").read())
t = t.replace("__EXISTING_FEATURES__", open(sys.argv[3], encoding="utf-8").read().strip())
sys.stdout.write(t)
PY

RAW="$STATE_DIR/.classify.raw.txt"
run_ai "$TIMEOUT_CLASSIFY" "$MODEL_CLASSIFY" "$RENDER" > "$RAW"
json_from_ai "$RAW" > "$STATE_DIR/.classify.json"

# 정본에 반영. 스크립트가 쓴다 — AI 에게 파일을 맡기지 않는다.
python3 - "$STATE_DIR/.classify.json" "$ISSUES_JSON" <<'PY'
import json, sys, datetime
res = {r["key"]: r for r in json.load(open(sys.argv[1]))}
d = json.load(open(sys.argv[2]))
now = datetime.datetime.now().isoformat(timespec="seconds")

VALID = {"bug", "improvement", "feature", "task", "unknown"}
applied = skipped = 0
for i in d["issues"]:
    r = res.get(i["key"])
    if not r:
        continue
    kind = r.get("kind")
    if kind not in VALID:
        print(f"  !! {i['key']}: 알 수 없는 kind={kind!r} — 건너뜀", file=sys.stderr)
        skipped += 1
        continue
    i["kind"] = kind
    i["feature"] = r.get("feature") or None
    if r.get("feature_title"):
        i["feature_title"] = r["feature_title"]
    i["classify_confidence"] = r.get("confidence")
    i["classify_rationale"] = r.get("rationale")
    i["classified_at"] = now
    applied += 1

missing = [k for k in res if k not in {i["key"] for i in d["issues"]}]
if missing:
    print(f"  !! 정본에 없는 키를 반환했다: {missing}", file=sys.stderr)

json.dump(d, open(sys.argv[2], "w"), ensure_ascii=False, indent=1)
print(f"분류 반영 {applied}건 (건너뜀 {skipped})", file=sys.stderr)
for i in d["issues"]:
    if res.get(i["key"]) and i.get("classified_at") == now:
        print(f"  {i['key']:10} {i['kind']:12} {i.get('feature') or '_inbox'}",
              file=sys.stderr)
PY
