#!/usr/bin/env bash
# 분류 결과대로 projects/<PROJECT>/<feature>/ 구조와 문서 골격을 만든다.
# AI 를 쓰지 않는다 — 템플릿 치환뿐이므로 결과가 흔들리지 않는다.
#
#   make-feature.sh          정본 전체를 훑어 없는 것만 생성
#
# 이미 있는 파일은 절대 덮어쓰지 않는다. 사람이 쓴 내용을 날리면 신뢰를 잃는다.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/config.sh" ]] || { echo "config.sh 가 없다. \`cp config.example.sh config.sh\` 후 값을 채워라." >&2; exit 1; }
source "$HERE/config.sh"; source "$LIB_DIR/common.sh"

[[ -f "$ISSUES_JSON" ]] || die "정본이 없다: $ISSUES_JSON"

python3 - "$ISSUES_JSON" "$PROJ_DIR" "$TPL_DIR" "$SITE_URL" "$JIRA_DIR" <<'PY'
import json, os, re, sys, datetime
store_p, proj_dir, tpl_dir, site, root = sys.argv[1:6]
d = json.load(open(store_p))
now = datetime.datetime.now().strftime("%F %T")
feat_tpl = open(os.path.join(tpl_dir, "feature.md"), encoding="utf-8").read()
issue_tpl = open(os.path.join(tpl_dir, "issue.md"), encoding="utf-8").read()

SLUG_OK = re.compile(r"^[a-z0-9][a-z0-9-]{0,60}$")
made_f = made_i = 0

for i in d["issues"]:
    if i.get("gone_since") or not i.get("classified_at"):
        continue
    proj = i.get("project") or "UNKNOWN"
    slug = i.get("feature")
    if slug and not SLUG_OK.match(slug):
        print(f"  !! {i['key']}: 슬러그가 규칙에 안 맞는다 ({slug!r}) → _inbox", file=sys.stderr)
        slug = None
    fdir = os.path.join(proj_dir, proj, slug or "_inbox")
    os.makedirs(fdir, exist_ok=True)

    # feature 문서 (슬러그가 있을 때만)
    if slug:
        fp = os.path.join(fdir, "FEATURE.md")
        if not os.path.exists(fp):
            body = (feat_tpl
                    .replace("{{FEATURE_TITLE}}", i.get("feature_title") or slug)
                    .replace("{{FEATURE_SLUG}}", slug)
                    .replace("{{PROJECT}}", proj)
                    .replace("{{CREATED}}", now))
            open(fp, "w", encoding="utf-8").write(body)
            made_f += 1
            print(f"  + feature {proj}/{slug}", file=sys.stderr)

    # 이슈 문서
    ip = os.path.join(fdir, f"{i['key']}.md")
    if not os.path.exists(ip):
        desc = (i.get("description") or "").strip() or \
               "_(Jira 에 본문이 없다. 제목만으로는 분석할 수 없다 — Jira 에 증상/재현 경로를 채워야 한다.)_"
        body = (issue_tpl
                .replace("{{KEY}}", i["key"])
                .replace("{{SUMMARY}}", i.get("summary") or "")
                .replace("{{URL}}", f"{site}/browse/{i['key']}")
                .replace("{{PROJECT}}", proj)
                .replace("{{FEATURE}}", slug or "_inbox")
                .replace("{{KIND}}", i.get("kind") or "?")
                .replace("{{ISSUETYPE}}", i.get("issuetype") or "?")
                .replace("{{STATUS}}", i.get("status") or "?")
                .replace("{{PRIORITY}}", i.get("priority") or "?")
                .replace("{{UPDATED}}", (i.get("updated") or "")[:19])
                .replace("{{CREATED}}", now)
                .replace("{{DESCRIPTION}}", desc))
        open(ip, "w", encoding="utf-8").write(body)
        made_i += 1
        print(f"  + issue   {proj}/{slug or '_inbox'}/{i['key']}.md", file=sys.stderr)

    i["doc"] = os.path.relpath(ip, root)

# FEATURE.md 의 이슈 목록 블록을 갱신한다.
by_feat = {}
for i in d["issues"]:
    if i.get("feature") and not i.get("gone_since"):
        by_feat.setdefault((i["project"], i["feature"]), []).append(i)

for (proj, slug), items in by_feat.items():
    fp = os.path.join(proj_dir, proj, slug, "FEATURE.md")
    if not os.path.exists(fp):
        continue
    lines = [f"- [{i['key']}]({site}/browse/{i['key']}) "
             f"[{i.get('kind','?')}] {i.get('summary','')} — {i.get('status','')} "
             f"([문서](./{i['key']}.md))"
             for i in sorted(items, key=lambda x: x["key"])]
    block = "<!-- ISSUES:BEGIN 이 블록은 bin/make-feature.sh 가 갱신한다. 손으로 고치지 마라. -->\n" \
            + "\n".join(lines) + "\n<!-- ISSUES:END -->"
    txt = open(fp, encoding="utf-8").read()
    new = re.sub(r"<!-- ISSUES:BEGIN.*?ISSUES:END -->", block, txt, flags=re.S)
    if new != txt:
        open(fp, "w", encoding="utf-8").write(new)

json.dump(d, open(store_p, "w"), ensure_ascii=False, indent=1)
print(f"feature {made_f}개 / 이슈 문서 {made_i}개 생성", file=sys.stderr)
PY
