#!/usr/bin/env bash
# 이슈 문서를 feature 디렉터리에 **정확히 하나씩** 유지한다.
# AI 를 쓰지 않는다 — 템플릿 치환과 파일 이동뿐이라 결과가 흔들리지 않는다.
#
#   make-feature.sh          정본을 훑어 문서 생성·이동·블록 보강
#
# 이 스크립트의 계약:
#   1. 한 이슈에 문서는 **하나만** 존재한다.
#      재분류로 feature 가 바뀌면 새로 만들지 않고 **옮긴다**.
#      (기존 구현은 새 경로에 만들고 옛 파일을 남겨 중복을 만들었다.)
#   2. 이미 있는 파일의 내용은 덮어쓰지 않는다.
#      META/HISTORY/SOURCE/CHANGELOG 블록만 갱신하고,
#      AI·PROGRESS·「사람 검토」는 건드리지 않는다.
#   3. 템플릿이 바뀌어 없는 블록이 생기면 **끼워 넣어** 구버전 문서를 이행시킨다.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/config.sh" ]] || { echo "config.sh 가 없다. \`cp config.example.sh config.sh\` 후 값을 채워라." >&2; exit 1; }
source "$HERE/config.sh"; source "$LIB_DIR/common.sh"

[[ -f "$ISSUES_JSON" ]] || die "정본이 없다: $ISSUES_JSON"

python3 - "$ISSUES_JSON" "$PROJ_DIR" "$TPL_DIR" "$SITE_URL" "$JIRA_DIR" <<'PY'
import json, os, re, sys, datetime, glob
store_p, proj_dir, tpl_dir, site, root = sys.argv[1:6]
d = json.load(open(store_p))
now = datetime.datetime.now().strftime("%F %T")
today = now[:10]
tpl = open(os.path.join(tpl_dir, "issue.md"), encoding="utf-8").read()
feat_tpl = open(os.path.join(tpl_dir, "feature.md"), encoding="utf-8").read()

SLUG_OK = re.compile(r"^[a-z0-9][a-z0-9-]{0,60}$")
made = moved = migrated = dupes = 0


def block(txt, name):
    """<!-- NAME:BEGIN ... NAME:END --> 를 통째로 반환. 없으면 None."""
    m = re.search(rf"<!-- {name}:BEGIN.*?{name}:END -->", txt, re.S)
    return m.group(0) if m else None


def inner(txt, name):
    """블록 안쪽 본문만 반환. 없으면 None."""
    m = re.search(rf"<!-- {name}:BEGIN.*?-->\n?(.*?)\n?<!-- {name}:END -->", txt, re.S)
    return m.group(1) if m else None


def wrap(name, body, note=""):
    head = f"<!-- {name}:BEGIN{(' ' + note) if note else ''} -->"
    return f"{head}\n{body}\n<!-- {name}:END -->"


def rebuild(txt, title, machine):
    """문서를 정규 순서로 재조립한다.

    META/HISTORY/SOURCE/CHANGELOG 는 매 실행 재생성(machine),
    AI/PROGRESS/사람 검토는 기존 내용을 그대로 보존한다.
    블록을 그때그때 끼워 넣으면 실행마다 순서가 뒤집히고 제목이 중복된다.
    """
    ai = inner(txt, "AI") or ("## 이슈 해석\n\n_(대기)_\n\n## 원인 분석\n\n_(대기)_\n\n"
                              "## 수정 계획\n\n_(대기)_\n\n## 확인 필요\n\n_(대기)_")
    prog = inner(txt, "PROGRESS") or "## 진행\n\n_(아직 착수 전)_"
    m = re.search(r"^## 사람 검토\s*$(.*)", txt, re.S | re.M)
    if m:
        human = m.group(1)
        # 과거 이행에서 문서 끝에 덧붙은 기계 블록이 사람 영역으로 딸려올 수 있다.
        # 그대로 두면 매 실행마다 중복 블록이 쌓인다.
        for n in ("META", "HISTORY", "SOURCE", "AI", "PROGRESS", "CHANGELOG"):
            human = re.sub(rf"<!-- {n}:BEGIN.*?{n}:END -->", "", human, flags=re.S)
        human = human.strip()
    else:
        human = "- [ ] 요구사항 해석 확인\n- [ ] 수정 계획 승인\n- 메모:"

    # 알려진 블록·제목·구분선을 걷어낸 나머지. 있으면 버리지 않고 보존한다.
    left = txt
    for n in ("META", "HISTORY", "SOURCE", "AI", "PROGRESS", "CHANGELOG"):
        left = re.sub(rf"<!-- {n}:BEGIN.*?{n}:END -->", "", left, flags=re.S)
    left = re.sub(r"^## 사람 검토\s*$.*", "", left, flags=re.S | re.M)
    left = re.sub(r"^#\s.*$", "", left, flags=re.M)
    left = re.sub(r"^(---|## Jira 원문)\s*$", "", left, flags=re.M)
    left = "\n".join(l for l in left.splitlines() if l.strip())

    parts = [f"# {title}", "",
             wrap("META", machine["META"], "스크립트가 갱신한다. 손으로 고치지 마라."),
             wrap("HISTORY", machine["HISTORY"], "상태 전이 누적. 추가만 된다."),
             wrap("SOURCE", machine["SOURCE"], "Jira 원문 사본."),
             "", "---", "",
             wrap("AI", ai, "사람이 고쳐도 다음 실행이 덮어쓰지 않는다."),
             "", wrap("PROGRESS", prog, "진행 상황."),
             "", wrap("CHANGELOG", machine["CHANGELOG"], "추가만 된다."),
             "", "---", "", "## 사람 검토", human]
    if left:
        parts += ["", "## 이전 문서 잔여 내용", "",
                  "<!-- 구조 이행 중 어느 블록에도 속하지 않은 내용. 확인 후 지워도 된다. -->",
                  "", left]
    return "\n".join(parts) + "\n"


