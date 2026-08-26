#!/usr/bin/env bash
# 활성 릴리스의 이슈마다 `feature/<이슈키>` 브랜치와 워크트리를 미리 만든다.
#
#   make-worktree.sh              release-focus.json 의 이슈 전부
#   make-worktree.sh PROJ-123     지정 이슈만
#   DRY_RUN=1 make-worktree.sh    무엇을 할지만 출력하고 실제로는 안 만든다
#
# 목적은 "언제든 그 디렉터리로 들어가 바로 작업" 이다. 그래서 gitignore 된
# 빌드 필수 파일(local.properties 등)까지 같이 넣어준다.
#
# 안전선 — 이 스크립트는 절대 하지 않는다:
#   - 기존 브랜치·워크트리·디렉터리 삭제나 덮어쓰기
#   - `git worktree prune`  (WSL 에서 prunable 로 보이는 것은 정상이다.
#      Windows git 이 만든 워크트리의 gitdir 표기가 `D:/` 라서 그렇게 보인다.
#      여기서 prune 을 돌리면 살아있는 워크트리 등록이 날아간다.)
#   - `reset --hard` / `checkout -- .`
#   - fetch / push   (분기 기준은 로컬 브랜치다. 네트워크를 쓰지 않는다.)
#
# 이미 있는 디렉터리가 워크트리로 등록돼 있지 않으면 **건드리지 않고 보고만** 한다.
# (실측: HiPlanner_wt/EST-1282 가 그런 상태다 — WSL git 으로 만든 워크트리의
#  등록이 어느 시점에 prune 돼 디렉터리만 남았고, 그 안에 작업물이 있었다.)
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/config.sh" ]] || { echo "config.sh 가 없다. \`cp config.example.sh config.sh\` 후 값을 채워라." >&2; exit 1; }
source "$HERE/config.sh"; source "$LIB_DIR/common.sh"

[[ -f "$ISSUES_JSON" ]] || die "정본이 없다: $ISSUES_JSON"

if [[ "$WORKTREE_AUTO" != "1" ]]; then
  log "워크트리 자동 생성 비활성(WORKTREE_AUTO=$WORKTREE_AUTO)"
  exit 0
fi
[[ -f "$FOCUS_JSON" ]] || die "릴리스 포커스가 없다: $FOCUS_JSON (bin/release-focus.sh 먼저)"

# ── 대상: 활성 릴리스 이슈 (인자로 좁힐 수 있다) ─────────────────────────
# `mapfile < <(cmd)` 는 프로세스 치환이라 cmd 의 실패가 전파되지 않는다.
# 파일로 받아 종료코드를 직접 본다(scan-issues.sh 에서 같은 함정에 한 번 빠졌다).
TARGETS="$STATE_DIR/.worktree.targets.tsv"
python3 - "$ISSUES_JSON" "$FOCUS_JSON" "$@" > "$TARGETS" <<'PY'
import json, sys
store_p, focus_p = sys.argv[1:3]
want = set(sys.argv[3:])
store = {i["key"]: i for i in json.load(open(store_p))["issues"]}
focus = json.load(open(focus_p))
for key in focus.get("focus_keys") or []:
    if want and key not in want:
        continue
    i = store.get(key) or {}
    print("\t".join([key, i.get("product") or "unknown",
                     i.get("release_focus") or "", i.get("summary") or ""]))
PY
mapfile -t ROWS < "$TARGETS"

if [[ ${#ROWS[@]} -eq 0 ]]; then
  log "워크트리 대상이 없다."
  exit 0
fi

RESULT="$STATE_DIR/.worktree.tsv"
: > "$RESULT"

# 등록된 워크트리 경로 목록을 저장소당 한 번만 읽는다.
declare -A WT_LISTED=()
wt_registered() {                       # wt_registered <저장소> <워크트리경로>
  local repo="$1" dir="$2" want
  want="$(winpath "$dir")"
  if [[ -z "${WT_LISTED[$repo]:-}" ]]; then
    WT_LISTED[$repo]="$(git_win "$repo" worktree list --porcelain 2>/dev/null \
      | sed -n 's|^worktree ||p' | tr 'A-Z' 'a-z' | tr '\\' '/')"
  fi
  grep -Fxq "$(tr 'A-Z' 'a-z' <<<"$want")" <<<"${WT_LISTED[$repo]}"
}

CREATED=0; EXISTED=0; CONFLICT=0; SKIPPED=0
for row in "${ROWS[@]}"; do
  IFS=$'\t' read -r KEY PRODUCT RELEASE _SUMMARY <<<"$row"

  REPO="${WT_REPO[$PRODUCT]:-}"
  if [[ -z "$REPO" ]]; then
    log "  - $KEY: product=$PRODUCT 에 저장소 매핑이 없다 — 건너뜀"
    printf '%s\tskipped\t\t\t\t%s\n' "$KEY" "저장소 매핑 없음(product=$PRODUCT)" >> "$RESULT"
    SKIPPED=$((SKIPPED+1)); continue
  fi
  if [[ ! -d "$REPO/.git" && ! -f "$REPO/.git" ]]; then
    log "  - $KEY: 저장소가 없다: $REPO — 건너뜀"
    printf '%s\tskipped\t\t\t\t%s\n' "$KEY" "저장소 없음: $REPO" >> "$RESULT"
    SKIPPED=$((SKIPPED+1)); continue
  fi

  ROOT="${WT_ROOT[$PRODUCT]:-$REPO-wt}"
  BASE="${WT_BASE[$PRODUCT]:-}"
  BR="${BRANCH_PREFIX}${KEY}"
  DIR="$ROOT/$KEY"

  # ── 이미 있는 경우 ────────────────────────────────────────────────────
  if [[ -d "$DIR" ]]; then
    if wt_registered "$REPO" "$DIR"; then
      printf '%s\texists\t%s\t%s\t%s\t\n' "$KEY" "$BR" "$DIR" "$BASE" >> "$RESULT"
      EXISTED=$((EXISTED+1))
    else
      log "  !! $KEY: 디렉터리가 있는데 워크트리로 등록돼 있지 않다 — 손대지 않는다"
      log "     $DIR"
      log "     안에 작업물이 있을 수 있다. 확인 후 옮기거나 이름을 바꿔라."
      printf '%s\tconflict\t%s\t%s\t%s\t%s\n' "$KEY" "$BR" "$DIR" "$BASE" \
        "디렉터리는 있으나 워크트리 미등록 — 수동 확인" >> "$RESULT"
      CONFLICT=$((CONFLICT+1)); continue
    fi
  else
    # ── 새로 만든다 ──────────────────────────────────────────────────────
    if ! git_win "$REPO" rev-parse --verify --quiet "refs/heads/$BASE" >/dev/null; then
      log "  !! $KEY: 기준 브랜치가 없다: $BASE ($REPO) — 건너뜀"
      printf '%s\tskipped\t%s\t%s\t%s\t%s\n' "$KEY" "$BR" "$DIR" "$BASE" \
        "기준 브랜치 없음: $BASE" >> "$RESULT"
      SKIPPED=$((SKIPPED+1)); continue
    fi
    if [[ -n "${DRY_RUN:-}" ]]; then
      log "  (dry-run) $KEY: $BR ← $BASE  →  $DIR"
      continue
    fi
    mkdir -p "$ROOT"
    WIN_DIR="$(winpath "$DIR")"
    if git_win "$REPO" rev-parse --verify --quiet "refs/heads/$BR" >/dev/null; then
      # 브랜치는 이미 있고 워크트리만 없다. 기존 작업을 살려서 붙인다.
      OUT="$(git_win "$REPO" worktree add "$WIN_DIR" "$BR" 2>&1)" || {
        log "  !! $KEY: 기존 브랜치 $BR 붙이기 실패"; sed 's/^/       /' <<<"$OUT" >&2
        printf '%s\tskipped\t%s\t%s\t%s\t%s\n' "$KEY" "$BR" "$DIR" "$BASE" \
          "worktree add 실패(기존 브랜치)" >> "$RESULT"
        SKIPPED=$((SKIPPED+1)); continue; }
      log "  + $KEY: 기존 브랜치 $BR → $DIR"
    else
      OUT="$(git_win "$REPO" worktree add -b "$BR" "$WIN_DIR" "$BASE" 2>&1)" || {
        log "  !! $KEY: 워크트리 생성 실패"; sed 's/^/       /' <<<"$OUT" >&2
        printf '%s\tskipped\t%s\t%s\t%s\t%s\n' "$KEY" "$BR" "$DIR" "$BASE" \
          "worktree add 실패" >> "$RESULT"
        SKIPPED=$((SKIPPED+1)); continue; }
      log "  + $KEY: $BR ← $BASE → $DIR"
    fi
    printf '%s\tcreated\t%s\t%s\t%s\t\n' "$KEY" "$BR" "$DIR" "$BASE" >> "$RESULT"
    CREATED=$((CREATED+1))
  fi

  # ── gitignore 된 빌드 필수 파일 넣어주기 (덮어쓰지 않는다) ─────────────
  for f in ${WT_SEED[$PRODUCT]:-}; do
    [[ -e "$REPO/$f" ]] || continue
    [[ -e "$DIR/$f" ]] && continue
    mkdir -p "$(dirname "$DIR/$f")"
    if cp -p "$REPO/$f" "$DIR/$f"; then
      log "      seed $f"
    else
      log "      !! seed 실패: $f — 워크트리에서 빌드하려면 손으로 복사해야 한다"
    fi
  done
done

# ── 정본에 기록 ─────────────────────────────────────────────────────────
python3 - "$ISSUES_JSON" "$RESULT" <<'PY'
import json, sys, datetime
store_p, res_p = sys.argv[1:3]
doc = json.load(open(store_p))
now = datetime.datetime.now().isoformat(timespec="seconds")
today = now[:10]
by_key = {i["key"]: i for i in doc["issues"]}
n = 0
for line in open(res_p, encoding="utf-8"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 6:
        continue
    key, state, br, path, base, note = parts[:6]
    i = by_key.get(key)
    if not i:
        continue
    if state in ("created", "exists"):
        prev = i.get("worktree") or {}
        i["worktree"] = {"branch": br, "path": path, "base": base,
                         "created_at": prev.get("created_at") or now}
        if state == "created":
            i.setdefault("changelog", []).append(
                {"at": today, "event": f"워크트리 준비: `{br}` ← `{base}` → `{path}`"})
            n += 1
    else:
        i["worktree_blocked"] = {"at": today, "reason": note,
                                 "branch": br, "path": path}
json.dump(doc, open(store_p, "w"), ensure_ascii=False, indent=1)
print(f"정본 기록 {n}건", file=sys.stderr)
PY

log "워크트리 — 생성 $CREATED / 기존 $EXISTED / 충돌 $CONFLICT / 건너뜀 $SKIPPED"
for p in "${!WT_MANUAL[@]}"; do
  [[ -n "${WT_MANUAL[$p]}" ]] && log "  후속(사람): [$p] ${WT_MANUAL[$p]}"
done
exit 0
