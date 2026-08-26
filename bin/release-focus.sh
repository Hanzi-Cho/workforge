#!/usr/bin/env bash
# "지금 진행 중인 릴리스" 를 판정해 state/release-focus.json 에 쓴다.
#
#   release-focus.sh          정본을 읽어 활성 릴리스와 소속 이슈를 계산
#
# AI 를 쓰지 않는다. 판정은 전부 규칙이다 — 매일 같은 입력이면 같은 결과가 나온다.
# (릴리스 판정을 AI 에 맡기면 어제는 v0.0.8, 오늘은 v0.0.7 로 흔들린다.
#  그러면 워크트리가 엉뚱한 기준에서 갈라진다.)
#
# 판정 규칙 — 자세한 근거는 config.sh 의 RELEASE_FOCUS 주석:
#   1) 내 담당 미완료 이슈에 붙은 Fix Version 만 후보.
#   2) released=true 는 제외. released 를 모르면(null) 미릴리즈로 간주한다.
#   3) 릴리스 라인별로 버전 번호가 가장 높은 하나만 활성.
#
# 정본에 기록하는 것: release_focus / release_focus_since, 그리고 진입·이탈 체인지로그.
# 이 필드가 있으면 뒤 단계(워크트리·문서 작성 우선순위)가 다시 계산하지 않는다.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/config.sh" ]] || { echo "config.sh 가 없다. \`cp config.example.sh config.sh\` 후 값을 채워라." >&2; exit 1; }
source "$HERE/config.sh"; source "$LIB_DIR/common.sh"

[[ -f "$ISSUES_JSON" ]] || die "정본이 없다: $ISSUES_JSON"

if [[ "$RELEASE_FOCUS" != "1" ]]; then
  log "릴리스 포커스 비활성(RELEASE_FOCUS=$RELEASE_FOCUS)"
  exit 0
fi

python3 - "$ISSUES_JSON" "$FOCUS_JSON" <<'PY'
import json, re, sys, datetime
from collections import Counter, defaultdict

store_p, focus_p = sys.argv[1:3]
doc = json.load(open(store_p))
issues = doc["issues"]
rel_meta = doc.get("releases") or {}
now = datetime.datetime.now().isoformat(timespec="seconds")
today = now[:10]

# 버전 이름을 (라인, 번호) 로 쪼갠다.
#   blaster-launcher-v0.0.8  → ("blaster-launcher", (0,0,8), None)
#   [Planner] v2.4.1         → ("[Planner]",        (2,4,1), None)
#   [Planner] v2.0.9-rc5     → ("[Planner]",        (2,0,9), "-rc5")
# 라인이 다르면 서로 다른 제품의 릴리스다. 절대 같이 비교하지 않는다.
VER_RE = re.compile(r"^(?P<line>.*?)[\s._-]*v?(?P<num>\d+(?:\.\d+)*)"
                    r"(?P<suf>[-.][A-Za-z0-9.]+)?\s*$")


def parse_version(name):
    m = VER_RE.match(name or "")
    if not m:
        # 번호가 없는 이름(예: "backlog")은 라인 자체로 두고 최하위로 정렬한다.
        return (name or "").strip(), (), None
    line = re.sub(r"[\s._-]*v?$", "", m.group("line")).strip()
    nums = tuple(int(x) for x in m.group("num").split("."))
    return line or (name or "").strip(), nums, m.group("suf")


def sort_key(nums, suf):
    # 접미사 없는 정식 릴리스가 rc/alpha 보다 최신이다. v2.0.9 > v2.0.9-rc5.
    return (nums, 1 if not suf else 0, (suf or "").lower())


live = [i for i in issues if not i.get("gone_since")]

# ── 1) 후보 수집 ────────────────────────────────────────────────────────
# 후보는 "내 담당 미완료 이슈에 실제로 붙어 있는" 버전뿐이다.
cand = {}                                   # (proj, name) -> {...}
members = defaultdict(list)                 # (proj, name) -> [issue]
for i in live:
    proj = i.get("project")
    for name in i.get("fix_versions") or []:
        members[(proj, name)].append(i)
        if (proj, name) in cand:
            continue
        meta = rel_meta.get(f"{proj}|{name}") or {}
        line, nums, suf = parse_version(name)
        cand[(proj, name)] = {
            "project": proj, "name": name, "line": line,
            "released": meta.get("released"),
            "release_date": meta.get("release_date"),
            "sort": sort_key(nums, suf),
        }