def rows(existing, entries, fmt):
    """표 블록에 새 행만 추가한다(중복 방지). entries 는 정본의 누적 리스트."""
    out = []
    for e in entries:
        line = fmt(e)
        if line not in existing:
            out.append(line)
    return out


for i in d["issues"]:
    if not i.get("classified_at"):
        continue
    key = i["key"]
    # 이력 필드가 나중에 추가돼 예전에 수집된 이슈에는 없다. 여기서 보정한다.
    # (스캔은 델타라 손대지 않은 이슈를 영원히 비워 둔다.)
    seed = (i.get("first_seen") or now)[:10]
    if not i.get("status_history"):
        i["status_history"] = [{"at": seed, "from": None, "to": i.get("status")}]
    if not i.get("changelog"):
        i["changelog"] = [{"at": seed, "event": "Jira 에서 수집"}]
    proj = i.get("project") or "UNKNOWN"
    slug = i.get("feature")
    if slug and not SLUG_OK.match(slug):
        print(f"  !! {key}: 슬러그 규칙 위반({slug!r}) → _inbox", file=sys.stderr)
        slug = None
    want_dir = os.path.join(proj_dir, proj, slug or "_inbox")
    want = os.path.join(want_dir, f"{key}.md")

    # ── 1) 이 이슈의 기존 문서를 전부 찾는다(중복 탐지 포함) ──────────────
    found = sorted(glob.glob(os.path.join(proj_dir, "**", f"{key}.md"), recursive=True))
    os.makedirs(want_dir, exist_ok=True)

    if not found:
        open(want, "w", encoding="utf-8").write(
            tpl.replace("{{KEY}}", key).replace("{{SUMMARY}}", i.get("summary") or ""))
        made += 1
        i.setdefault("changelog", []).append({"at": today, "event": f"문서 생성: {os.path.relpath(want, root)}"})
        print(f"  + {os.path.relpath(want, root)}", file=sys.stderr)
    else:
        src = found[0]
        # 중복이 이미 있으면 첫 번째만 남기고 나머지는 병합하지 않고 보고한다.
        for extra in found[1:]:
            print(f"  !! 중복 문서 발견 — 수동 확인 필요: {os.path.relpath(extra, root)}",
                  file=sys.stderr)
            dupes += 1
        if os.path.abspath(src) != os.path.abspath(want):
            os.replace(src, want)          # 새로 만들지 않고 이동
            moved += 1
            i.setdefault("changelog", []).append(
                {"at": today,
                 "event": f"문서 이동: {os.path.relpath(src, root)} → {os.path.relpath(want, root)}"})
            print(f"  → 이동 {os.path.relpath(src, root)} ⇒ {os.path.relpath(want, root)}",
                  file=sys.stderr)
            # 빈 디렉터리 정리
            try: os.rmdir(os.path.dirname(src))
            except OSError: pass

    i["doc"] = os.path.relpath(want, root)

    # ── 2) 정규 순서로 재조립 (기계 블록 갱신 + 사람 내용 보존) ─────────
    txt = open(want, encoding="utf-8").read()
    before = txt

    desc = (i.get("description") or "").strip() or \
        "_(Jira 에 본문이 없다. 제목만으로는 분석할 수 없다 — Jira 에 증상·재현 경로를 채워야 한다.)_"
    hist = i.get("status_history") or []
    clog = i.get("changelog") or []
    machine = {
        "META": "\n".join([
            f"- Jira: [{key}]({site}/browse/{key})",
            f"- 프로젝트 `{proj}` / feature `{slug or '_inbox'}`",
            f"- 유형 {i.get('kind') or '?'} (Jira: {i.get('issuetype') or '?'})"
            f" / 상태 **{i.get('status') or '?'}** / 우선순위 {i.get('priority') or '?'}",
            f"- Jira 갱신 {(i.get('updated') or '')[:19]} / 최근 동기화 {now}",
        ]),
        "HISTORY": "## 상태 이력\n\n| 날짜 | 전이 |\n|---|---|\n" + "\n".join(
            f"| {h['at']} | {h.get('from') or '(등록)'} → {h.get('to')} |" for h in hist),
        "SOURCE": "## Jira 원문\n\n" + desc,
        # 표는 한 줄 요약만. 실제 변경분(diff)은 표를 깨지 않게 접이식 블록으로 뒤에 붙인다.
        "CHANGELOG": ("## 체인지로그\n\n| 날짜 | 내용 |\n|---|---|\n" + "\n".join(
            f"| {c['at']} | {c.get('event')} |" for c in clog)
            + "".join(
                f"\n\n<details>\n<summary>{c['at']} · {c.get('event')}</summary>\n\n"
                f"```diff\n{c['diff']}\n```\n\n</details>"
                for c in clog if c.get("diff"))),
    }
    txt = rebuild(txt, f"{key} {i.get('summary') or ''}".strip(), machine)

    if txt != before:
        if not block(before, "CHANGELOG"):
            migrated += 1
        open(want, "w", encoding="utf-8").write(txt)

