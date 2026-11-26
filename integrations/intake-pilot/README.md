# n8n 업무 이벤트 라우터

문의 접수, 검증 완료, 사람의 검토, 일일 정리를 같은 입력 계약으로 받아 목적지별 초안을 만든다. 로컬 n8n에서 `n8n-workflow.json`을 **Import from File**로 열고 수동 실행한다. 예제는 합성 데이터 11건이다.

| 이벤트 | 규칙과 출력 |
| --- | --- |
| `issue.received` | 재현 정보 7개를 확인한다. `channel`은 `jira`, `email`, `phone`, `in_person` 중 하나다. 기존 Jira 건은 `issue_key`로 보완 초안을 만든다. 메일·전화·대면에서도 키가 이미 있으면 그 건에 연결한다. Jira에서 왔는데 키가 없으면 보완을 요청한다. 예전 형식은 채널을 생략할 수 있다. |
| `work.completed` | 검증 참조와 대상 버전을 Hookboard 근거 후보로 돌려준다. 학습 근거가 있으면 TIL 비공개 후보를 함께 만든다. |
| `review.decided` | 대상 버전과 사람의 검토 참조를 받아 승인 근거 또는 수정 요청을 반환한다. |
| `workday.closed` | `work_date`와 1~100개의 작업 행을 입력하면 순서를 보존해 Confluence 업무일지 초안을 만든다. 각 행에는 `case_id, work, result, evidence_ref, next_step`이 필요하다. |
| 공통 | 필수값이 비면 보완 목록을 반환한다. 형식 오류와 배치 안의 동일 이벤트·버전 충돌은 차단한다. 배치 안의 동일 입력은 중복으로 표시한다. |

수동 트리거 → 이벤트 입력 → Code 노드의 `routeBatch` → `action`별 Switch → 10개 끝 노드 순서로 실행된다. 끝 노드의 Output에서 `work.route.v1`을 확인할 수 있다. 모든 끝 노드는 No Operation이며 외부 서비스 쓰기나 일정 실행을 수행하지 않는다. Jira 저장, 일지 게시, Hookboard 승인자·버전 대조, TIL 게시 검토는 목적지 연결 시 별도로 수행한다. 입력 분류는 `synthetic` 또는 `personal`이며 회사 자료는 합성 예제와 분리해 관리한다.

`case_id`는 같은 업무를, `event_id`와 `revision`은 개별 이벤트의 버전을 가리킨다. 결과 키는 `event_id/revision/target/action`이다. 같은 입력을 새 실행에서 재생하면 같은 결과를 얻는다. TIL 비공개 후보를 연결하면 실행 간 중복은 목적지의 저장 영수증과 파일 내용으로 대조한다.

## 개발과 검증

Node.js 22 이상에서 실행한다. 빌더는 스크립트의 라우팅 함수와 합성 입력을 n8n JSON에 넣는다.

```sh
node --test route.test.mjs
node build.mjs
```

가져온 뒤 예제 중 한 건의 채널, 기존 티켓 키, 필수 필드를 바꾸고 해당 끝 노드의 결과를 확인할 수 있다. n8n에서는 실제 업무 원문이 실행 이력에 저장될 수 있으므로 공유 예제에는 합성 자료를 사용한다.

## 출력 확인과 재시도

Linux 또는 WSL에서 Python 3.10 이상, Node.js, n8n CLI를 사용한다. 아래 명령은 이 디렉터리에서 실행한다. 검증 환경은 Node.js 24.22.3과 n8n 2.48.8이다.

```sh
python3 replay.py --out "$HOME/agentasm-review"
```

실행할 때마다 임시 n8n 인스턴스에 워크플로를 가져와 예제를 재생한다. 라우터의 결과와 Switch 끝 노드의 실제 출력을 대조한 뒤 `review.html`과 `drafts.json`을 지정한 디렉터리에 만든다. 기본 예제 11건은 10종의 분기로 출력 12건을 만든다. 검증 완료 1건에서 Hookboard 근거와 TIL 학습 후보가 함께 나오기 때문이다. 다른 입력 배열은 `--events /path/to/events.json`, 별도로 설치한 n8n은 `--n8n /path/to/n8n`으로 지정한다. 개인 자료를 재생할 때는 비공개 출력 경로를 사용한다.

| 목적지 | 검토할 내용 |
| --- | --- |
| Jira | 신규 이슈는 제목과 ADF 본문을, 기존 키가 있으면 해당 이슈에 추가할 ADF 댓글을 만든다. 실제 신규 등록에는 대상 프로젝트와 이슈 유형이 필요하다. [Jira 이슈 API](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issues/) · [Jira 댓글 API](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issue-comments/) |
| Confluence | 일지 제목과 입력 순서를 보존한 표를 `storage` 본문으로 만든다. 실제 게시는 공간, 대상 페이지, 갱신 버전의 연결이 필요하다. [Confluence 페이지 API](https://developer.atlassian.com/cloud/confluence/rest/v2/api-group-page/) |
| Hookboard | 검증 근거, 산출물 버전, 사람의 검토 참조를 표시한다. 게이트 상태 변경은 Hookboard의 승인 처리에 속한다. |
| TIL | 기본 실행은 학습 후보를 표시한다. 합성 후보의 실제 비공개 저장과 재조회를 시험하려면 아래 옵션을 지정한다. |
| 로컬 | 누락된 필드, 차단 사유, 같은 배치 안의 중복을 표시한다. |

### TIL 비공개 후보 저장 검증

`scripts/daily_pipeline.py import-agent-draft`를 지원하는 로컬 TIL 체크아웃이 필요하다. 통합 검증에는 해당 가져오기 명령이 있는 리비전 `7978e6e`를 사용했다.

```sh
python3 replay.py --out "$HOME/agentasm-review" --til-root /path/to/til --date 2026-11-26
```

합성 후보는 체크아웃의 `.til-state/<날짜>/agent-drafts/`에 저장된다. 생성한 파일을 다시 읽고 내용이 일치하면 영수증에 확인 상태를 남긴다. 동일 키를 재시도할 때는 처음 지정한 날짜를 사용한다. 개인 후보는 검토 대기로 표시한다. 같은 키로 내용이 바뀌거나 저장된 파일이 달라지면 해당 항목을 실패로 표시한다. 다른 초안은 검토 파일에 남으며 프로세스는 종료 코드 1을 반환한다. 실제 변경을 다시 제출할 때는 이벤트 버전을 올린다.

```sh
python3 -m unittest -v test_product
```
