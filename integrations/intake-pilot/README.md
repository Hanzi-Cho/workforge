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

`case_id`는 같은 업무를, `event_id`와 `revision`은 개별 이벤트의 버전을 가리킨다. 결과 키는 `event_id/revision/target/action`이다. 같은 입력을 새 실행에서 재생하면 같은 결과를 얻는다. 목적지를 연결할 때 실행 간 중복은 저장 영수증으로 대조한다.

## 개발과 검증

Node.js 22 이상에서 실행한다. 빌더는 스크립트의 라우팅 함수와 합성 입력을 n8n JSON에 넣는다.

```sh
node --test route.test.mjs
node build.mjs
```

가져온 뒤 예제 중 한 건의 채널, 기존 티켓 키, 필수 필드를 바꾸고 해당 끝 노드의 결과를 확인할 수 있다. n8n에서는 실제 업무 원문이 실행 이력에 저장될 수 있으므로 공유 예제에는 합성 자료를 사용한다.
