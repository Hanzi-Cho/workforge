#!/usr/bin/env bash
# 정본 → reports/<날짜>.md 데일리 리포트 하나.
#
#   render-report.sh              오늘 날짜로
#   render-report.sh 2026-08-19   날짜 지정
#   NO_BRIEFING=1 render-report.sh   브리핑(AI) 생략
#
# 리포트에는 목록과 브리핑만 담는다. 원인 분석·수정 계획·진행은
# 이슈별 문서(projects/<PROJ>/<feature>/<KEY>.md)가 소유한다.
# 한 이슈는 한 줄로 끝낸다.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/config.sh" ]] || { echo "config.sh 가 없다. \`cp config.example.sh config.sh\` 후 값을 채워라." >&2; exit 1; }
source "$HERE/config.sh"; source "$LIB_DIR/common.sh"

[[ -f "$ISSUES_JSON" ]] || die "정본이 없다: $ISSUES_JSON"
DATE="${1:-$(date +%F)}"
mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/$DATE.md"

# ── 1) 목록 렌더 + 브리핑용 요약 추출 ───────────────────────────────────
SUMMARY="$STATE_DIR/.briefing.json"
python3 - "$ISSUES_JSON" "$REPORT" "$SITE_URL" "$DATE" "$SUMMARY" <<'PY'
import json, sys, datetime
store_p, out_p, site, date, sum_p = sys.argv[1:6]
d = json.load(open(store_p))
live = [i for i in d["issues"] if not i.get("gone_since")]

def line(i, transition=False):
    """한 이슈 = 한 줄. 링크 · 제목 · (상태전이) · 파일경로."""
    seg = f"- [{i['key']}]({site}/browse/{i['key']}) {i.get('summary','').strip()}"
    if transition:
        tr = [h for h in (i.get("status_history") or []) if h["at"] == date and h.get("from")]
        if tr:
            seg += " — " + " → ".join([tr[0]["from"]] + [t["to"] for t in tr])
    return seg + f" — `{i.get('doc') or '(문서 없음)'}`"

new  = [i for i in live if (i.get("first_seen") or "")[:10] == date]
newk = {i["key"] for i in new}
chg  = [i for i in live if i["key"] not in newk
        and any(h["at"] == date for h in (i.get("status_history") or []) if h.get("from"))]
chgk = {i["key"] for i in chg}
rest = [i for i in live if i["key"] not in newk and i["key"] not in chgk]

def bykey(x): return x["key"]
L = [f"# {date} Daily Report", ""]
L += [f"## 신규 ({len(new)})", ""]
L += [line(i) for i in sorted(new, key=bykey)] or ["- 없음"]
L += ["", f"## 변경 ({len(chg)})", ""]
L += [line(i, True) for i in sorted(chg, key=bykey)] or ["- 없음"]
L += ["", f"## 잔여 ({len(rest)})", ""]
L += [line(i) for i in sorted(rest, key=bykey)] or ["- 없음"]
open(out_p, "w", encoding="utf-8").write("\n".join(L) + "\n")

# 브리핑에 넘길 요약 — 판단에 필요한 것만, 목록 전체를 넘기지 않는다.
def slim(items, n=12):
    return [{"key": i["key"], "summary": i.get("summary"), "kind": i.get("kind"),
             "feature": i.get("feature"), "status": i.get("status"),
             "has_desc": bool((i.get("description") or "").strip()),
             "recommendation": i.get("recommendation")} for i in items[:n]]
from collections import Counter
json.dump({
    "date": date,
    "counts": {"new": len(new), "changed": len(chg), "remaining": len(rest)},
    "no_description": sum(1 for i in live if not (i.get("description") or "").strip()),
    "total_open": len(live),
    "by_feature": dict(Counter(f"{i.get('project')}/{i.get('feature') or '_inbox'}"
                               for i in live).most_common(8)),
    "recommendations": dict(Counter(i.get("recommendation") for i in live
                                    if i.get("recommendation"))),
    "new_issues": slim(sorted(new, key=bykey)),
    "changed_issues": slim(sorted(chg, key=bykey)),
}, open(sum_p, "w"), ensure_ascii=False, indent=1)
print(f"목록: 신규 {len(new)} / 변경 {len(chg)} / 잔여 {len(rest)}", file=sys.stderr)
PY

# ── 2) 브리핑(8줄 이내) ─────────────────────────────────────────────────
{
  echo
  echo "---"
  echo
  echo "## 브리핑"
  echo
} >> "$REPORT"

if [[ -n "${NO_BRIEFING:-}" ]]; then
  echo "- (브리핑 생략됨)" >> "$REPORT"
else
  RENDER="$STATE_DIR/.briefing.prompt.md"
  python3 - "$PROMPT_DIR/briefing.md" "$SUMMARY" > "$RENDER" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
sys.stdout.write(t.replace("__SUMMARY_JSON__", open(sys.argv[2], encoding="utf-8").read()))
PY
  if run_ai "$TIMEOUT_CLASSIFY" "$MODEL_CLASSIFY" "$RENDER" > "$STATE_DIR/.briefing.out"; then
    # 8줄 상한은 코드가 강제한다. 프롬프트만으로는 지켜지지 않는다.
    python3 - "$STATE_DIR/.briefing.out" "$REPORT" <<'PY'
import sys, re
raw = open(sys.argv[1], encoding="utf-8").read()
raw = re.sub(r"^```.*?$|^```$", "", raw, flags=re.M)
lines = [l.rstrip() for l in raw.splitlines() if l.strip()]
lines = [l if l.lstrip().startswith(("-", "*")) else "- " + l.lstrip() for l in lines]
kept, dropped = lines[:8], len(lines) - 8
with open(sys.argv[2], "a", encoding="utf-8") as f:
    f.write("\n".join(kept) + "\n")
    if dropped > 0:
        f.write(f"\n<!-- 브리핑 {dropped}줄이 8줄 상한으로 잘렸다. -->\n")
print(f"브리핑 {len(kept)}줄" + (f" ({dropped}줄 잘림)" if dropped > 0 else ""),
      file=sys.stderr)
PY
  else
    echo "- ⚠ 브리핑 생성 실패. 위 목록으로 판단할 것." >> "$REPORT"
    log "브리핑 실패 — 목록은 정상 생성됨"
  fi
fi

log "리포트: $REPORT"