# ── 3) FEATURE.md 생성 및 소속 이슈 목록 갱신 ───────────────────────────
by_feat = {}
for i in d["issues"]:
    if i.get("feature") and not i.get("gone_since"):
        by_feat.setdefault((i["project"], i["feature"]), []).append(i)

for (proj, slug), items in sorted(by_feat.items()):
    fp = os.path.join(proj_dir, proj, slug, "FEATURE.md")
    if not os.path.exists(fp):
        title = next((x.get("feature_title") for x in items if x.get("feature_title")), slug)
        os.makedirs(os.path.dirname(fp), exist_ok=True)
        open(fp, "w", encoding="utf-8").write(
            feat_tpl.replace("{{FEATURE_TITLE}}", title).replace("{{FEATURE_SLUG}}", slug)
                    .replace("{{PROJECT}}", proj).replace("{{CREATED}}", now))
        print(f"  + feature {proj}/{slug}", file=sys.stderr)
    lines = [f"- [{x['key']}]({site}/browse/{x['key']}) [{x.get('kind','?')}] "
             f"{x.get('summary','')} — {x.get('status','')} ([문서](./{x['key']}.md))"
             for x in sorted(items, key=lambda y: y["key"])]
    blk = ("<!-- ISSUES:BEGIN 이 블록은 bin/make-feature.sh 가 갱신한다. 손으로 고치지 마라. -->\n"
           + "\n".join(lines) + "\n<!-- ISSUES:END -->")
    t = open(fp, encoding="utf-8").read()
    n = re.sub(r"<!-- ISSUES:BEGIN.*?ISSUES:END -->", lambda _: blk, t, flags=re.S)
    if n != t:
        open(fp, "w", encoding="utf-8").write(n)

# ── 4) 고아 feature 디렉터리 정리 ───────────────────────────────────────
# 이슈가 전부 다른 feature 로 옮겨가면 FEATURE.md 만 남은 빈 디렉터리가 생긴다.
# 사람이 설계 메모를 쓴 FEATURE.md 는 지우면 안 되므로,
# 템플릿 그대로인 것만 제거하고 나머지는 보고한다.
orphans = removed = 0
for fp in glob.glob(os.path.join(proj_dir, "*", "*", "FEATURE.md")):
    fdir = os.path.dirname(fp)
    if glob.glob(os.path.join(fdir, "*.md")) != [fp]:
        continue                                    # 아직 이슈 문서가 있다
    orphans += 1
    body = open(fp, encoding="utf-8").read()
    untouched = ("_(이 feature 가 무엇을 다루는지" in body
                 and "_(사람이 쓴다. AI 가 채우지 않는다.)_" in body)
    if untouched:
        os.remove(fp)
        try: os.rmdir(fdir)
        except OSError: pass
        removed += 1
        print(f"  - 빈 feature 제거: {os.path.relpath(fdir, root)}", file=sys.stderr)
    else:
        print(f"  !! 이슈 없는 feature 인데 사람이 쓴 내용이 있다 — 수동 확인: "
              f"{os.path.relpath(fp, root)}", file=sys.stderr)

json.dump(d, open(store_p, "w"), ensure_ascii=False, indent=1)
msg = f"문서 생성 {made} / 이동 {moved} / 블록 보강 {migrated} / 빈 feature 제거 {removed}"
if dupes:
    msg += f" / ⚠ 중복 {dupes}"
print(msg, file=sys.stderr)
PY
