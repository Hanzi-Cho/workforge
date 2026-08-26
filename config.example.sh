# 이 파일을 config.sh 로 복사해서 값을 채운다.
#
#     cp config.example.sh config.sh
#
# config.sh 는 .gitignore 에 있다. 사내 정보(cloudId, accountId, 저장소 경로)가
# 들어가므로 절대 커밋하지 마라.
# shellcheck shell=bash

# ── Atlassian ───────────────────────────────────────────────────────────
# CLOUD_ID 찾는 법: Claude Code 에서 아래를 실행하면 id 가 나온다.
#     mcp__atlassian__getAccessibleAtlassianResources
# 또는 브라우저에서 https://<사이트>.atlassian.net/_edge/tenant_info
CLOUD_ID="${CLOUD_ID:-00000000-0000-0000-0000-000000000000}"
SITE_URL="${SITE_URL:-https://your-site.atlassian.net}"

# 담당자 accountId.
# 표시 이름("Hong Gildong")은 Jira 에 다른 언어로 등록돼 있으면 매칭이 깨진다.
# accountId 로 고정하라. 확인: mcp__atlassian__atlassianUserInfo
ASSIGNEE_ID="${ASSIGNEE_ID:-000000:00000000-0000-0000-0000-000000000000}"

# 완료된 이슈는 제외한다. 전체 이력을 원하면 비워라(수백 건이 된다).
STATUS_FILTER="${STATUS_FILTER:-AND statusCategory != Done}"

# 대상 프로젝트 키. 스캔은 **프로젝트별로 따로** 돈다.
#
# 왜 쪼개는가(실측): 이슈 59건을 한 세션에서 12페이지 긁게 했더니
# 에이전트가 빈 출력을 내고 죽었다. 그 전에는 2페이지에서 멈추고
# "전부 가져왔다"고 거짓 보고했다. 프로젝트당 3페이지 안쪽이면 안정적이고,
# 하나가 실패해도 나머지는 살아남는다.
#
# 담당 이슈가 많다면 실제로 코드 작업이 되는 프로젝트만 넣어라.
# VOC·주간보고성 프로젝트를 넣으면 비용만 늘고 쓸모 있는 산출물이 안 나온다.
PROJECTS="${PROJECTS:-PROJ}"

# ── 모델 / 예산 ─────────────────────────────────────────────────────────
# 실측(Sonnet 기준): 이슈 1건 심층 분석 ≈ $1, 프로젝트 1개 전수 수집 ≈ $0.5,
# 분류 24건 ≈ $0.25.
# 구독 요금제라면 이건 청구액이 아니라 rate limit 소모의 대리 지표다.
# 야간에 한도를 다 태우면 아침에 네가 쓸 몫이 없다.
MODEL_SCAN="${MODEL_SCAN:-sonnet}"
MODEL_CLASSIFY="${MODEL_CLASSIFY:-sonnet}"
MODEL_FILL="${MODEL_FILL:-sonnet}"      # 가장 비싼 단계

# 한 번의 실행에서 문서를 채울 이슈 최대 개수. 나머지는 다음 실행으로 넘어간다.
MAX_FILL_PER_RUN="${MAX_FILL_PER_RUN:-5}"

# 한 번의 실행에서 **본문까지** 상세 수집할 이슈 최대 개수.
# 스캔은 2단계다: (A) 키+updated 만 훑어 변경분을 가려내고 (B) 변경분만 본문 수집.
MAX_DETAIL_PER_RUN="${MAX_DETAIL_PER_RUN:-12}"

# 단계별 타임아웃(초)
TIMEOUT_SCAN="${TIMEOUT_SCAN:-600}"
TIMEOUT_CLASSIFY="${TIMEOUT_CLASSIFY:-420}"
TIMEOUT_FILL="${TIMEOUT_FILL:-900}"

# 주 1회 전수 대조를 돌릴 요일(1=월 … 7=일). 그 외 요일은 델타 스캔만 한다.
FULL_SCAN_DOW="${FULL_SCAN_DOW:-1}"

# ── 선택: 프로젝트 → 저장소 매핑 ────────────────────────────────────────
# 이 도구는 코드베이스에 독립적이다. 비워 두면 AI 는 Jira 본문만 보고
# 계획을 세운다("무엇을 해야 하는지" 수준).
# 매핑을 주면 실제 코드를 읽어 `파일:줄번호`까지 짚는다. 읽기 전용으로만 연다.
#
# 한 프로젝트에 여러 저장소를 공백으로 나열할 수 있다. 그렇게 하는 걸 권한다 —
# 이슈 제목이 가리키는 저장소와 실제 원인이 있는 저장소가 다른 경우가 흔하다.
# (실측: 프론트엔드 화면 이슈로 등록됐는데 원인의 절반이 백엔드 서비스에 있었다.
#  저장소 하나만 열어주면 "관련 코드 없음"이라는 오답이 나온다.)
#
# stale 한 사본은 넣지 마라. AI 가 옛 코드를 근거로 계획을 세운다.
declare -A REPO_MAP=(
  # [PROJ]="/path/to/frontend /path/to/backend /path/to/mobile"
)

