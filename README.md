# jira-nightly

**자는 동안 Jira 이슈를 정리해 두는 도구.**

아침에 출근하면 내 담당 이슈가 표 하나로 정리돼 있고, 각 이슈마다
"이게 무슨 문제인지 / 어디를 고쳐야 하는지" 초안이 적힌 문서가 만들어져 있다.
사람은 그걸 **검토**한다. 쓰는 건 AI가 한다.

Claude Code + Jira MCP + cron. 그게 전부다. 서버도 클라우드도 필요 없다.

---

## 목차

1. [뭘 해주는 도구인가](#1-뭘-해주는-도구인가)
2. [전체 그림](#2-전체-그림)
3. [설치](#3-설치)
4. [처음 실행해보기](#4-처음-실행해보기)
5. [만들어지는 것들](#5-만들어지는-것들)
6. [동작 원리](#6-동작-원리)
7. [왜 이렇게 만들었나](#7-왜-이렇게-만들었나)
8. [비용](#8-비용)
9. [문제가 생기면](#9-문제가-생기면)
10. [한계](#10-한계)

---

## 1. 뭘 해주는 도구인가

Jira에 내 담당 이슈가 20개, 50개씩 쌓여 있다고 하자. 아침마다 하나씩 열어보고
"이게 뭐였더라", "이건 어느 코드지" 하는 데 30분이 날아간다.

이 도구는 그 30분을 새벽 6시에 대신 해둔다.

**Before** — Jira 웹에서 이슈 50개를 하나씩 클릭

**After** — 파일 두 종류만 보면 된다

```
reports/2026-08-19.md                       ← 오늘의 데일리 리포트 한 장
projects/PROJ/network-status/PROJ-123.md    ← 이슈별 분석 + 수정 계획
```

데일리 리포트는 **목록과 브리핑만** 담는다. 한 이슈가 한 줄이다.

```markdown
# 2026-08-19 Daily Report

## 신규 (2)
- [PROJ-131](https://.../PROJ-131) 로그인 후 토큰 갱신 실패 — `projects/PROJ/_inbox/PROJ-131.md`

## 변경 (1)
- [PROJ-123](https://.../PROJ-123) 네트워크 상태 미갱신 — 검토 → 종결 — `projects/PROJ/network-status/PROJ-123.md`

## 잔여 (22)
- [PROJ-118](https://.../PROJ-118) ...  — `projects/PROJ/launcher-infra/PROJ-118.md`

---
## 브리핑
- 리포트 생성 결함이 6건째다. 개별 대응 말고 원인을 한 번에 봐야 한다.
- EST 11건 전부 본문이 비어 있다. 분석보다 이슈 작성 요청이 먼저다.
```

원인 분석·수정 계획·진행 상황은 리포트가 아니라 **이슈 문서가 소유한다.**
리포트는 매일 새로 만들어지고, 이슈 문서는 **이슈마다 하나가 계속 누적된다.**

이슈 문서는 **이슈당 하나**이고 날마다 내용이 누적된다.

```markdown
# PROJ-123 제목

<!-- META -->      Jira 링크 · feature · 현재 상태      (스크립트 갱신)
## 상태 이력       날짜별 전이가 쌓인다                  (스크립트 추가)
## Jira 원문       원문 사본                            (스크립트 동기화)
## 이슈 해석 / 원인 분석 / 수정 계획 / 확인 필요        (AI, 사람이 고쳐도 유지)
## 진행            착수 후 진행 상황
## 체인지로그      이 문서에 무슨 일이 있었는지          (스크립트 추가)
## 사람 검토       내 메모. 절대 안 지워진다

Confidence: 0.8
Recommendation: READY_TO_IMPLEMENT
```

마지막 `Recommendation` 한 줄만 봐도 오늘 뭘 할지 정할 수 있다.

| 값 | 뜻 |
|---|---|
| `READY_TO_IMPLEMENT` | 계획이 섰다. 바로 구현 가능 |
| `NEEDS_DECISION` | 사람이 방향을 정해야 함 |
| `NEEDS_MORE_INFO` | Jira 본문이 부실함. 정보부터 채워야 함 |
| `NOT_ACTIONABLE` | 코드 작업이 아님 |

---

## 2. 전체 그림

```
                        ┌─────────────┐
                        │    Jira     │
                        └──────┬──────┘
                               │ (읽기만)
   새벽 6시, 월~금              ▼
   cron ──────────▶ nightly_scheduler.sh
                               │
      ┌────────────────────────┼────────────────────────┐
      ▼                        ▼                        ▼
  ① 스캔                   ③ 분류                   ⑤ 작성
  이슈 긁어오기            버그? 개선?              코멘트 + 수정계획
  [AI]                     어느 기능 묶음?          [AI · 제일 비쌈]
      │                    [AI]                         │
      │                        │                        │
      ▼                        ▼                        ▼
 state/issues.json  ──▶  ② 리포트    ──▶  ④ 문서 생성/이동
   (정본 = 진짜 데이터)      [코드]              [코드]
                               │                        │
                               ▼                        ▼
                  reports/<날짜>.md          projects/PROJ/<기능>/
                                                   ├── FEATURE.md
                                                   └── PROJ-123.md
                               │                        │
                               └───────────┬────────────┘
                                           ▼
                                    ☕ 출근한 사람
```

**[AI]** 표시가 돈이 드는 단계다. ②④는 순수 코드라 공짜다.

여기서 제일 중요한 규칙 하나:

> **`state/issues.json`이 진짜 데이터(정본)이고, 나머지는 전부 다시 만들 수 있는 사본이다.**

`reports/`를 지워도 `render-report.sh` 한 번이면 복구된다.
반대로 `state/issues.json`을 지우면 처음부터 다시 긁어야 한다.

---

## 3. 설치

### 필요한 것

| 항목 | 확인 방법 |
|---|---|
| Claude Code | `claude --version` |
| Jira MCP 연결 | `claude mcp list` → `atlassian ✔ Connected` |
| bash · python3 · cron | `which bash python3 crontab` |

WSL을 쓴다면 systemd가 켜져 있어야 cron이 돈다.

```bash
cat /etc/wsl.conf     # [boot] systemd=true 가 있어야 함
systemctl is-active cron
```

없으면 `/etc/wsl.conf`에 아래를 넣고 `wsl --shutdown` 후 재시작한다.

```ini
[boot]
systemd=true
```

### Jira MCP 연결

```bash
claude mcp add --transport http atlassian https://mcp.atlassian.com/v1/mcp/authv2
claude mcp login atlassian
```

> **TTY 없이 로그인이 안 될 때** (WSL에서 흔하다):
> ```bash
> setsid script -qec 'claude mcp login atlassian' /dev/null
> ```

### 설정 파일

```bash
git clone <이 저장소> jira-nightly && cd jira-nightly
cp config.example.sh config.sh
```

`config.sh`를 열어 4개만 채우면 된다. **이 파일은 `.gitignore`에 있다** —
사내 정보가 들어가므로 커밋되지 않는다.

```bash
CLOUD_ID="..."        # ① Atlassian 사이트 ID
SITE_URL="https://your-site.atlassian.net"
ASSIGNEE_ID="..."     # ② 내 accountId
PROJECTS="PROJ"       # ③ 대상 프로젝트 키 (공백으로 여러 개)
```

**① CLOUD_ID 찾기** — 브라우저에서 `https://<사이트>.atlassian.net/_edge/tenant_info`
접속하면 나온다. 또는 Claude Code에서 `getAccessibleAtlassianResources` 실행.

**② ASSIGNEE_ID 찾기** — Claude Code에서 `atlassianUserInfo` 실행.
`account_id` 값을 그대로 쓴다.

> 왜 이름이 아니라 ID인가? Jira에 등록된 표시 이름이 `Hong Gildong`이 아니라
> `홍길동`일 수 있다. 이름으로 JQL을 쓰면 조용히 0건이 나온다.

**③ (선택) 저장소 연결** — 이걸 설정하면 AI가 실제 코드를 읽고
`파일:줄번호`까지 짚어준다. 안 하면 "무엇을 해야 하는지" 수준의 일반론만 나온다.

```bash
declare -A REPO_MAP=(
  [PROJ]="/path/to/frontend /path/to/backend"
)
```

> 저장소는 **여러 개 넣는 걸 권한다.** 이슈 제목이 가리키는 곳과
> 진짜 원인이 있는 곳이 다른 경우가 많다. 실제로 "프론트엔드 화면 버그"로
> 등록된 이슈의 원인 절반이 백엔드에 있던 적이 있다.
> 저장소 하나만 열어주면 "관련 코드 없음"이라는 오답이 나온다.

---

## 4. 처음 실행해보기

**순서대로** 해보는 걸 권한다. 처음부터 전체를 돌리면 어디서 틀렸는지 모른다.

### 1단계 — 리포트만 만들어보기 (싸다)

```bash
./bin/nightly_scheduler.sh --full --scan-only
```

`reports/<날짜>.md`가 생긴다. AI 작성 단계는 건너뛰므로 프로젝트당 $0.5 정도.

리포트를 열어보고 **본문 없는 이슈가 얼마나 되는지 확인**하라. 이게 이 도구의
성패를 가른다 ([10. 한계](#10-한계) 참고).

### 2단계 — 문서까지 만들기

```bash
./bin/nightly_scheduler.sh --full
```

분류 → 폴더 생성 → AI 작성(최대 5건)까지 간다.

### 3단계 — 특정 이슈만 다시

```bash
./bin/fill-issue-doc.sh PROJ-123
FORCE=1 ./bin/fill-issue-doc.sh PROJ-123    # 이미 쓴 것도 덮어쓰기
```

### 4단계 — cron 등록

```bash
./bin/install-cron.sh          # 월~금 06:00
./bin/install-cron.sh --show   # 확인
./bin/install-cron.sh --remove # 해제
```

### Windows 절전 방지 설정

노트북을 잠그거나 덮개를 닫은 상태에서도 백그라운드 작업이 계속 실행되도록 설정한다.

**1. 덮개를 닫아도 실행 유지**

```
제어판 → 전원 옵션 → 덮개를 닫으면 수행되는 작업 선택
  전원 사용 → 아무 것도 안 함
```

**2. 자동 절전 / 최대 절전 비활성화**

```
전원 옵션 → 고급 전원 관리 옵션 설정 → 절전
  다음 시간 후 절전 모드로 전환      → 전원 사용 → 사용 안 함
  다음 시간 이후 최대 절전 모드로 전환 → 전원 사용 → 사용 안 함
```

> 화면 꺼짐과 `Win + L` 화면 잠금은 백그라운드 프로세스 실행에 영향을 주지 않는다.
> 노트북은 전원에 연결해 두어야 한다.

**3. Windows 재부팅 대비**

재부팅 후에는 아무도 WSL을 깨우지 않으면 인스턴스가 뜨지 않고, 따라서 cron도 없다.
작업 스케줄러에 **로그온 시 트리거**로 아래를 등록해두면 확실하다.

```
프로그램: wsl.exe
인수    : -d Ubuntu -- true
```

---

## 5. 만들어지는 것들

```
jira-nightly/
├── config.sh            ← 내가 고치는 유일한 파일 (gitignore)
├── bin/                 ← 스크립트 7개
├── lib/                 ← 공통 함수
├── prompts/             ← AI 지시문 5개
├── templates/           ← 문서 골격 2개
│
├── state/         [기계] ★ issues.json = 정본. 사람이 안 봄
├── projects/      [사람] ★ 이슈 문서. 이슈당 하나, 계속 누적된다
├── reports/       [사람] ★ <날짜>.md — 아침에 여는 파일
└── logs/          [기계]
```

**지워도 되는 것 / 안 되는 것**

| | 지워도 됨? | 이유 |
|---|:-:|---|
| `state/.*` (점 파일) | ○ | 중간 산출물 |
| `state/issues.json` | △ | 지우면 전수 재수집 |
| `logs/` | ○ | 로그일 뿐 |
| `projects/` | **✗** | **내가 쓴 검토 메모가 들어있다** |
| `reports/` | ○ | `render-report.sh`로 복구 |

### 스크립트 한 줄 설명

| 파일 | 역할 | AI |
|---|---|:-:|
| `nightly_scheduler.sh` | **진입점.** 5단계를 순서대로 실행 | |
| `scan-issues.sh` | Jira 조회 → 정본 병합 | ● |
| `render-report.sh` | 정본 → `reports/<날짜>.md` + 브리핑 | ◐ |
| `classify-issues.sh` | 버그/개선 판정 + 기능 묶음 | ● |
| `make-feature.sh` | 문서 생성·**이동**(이슈당 1개 보장)·블록 보강 | |
| `fill-issue-doc.sh` | 코멘트·수정계획 작성 (제일 비쌈) | ● |
| `install-cron.sh` | cron 등록/해제 | |

각 스크립트는 **단독으로 실행 가능**하다. 어디서 실패하면 그 단계만 다시 돌리면 된다.

### 이슈 문서의 구조

```markdown
# PROJ-123 제목

<!-- META:BEGIN  --> 스크립트가 갱신 (손대지 말 것)
<!-- SOURCE:BEGIN--> Jira 원문 복사본 (손대지 말 것)

<!-- AI:BEGIN -->
## 이슈 해석 / 코멘트 / 수정 계획 / 확인 필요
   ↑ AI가 쓰는 영역. 다시 돌리면 이 블록만 교체된다
<!-- AI:END -->

## 사람 검토          ← 여기에 쓴 건 절대 안 지워진다
- [ ] 수정 계획 승인
- 검토 메모:
```

블록이 나뉘어 있어서 **AI가 다시 써도 내 메모는 살아남는다.**

---

## 6. 동작 원리

### 델타 스캔 — 매일 전부 다시 읽지 않는다

```
월요일  →  전수 스캔 (담당 이슈 전부)      유실 대조용
화~금   →  델타 스캔 (마지막 실행 이후 바뀐 것만)
```

델타의 기준은 `state/last-run.json`의 `last_success`다. JQL에 이 조건이 붙는다.

```sql
updated >= "2026-08-18 06:00"
```

보통 0~3건이라 거의 공짜다.

> **`last_success`는 성공했을 때만 갱신된다.** 오늘 실패하면 내일이
> 어제 시점부터 다시 긁으므로 유실이 안 생긴다.

### 변경 판별은 코드가 한다

"뭐가 새로 생겼지?"를 AI에게 물으면 비싸고 틀린다.
`updated` 타임스탬프 비교는 결정론적이고 공짜다.

```
정본의 updated  vs  방금 긁은 updated
    다르면 → 변경됨
    없으면 → 신규
```

AI는 **판단(분류)과 글쓰기**만 한다.

### AI의 작업량을 코드가 검증한다

이게 이 도구의 핵심 안전장치다.

```
① count 조회  →  "이 조건에 13건 있음"      (별도 호출, $0.08)
② 수집        →  AI가 페이징하며 긁어옴
③ 검증        →  긁어온 게 13건 맞나?
                     아니면 → 즉시 실패, 정본 안 건드림
```

왜 필요하냐면 — **AI가 10건만 가져오고 "전부 가져왔습니다"라고 보고한 적이 있다.**
그대로 넘어갔으면 나머지 49건이 "담당에서 빠짐"으로 처리돼 표에서 조용히 사라졌을 것이다.

### 프로젝트별로 쪼개서 돈다

한 세션에서 12페이지를 긁게 했더니 AI가 빈 출력을 내고 죽었다.
프로젝트마다 **별도 세션**으로 돌리면 각각 3페이지 안쪽이라 안정적이고,
하나가 실패해도 나머지는 살아남는다.

```
PROJECTS="FRONT BACK MOBILE"
   │
   ├── FRONT  세션1 → count → 수집 → 검증 ✓
   ├── BACK   세션2 → count → 수집 → 검증 ✗ (이 프로젝트만 제외)
   └── MOBILE 세션3 → count → 수집 → 검증 ✓
                                  │
                          FRONT + MOBILE 만 정본에 반영
```

### AI는 파일을 쓰지 않는다

AI는 **stdout으로만** 출력하고, 파일 쓰기는 전부 bash/python이 한다.
그래서 AI를 `Write`·`Edit`·`Bash`까지 차단한 **진짜 읽기 전용**으로 돌릴 수 있다.

이유는 [7번](#7-왜-이렇게-만들었나)에.

---

## 7. 왜 이렇게 만들었나

전부 **실제로 돌려보다가 데인 것**들이다. 문서만 읽어선 안 나온다.

### `--allowedTools`는 샌드박스가 아니다

```bash
claude -p "uname -a 실행해줘" --allowedTools "Read"
# → Bash가 그대로 실행됨. 거부 0건.
```

`--allowedTools`는 **허용을 부여**하는 것이지 나머지를 막는 게 아니다.
기존 `settings.json`의 허용 규칙이 그대로 살아있다.

### 도구를 막아도 능력은 안 막힌다

```bash
claude -p "파일 만들어줘" --disallowedTools "Write"
# → "Write가 비활성화되어 있어서 대신 Bash로 만들었다"  (파일 생성됨)
```

**`Write`를 막으니 `Bash`로 우회했다.** 그래서 읽기 전용이 필요하면
`Bash`까지 막아야 한다. 그리고 그렇게 하려면 AI가 파일을 쓸 일이 없어야 한다.
→ *AI는 stdout만, 쓰기는 셸이* 라는 규칙이 여기서 나왔다.

### headless에서 MCP 도구는 기본 거부다

첫 실행이 "0건 수집"으로 조용히 끝났다. 로그를 까보니:

```json
"permission_denials": [{"tool_name": "mcp__atlassian__searchJiraIssuesUsingJql"}]
```

TTY가 없으니 자동 거부됐고, **AI는 그걸 숨기고 "0건"이라고 태연히 보고했다.**
아침에 "오늘은 이슈가 없네"로 오해하는 게 최악이므로,
`permission_denials`가 비어있지 않으면 **즉시 죽는다.**

MCP 도구는 `--allowedTools`에 명시해야 한다.

### bash 프로세스 치환은 실패를 전파하지 않는다

```bash
mapfile -t RESULT < <(./scan.sh)    # scan.sh 가 죽어도 여기는 성공으로 보인다
```

스캔이 실패했는데 파이프라인이 다음 단계로 계속 갔다. 이렇게 고쳤다.

```bash
./scan.sh > "$TMP" || die "스캔 실패 — 이후 단계 중단"
mapfile -t RESULT < "$TMP"
```

### 마크다운 표를 데이터로 쓰지 않는다

처음엔 마크다운 표를 정본으로 두려 했다. 문제:

- 한 칸 바뀐 걸 확인하려면 표 전체를 diff해야 한다
- AI가 표를 다시 쓰다가 기존 행을 날려도 알 수 없다

→ **JSON을 정본, 마크다운을 생성물로.** 사람은 md를 읽고 스크립트는 json을 읽는다.

### 이슈 문서는 이슈당 하나만 존재한다

재분류로 feature가 바뀌면 새 경로에 만들지 않고 **옮긴다**.
초기 구현은 새로 만들고 옛 파일을 남겨 같은 이슈의 문서가 둘이 됐다.
여러 날에 걸쳐 실행되는 도구에서 이건 곧 문서 신뢰도 붕괴로 이어진다.

### Jira MCP는 페이지당 5건만 준다

`maxResults: 100`을 줘도 무시한다. 다만 이건 고정값이 아니라
**응답 크기 제한**이다. `fields`를 줄이면 한 페이지에 10건 이상 온다.

---

## 8. 비용

Sonnet 기준 실측이다.

| 단계 | 비용 |
|---|---|
| count 조회 (프로젝트당) | $0.08 |
| 전수 수집 (프로젝트당) | $0.4 ~ 0.6 |
| 분류 (24건 한 번에) | $0.25 |
| **문서 작성 (이슈 1건)** | **$0.5 ~ 1.0** |

**작성 단계가 압도적으로 비싸다.** 그래서:

- `MAX_FILL_PER_RUN`(기본 5)으로 하루 작성량을 묶는다
- 분류 결과를 캐시해 같은 이슈를 두 번 판정하지 않는다
- 매일 전수 스캔하지 않는다 (델타 + 주 1회 전수)

> **구독 요금제(Pro/Max)를 쓴다면 이 `$` 숫자는 청구액이 아니다.**
> API 키가 아니라 OAuth 로그인이면 별도 과금이 없고, 대신
> **rate limit(5시간 롤링 윈도우 + 주간 한도)**을 소모한다.
> 즉 이 숫자는 "한도를 얼마나 태웠나"의 대리 지표로 읽으면 된다.
>
> 확인: `echo $ANTHROPIC_API_KEY` 가 비어 있으면 구독 인증이다.
>
> **야간에 한도를 다 태우면 아침에 내가 쓸 몫이 없다.** 상한을 올릴 때 기억할 것.

---

## 9. 문제가 생기면

### 제일 흔한 원인: Jira 세션 만료

```bash
claude mcp list                                              # ✔ Connected 인지
setsid script -qec 'claude mcp login atlassian' /dev/null    # 재로그인
```

### 로그 보기

```bash
tail -f logs/$(date +%F).log     # 수동 실행
tail -f logs/cron.log            # cron 실행
cat state/last-run.json          # last_failure 에 실패 단계가 남는다
```

### 실패한 AI 호출 뜯어보기

```bash
ls state/.failed.*               # 진단용으로 지우지 않고 남긴다
```

### 자주 만나는 에러

| 증상 | 원인 | 조치 |
|---|---|---|
| `config.sh 가 없다` | 설정 안 함 | `cp config.example.sh config.sh` |
| `도구가 거부됐다: mcp__...` | MCP 미허용 | `lib/common.sh`의 `JIRA_TOOLS`에 추가 |
| `수집 누락 10/59건` | AI 페이징 중단 | 재실행. 반복되면 `PROJECTS`를 더 잘게 |
| `다른 실행이 진행 중이다` | lock 잔존 | `rm state/.lock` |
| cron이 안 돎 | 절전 / WSL 미기동 | [4단계](#4단계--cron-등록) 참고 |

---

## 10. 한계

**솔직하게 — 이 도구의 성능은 Jira 본문 품질에 종속된다.**

실제 배포 환경에서 측정했을 때 대상 이슈의 **약 75%가 `description`이 비어 있었다.**
제목 한 줄로는 AI가 할 수 있는 게 없다.

```
본문 있음  →  쓸 만한 수정 계획이 나온다
본문 없음  →  "Jira에 이런 걸 채워달라" 목록만 나온다
```

브리핑이 이걸 매일 첫 줄에서 지적하게 해뒀다.
거기 걸린 이슈는 AI를 더 돌릴 게 아니라 **Jira를 채워야 한다.**

> AI 자동화를 붙이기 전에 이슈 본문부터 채우는 게 대부분 더 남는 장사다.
> 이 도구의 첫 수확은 "구현된 PR"이 아니라 "정보가 부족한 이슈 목록"일 가능성이 높다.

그 외:

- **첨부파일을 못 읽는다.** 정보가 스크린샷·동영상·로그 파일에만 있으면 손을 못 댄다.
- **Jira에 아무것도 쓰지 않는다.** 코멘트 등록·상태 전이 없음. 전부 로컬 파일로만.
- **코드를 고치지 않는다.** 분석과 계획까지다. 구현은 사람이(또는 다음 단계에서).
- **완료된 이슈는 제외한다.** `STATUS_FILTER`로 바꿀 수 있지만 수백 건이 된다.

---

## 라이선스

MIT
