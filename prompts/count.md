`mcp__atlassian__searchJiraIssuesUsingJql` 를 **정확히 한 번** 호출한다.

- cloudId: `__CLOUD_ID__`
- jql: `__JQL__`
- fields: `["key"]`
- searchResultMode: `count`

응답의 `totalCount` 를 그대로 아래 형식으로 출력한다.

{"total": <숫자>}

다른 텍스트는 아무것도 출력하지 마라. 숫자를 추측하거나 계산하지 마라.
도구가 준 값을 그대로 옮겨라.