# ── 릴리스 포커스 ───────────────────────────────────────────────────────
# "지금 진행 중인 릴리스" 를 코드가 판정한다. AI 를 쓰지 않는다(공짜·결정론적).
#
# 판정 규칙(bin/release-focus.sh):
#   1) **내 담당 미완료 이슈에 붙어 있는 Fix Version 만** 후보다.
#      Jira 의 전체 버전 목록을 훑지 않는다 — 남이 열어놓고 방치한 옛 버전이
#      섞인다(실측: 2022~2023 년에 열린 채 미릴리즈로 남은 버전이 여럿 있었다).
#   2) 이미 릴리스된 버전(released=true)은 제외한다.
#   3) 남은 후보를 **릴리스 라인**(버전 번호를 떼어낸 이름)으로 묶고,
#      라인별로 버전 번호가 가장 높은 하나만 활성으로 본다.
#        product-v0.0.7, product-v0.0.8  → 라인 "product", 활성 v0.0.8
#        [App] v2.0.9-rc5, [App] v2.4.1  → 라인 "[App]",   활성 v2.4.1
#
# Jira 에 다음 릴리스를 추가하면 그 다음 실행부터 자동으로 옮겨간다.
# 이 파일에 버전 번호를 적을 필요가 없다.
RELEASE_FOCUS="${RELEASE_FOCUS:-1}"

# ── 선택: 워크트리 자동 생성 ────────────────────────────────────────────
# 활성 릴리스의 이슈마다 `feature/<이슈키>` 브랜치와 워크트리를 미리 만들어 둔다.
# 아침에 이슈를 열자마자 그 디렉터리로 들어가 바로 작업할 수 있게 하는 것이 목적이다.
# WT_REPO 를 비워 두면 이 기능 전체가 꺼진다.
#
# 안전선(bin/make-worktree.sh 는 절대 하지 않는다):
#   - 기존 브랜치·워크트리·디렉터리 삭제나 덮어쓰기
#   - `git worktree prune`, `reset --hard`, `checkout -- .`
#   - fetch / push  (분기 기준은 로컬 브랜치다. 네트워크를 쓰지 않는다.)
WORKTREE_AUTO="${WORKTREE_AUTO:-1}"
BRANCH_PREFIX="${BRANCH_PREFIX:-feature/}"

# Windows(WSL) 에서 /mnt/<드라이브> 의 저장소를 다룰 때 쓸 git 실행 파일.
# WSL git 으로 쓰기 작업을 하면 CRLF 때문에 워킹트리가 깨진다 —
# 이유는 lib/common.sh 의 git_win() 주석에 실측과 함께 적어 두었다.
# 저장소가 리눅스 파일시스템에만 있으면 이 값은 쓰이지 않는다.
GIT_WIN="${GIT_WIN:-/mnt/c/Program Files/Git/cmd/git.exe}"

# product(분류 결과: launcher / fe / planner) → 저장소.
# 분류가 unknown 이면 만들지 않고 리포트에 "저장소 매핑 없음" 으로 남긴다.
declare -A WT_REPO=(
  # [launcher]="/path/to/launcher"
)
# 워크트리를 놓을 상위 디렉터리. `<root>/<이슈키>` 가 된다.
declare -A WT_ROOT=(
  # [launcher]="/path/to/launcher_wt"
)
# 분기 기준 브랜치(로컬).
declare -A WT_BASE=(
  # [launcher]="dev"
)
# gitignore 돼서 새 워크트리엔 없는데 빌드에 필요한 파일. 저장소 루트 기준 상대경로.
# 이걸 안 넣으면 워크트리에 들어가 빌드하는 순간 SDK 경로가 없다고 죽는다.
declare -A WT_SEED=(
  # [launcher]="android/local.properties .env"
)
# 사람이 직접 해야 하는 후속 작업. 리포트/로그에 그대로 실린다.
# 의존성 디렉터리(node_modules 등)는 복사하지 않는다 — 이슈마다 수 GB 를 복제하게 된다.
declare -A WT_MANUAL=(
  # [launcher]="npm ci"
)

# ── 경로 ────────────────────────────────────────────────────────────────
JIRA_DIR="${JIRA_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
BIN_DIR="$JIRA_DIR/bin"
LIB_DIR="$JIRA_DIR/lib"
PROMPT_DIR="$JIRA_DIR/prompts"
TPL_DIR="$JIRA_DIR/templates"
STATE_DIR="$JIRA_DIR/state"
LOG_DIR="$JIRA_DIR/logs"
PROJ_DIR="$JIRA_DIR/projects"

ISSUES_JSON="$STATE_DIR/issues.json"     # 정본. 사람이 손으로 고치지 않는다.
REPORT_DIR="$JIRA_DIR/reports"           # 생성물. reports/<날짜>.md 를 사람이 읽는다.
LAST_RUN="$STATE_DIR/last-run.json"
FOCUS_JSON="$STATE_DIR/release-focus.json"   # 생성물. 정본에서 매 실행 다시 계산한다.

# cron 은 PATH 가 최소다. claude / node 를 명시적으로 넣는다.
export PATH="$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
