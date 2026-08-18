#!/usr/bin/env bash
# state/issues.json(정본) → ISSUE_TABLE.md(생성물)
# AI 를 쓰지 않는다. 순수 변환이므로 공짜이고 결과가 흔들리지 않는다.
# 이 파일을 손으로 고치지 마라 — 다음 실행에서 덮어써진다.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/config.sh" ]] || { echo "config.sh 가 없다. \`cp config.example.sh config.sh\` 후 값을 채워라." >&2; exit 1; }
source "$HERE/config.sh"; source "$LIB_DIR/common.sh"

[[ -f "$ISSUES_JSON" ]] || die "정본이 없다: $ISSUES_JSON (먼저 scan-issues.sh 실행)"

python3 - "$ISSUES_JSON" "$TABLE_MD" "$SITE_URL" "$JIRA_DIR" <<'PY'
import json, os, sys
from collections import Counter, defaultdict

store_p, out_p, site, root = sys.argv[1:5]
d = json.load(open(store_p))
issues = [i for i in d["issues"] if not i.get("gone_since")]
gone = [i for i in d["issues"] if i.get("gone_since")]

def esc(s):
    return (str(s or "").replace("|", "\\|").replace("\n", " ").strip())

def kind_of(i):
    return i.get("kind") or i.get("issuetype") or "?"

L = [f"# Jira Issue Table", "",
     f"> 생성물이다. 손으로 고치지 마라 — `bin/render-table.sh` 가 덮어쓴다.",
     f"> 정본은 `state/issues.json`.", "",
     f"- 갱신: {d.get('generated_at','?')}  (마지막 스캔: `{d.get('last_scan_mode','?')}`)",
     f"- 열린 이슈: **{len(issues)}건**"]
if gone:
    L.append(f"- 담당 이탈/완료: {len(gone)}건")
sp = d.get("scanned_projects") or []
L.append(f"- 스캔 성공 프로젝트: {', '.join(f'`{p}`' for p in sp) if sp else '없음'}")

need_desc = [i for i in issues if not (i.get("description") or "").strip()]
unclass  = [i for i in issues if not i.get("classified_at")]
L += ["", f"- 분류 대기: {len(unclass)}건",
      f"- **본문 없음: {len(need_desc)}건** — 이 이슈들은 AI 분석이 불가능하다. "
      f"Jira 에 증상/재현 경로를 채워야 한다.", ""]

# ── 프로젝트별 ──────────────────────────────────────────────────────────
by_proj = defaultdict(list)
for i in issues:
    by_proj[i.get("project") or "?"].append(i)

L += ["## 프로젝트 요약", "",
      "| 프로젝트 | 건수 | 본문 없음 | 분류 대기 |",
      "|---|---:|---:|---:|"]
for p, items in sorted(by_proj.items(), key=lambda kv: -len(kv[1])):
    nd = sum(1 for i in items if not (i.get("description") or "").strip())
    nc = sum(1 for i in items if not i.get("classified_at"))
    L.append(f"| `{p}` | {len(items)} | {nd} | {nc} |")
L.append("")

for p, items in sorted(by_proj.items(), key=lambda kv: -len(kv[1])):
    L += [f"## {p}", "",
          "| Key | 유형 | 상태 | Feature | 요약 | 본문 | 갱신 | 문서 |",
          "|---|---|---|---|---|:-:|---|---|"]
    for i in sorted(items, key=lambda x: x.get("updated") or "", reverse=True):
        k = i["key"]
        feat = f"`{i['feature']}`" if i.get("feature") else "—"
        has = "○" if (i.get("description") or "").strip() else "**✗**"
        doc = i.get("doc")
        doc_cell = f"[문서]({os.path.relpath(os.path.join(root, doc), root)})" if doc else "—"
        L.append(f"| [{k}]({site}/browse/{k}) | {esc(kind_of(i))} | {esc(i.get('status'))} "
                 f"| {feat} | {esc(i.get('summary'))[:60]} | {has} "
                 f"| {esc((i.get('updated') or '')[:10])} | {doc_cell} |")
    L.append("")

if need_desc:
    L += ["## 본문이 없어 분석할 수 없는 이슈", "",
          "제목 한 줄로는 설계도 구현도 만들 수 없다. 여기 있는 이슈는",
          "AI 를 더 돌리는 게 아니라 **Jira 본문을 채우는 것**이 다음 행동이다.", ""]
    for i in sorted(need_desc, key=lambda x: x.get("key")):
        L.append(f"- [{i['key']}]({site}/browse/{i['key']}) {esc(i.get('summary'))}")
    L.append("")

if gone:
    L += ["<details><summary>담당 이탈 / 완료 " + str(len(gone)) + "건</summary>", ""]
    for i in sorted(gone, key=lambda x: x.get("gone_since") or ""):
        L.append(f"- [{i['key']}]({site}/browse/{i['key']}) {esc(i.get('summary'))} "
                 f"— {i.get('gone_since','')[:10]} 확인")
    L += ["", "</details>", ""]

open(out_p, "w", encoding="utf-8").write("\n".join(L) + "\n")
print(f"테이블 갱신: {out_p} (열린 이슈 {len(issues)}건, 본문 없음 {len(need_desc)}건)",
      file=sys.stderr)
PY
