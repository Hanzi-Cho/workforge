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
TABLE_MD="$JIRA_DIR/ISSUE_TABLE.md"      # 생성물. 사람이 읽는다.
LAST_RUN="$STATE_DIR/last-run.json"

# cron 은 PATH 가 최소다. claude / node 를 명시적으로 넣는다.
export PATH="$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