# ── 2) 릴리스된 버전 제외 ───────────────────────────────────────────────
# released 를 모르면(null) 남긴다. 새로 만든 릴리스는 메타를 아직 못 받았을 수
# 있는데, 그걸 배제하면 정작 오늘 만든 릴리스가 포커스에서 빠진다.
open_cand = {k: v for k, v in cand.items() if v["released"] is not True}
dropped_released = sorted(k[1] for k, v in cand.items() if v["released"] is True)

# ── 3) 라인별 최신 하나만 ───────────────────────────────────────────────
by_line = defaultdict(list)
for k, v in open_cand.items():
    by_line[(v["project"], v["line"])].append((v["sort"], k))
active = set()
superseded = []
for _, lst in by_line.items():
    lst.sort(reverse=True)
    active.add(lst[0][1])
    superseded += [k[1] for _, k in lst[1:]]

# ── 4) 출력 + 정본 갱신 ─────────────────────────────────────────────────
STATUS_ORDER = ("해야 할 일", "진행 중", "검토", "수정완료", "승인 대기")


def status_sort(s):
    try:
        return STATUS_ORDER.index(s)
    except ValueError:
        return len(STATUS_ORDER)


focus_by_key = {}
out_releases = []
for k in sorted(active, key=lambda x: (x[0], x[1])):
    v = open_cand[k]
    items = sorted(members[k], key=lambda i: i["key"])
    for i in items:
        focus_by_key[i["key"]] = v["name"]
    out_releases.append({
        "project": v["project"], "line": v["line"], "name": v["name"],
        "released": v["released"], "release_date": v["release_date"],
        "counts_by_status": dict(sorted(
            Counter(i.get("status") or "?" for i in items).items(),
            key=lambda kv: status_sort(kv[0]))),
        "issues": [{"key": i["key"], "status": i.get("status"),
                    "product": i.get("product"), "kind": i.get("kind"),
                    "summary": i.get("summary"),
                    "worktree": i.get("worktree")} for i in items],
    })

entered, left = [], []
for i in issues:
    was = i.get("release_focus")
    nowrel = focus_by_key.get(i["key"])
    if was == nowrel:
        continue
    i["release_focus"] = nowrel
    if nowrel:
        i["release_focus_since"] = today
        i.setdefault("changelog", []).append(
            {"at": today, "event": f"릴리스 포커스 진입: {nowrel}"})
        entered.append(i["key"])
    else:
        i.setdefault("changelog", []).append(
            {"at": today, "event": f"릴리스 포커스 이탈: {was}"})
        left.append(i["key"])

json.dump({
    "generated_at": now,
    "releases": out_releases,
    "focus_keys": sorted(focus_by_key),
    "entered_today": sorted(entered),
    "left_today": sorted(left),
    "excluded": {"released": dropped_released,
                 "superseded_in_line": sorted(superseded)},
}, open(focus_p, "w"), ensure_ascii=False, indent=1)
json.dump(doc, open(store_p, "w"), ensure_ascii=False, indent=1)

if not out_releases:
    print("활성 릴리스 없음 — 내 담당 이슈에 미릴리즈 Fix Version 이 하나도 없다.",
          file=sys.stderr)
for r in out_releases:
    st = " · ".join(f"{s} {n}" for s, n in r["counts_by_status"].items())
    print(f"  ◆ {r['name']} ({r['project']}) {len(r['issues'])}건 — {st}",
          file=sys.stderr)
if entered:
    print(f"  포커스 진입 {len(entered)}건: {', '.join(entered)}", file=sys.stderr)
if left:
    print(f"  포커스 이탈 {len(left)}건: {', '.join(left)}", file=sys.stderr)
if dropped_released:
    print(f"  제외(릴리스 완료): {', '.join(dropped_released)}", file=sys.stderr)
if superseded:
    print(f"  제외(같은 라인의 구버전): {', '.join(sorted(set(superseded)))}",
          file=sys.stderr)
PY
