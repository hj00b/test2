# GitLab Webhook 설정 가이드

## 목차
1. [개요](#개요)
2. [사전 요구사항](#사전-요구사항)
3. [Webhook 작동 원리](#webhook-작동-원리)
4. [설정 방법](#설정-방법)
5. [Jenkins 설정](#jenkins-설정)
6. [테스트 및 검증](#테스트-및-검증)
7. [트러블슈팅](#트러블슈팅)

---

## 개요

GitLab Webhook을 사용하면 코드가 푸시될 때 자동으로 Jenkins 빌드를 트리거할 수 있습니다.

### 작동 흐름

```
┌─────────┐         ┌─────────┐         ┌─────────┐
│ GitLab  │ Webhook │ Jenkins │ Deploy  │ Docker  │
│         ├────────>│         ├────────>│         │
│ Push    │         │ Build   │         │ Compose │
└─────────┘         └─────────┘         └─────────┘

1. 개발자가 GitLab에 코드 푸시
2. GitLab이 Webhook으로 Jenkins에 이벤트 전송
3. Jenkins가 Generic Webhook Trigger로 빌드 시작
4. 빌드 완료 후 Docker Compose로 배포
5. Blue-Green 전환 (선택적)
```

### 주요 기능

- ✅ **자동 CI/CD**: Push 시 자동 빌드 & 배포
- ✅ **브랜치별 배포**: master → 운영, dev → 개발
- ✅ **Merge Request 검증**: PR 시 자동 테스트
- ✅ **Tag 릴리즈**: Tag push 시 릴리즈 빌드
- ✅ **상태 피드백**: Jenkins 빌드 결과를 GitLab에 표시

---

## 사전 요구사항

### 1. GitLab 설정

**Personal Access Token 생성:**
```
GitLab > User Settings > Access Tokens

Token name: jenkins-integration
Scopes:
  ✓ api
  ✓ read_repository
  ✓ write_repository

생성 후 토큰 복사 (한 번만 표시됨)
```

**Outbound Requests 허용 (GitLab Admin):**
```
GitLab Admin Area > Settings > Network > Outbound requests
✓ Allow requests to the local network from webhooks and integrations
```

### 2. Jenkins 설정

**필수 플러그인:**
- Generic Webhook Trigger Plugin
- GitLab Plugin (선택사항)
- Credentials Plugin

**플러그인 설치 확인:**
```bash
# jenkins/plugins.txt에 포함되어 있음
generic-webhook-trigger:latest
gitlab-plugin:latest
```

### 3. Webhook Secret Token 생성

```bash
# Secure Random Token 생성
openssl rand -hex 32

# 출력 예시:
# 3f7a8b9c1d2e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9
```

이 토큰을 GitLab과 Jenkins 양쪽에 설정합니다.

---

## Webhook 작동 원리

### GitLab Webhook Payload

GitLab이 Push 이벤트 발생 시 Jenkins로 전송하는 JSON 데이터:

```json
{
  "object_kind": "push",
  "event_name": "push",
  "ref": "refs/heads/master",
  "checkout_sha": "abc123def456",
  "user_name": "John Doe",
  "user_email": "john@example.com",
  "project": {
    "id": 123,
    "name": "my-project",
    "web_url": "https://gitlab.example.com/group/my-project"
  },
  "commits": [
    {
      "id": "abc123def456",
      "message": "feat: Add new feature",
      "timestamp": "2025-10-27T10:00:00+00:00",
      "author": {
        "name": "John Doe",
        "email": "john@example.com"
      }
    }
  ],
  "total_commits_count": 1
}
```

### Jenkins Generic Webhook Trigger

Jenkins가 Webhook Payload에서 추출하는 변수:

| 변수 | JSONPath | 설명 |
|------|----------|------|
| `GIT_BRANCH` | `$.ref` | 브랜치 (refs/heads/ 제거) |
| `GIT_COMMIT` | `$.checkout_sha` | Commit SHA |
| `PROJECT_NAME` | `$.project.name` | 프로젝트 이름 |
| `USER_NAME` | `$.user_name` | 커밋한 사용자 |
| `COMMIT_MESSAGE` | `$.commits[0].message` | 커밋 메시지 |
| `EVENT_TYPE` | `$.object_kind` | 이벤트 타입 |

---

## 설정 방법

### 방법 1: 자동화 스크립트 사용 (권장)

**1. Webhook Secret Token 생성:**
```bash
# Token 생성
WEBHOOK_SECRET=$(openssl rand -hex 32)
echo "Webhook Secret: $WEBHOOK_SECRET"

# Jenkins Credentials에 저장 필요
```

**2. GitLab Personal Access Token 준비:**
```bash
# GitLab에서 생성한 토큰
GITLAB_TOKEN="glpat-xxxxxxxxxxxxx"
```

**3. 자동 설정 스크립트 실행:**
```bash
cd gitlab/scripts
chmod +x setup-webhook.sh

# 사용법:
# ./setup-webhook.sh <gitlab-url> <project-id> <gitlab-token> <jenkins-url> <webhook-secret>

# 예시:
./setup-webhook.sh \
  https://gitlab.example.com \
  123 \
  glpat-xxxxxxxxxxxxx \
  https://jenkins.example.com/generic-webhook-trigger/invoke \
  $WEBHOOK_SECRET
```

**4. 스크립트 실행 결과:**
```
========================================
GitLab Webhook Setup
========================================

GitLab URL: https://gitlab.example.com
Project ID: 123
Jenkins URL: https://jenkins.example.com/generic-webhook-trigger/invoke

Step 1: Checking existing webhooks...
Step 2: Creating new webhook...
✓ Webhook created successfully!
Webhook ID: 456

Step 3: Testing webhook...
✓ Test successful

========================================
Webhook Setup Complete!
========================================

Webhook Details:
  - ID: 456
  - URL: https://jenkins.example.com/generic-webhook-trigger/invoke
  - Triggers: Push (master, dev), Tag Push, Merge Requests

Next Steps:
1. Configure Jenkins job to use Generic Webhook Trigger
2. Set the same secret token in Jenkins credentials
3. Push to master or dev branch to test the integration
```

### 방법 2: GitLab UI에서 수동 설정

**1. GitLab 프로젝트로 이동:**
```
Settings > Webhooks
```

**2. Webhook 정보 입력:**
```
URL: https://jenkins.example.com/generic-webhook-trigger/invoke

Secret Token: (생성한 Webhook Secret 입력)

Trigger:
  ✓ Push events
    Branch filter: master,dev
  ✓ Tag push events
  ✓ Merge request events

SSL verification:
  ✓ Enable SSL verification

Add webhook 클릭
```

**3. Webhook 테스트:**
```
Recent Deliveries 섹션에서:
  Test > Push events 클릭

응답 확인:
  HTTP 200 OK → 성공
  HTTP 401 Unauthorized → Secret Token 불일치
  HTTP 404 Not Found → Jenkins URL 오류
```

---

## Jenkins 설정

### 방법 1: Jenkins UI에서 설정

**1. Jenkins Credentials 추가:**
```
Jenkins > Manage Jenkins > Credentials > Global

Add Credentials:
  Kind: Secret text
  Secret: (Webhook Secret Token 입력)
  ID: gitlab-webhook-secret
  Description: GitLab Webhook Secret Token
```

**2. Pipeline Job 생성:**
```
New Item > Pipeline > OK

이름: backend-deployment-webhook
```

**3. Generic Webhook Trigger 설정:**
```
Build Triggers 섹션:
  ✓ Generic Webhook Trigger

Generic Variables:
  Variable: GIT_BRANCH
  Expression: $.ref
  Expression Type: JSONPath
  RegexFilter: refs/heads/

  Variable: GIT_COMMIT
  Expression: $.checkout_sha
  Expression Type: JSONPath

  (나머지 변수도 동일하게 추가)

Token:
  token-gitlab-webhook-secret (Credentials에서 선택)

Optional Filter:
  Text: $GIT_BRANCH
  Expression: ^(master|dev)$

Print contributed variables: ✓
Print post content: (체크 안 함)
```

**4. Pipeline Script 설정:**
```groovy
Pipeline:
  Definition: Pipeline script from SCM

SCM: Git
  Repository URL: https://gitlab.example.com/group/project.git
  Credentials: gitlab-credentials
  Branches to build: ${GIT_BRANCH}

Script Path: jenkins/pipelines/Jenkinsfile.backend
```

### 방법 2: Job DSL 사용 (자동화)

**1. Job DSL Plugin 설치:**
```
Jenkins > Manage Jenkins > Plugins
검색: Job DSL
설치
```

**2. Seed Job 생성:**
```
New Item > Freestyle project > OK

이름: seed-job-dsl

Build:
  Process Job DSLs
    Look on Filesystem
    DSL Scripts: jenkins/job-configs/webhook-job-dsl.groovy

Save
```

**3. Seed Job 실행:**
```
Build Now 클릭

생성된 Job 확인:
  - backend-deployment-webhook
  - frontend-deployment-webhook
  - project-multibranch (선택사항)
```

### Jenkins에서 Webhook URL 확인

**Generic Webhook Trigger URL 형식:**
```
https://jenkins.example.com/generic-webhook-trigger/invoke

또는 특정 Job 트리거:
https://jenkins.example.com/generic-webhook-trigger/invoke?token=YOUR_TOKEN
```

**Multi-branch Pipeline Webhook:**
```
https://jenkins.example.com/project/YOUR_PROJECT
```

---

## 테스트 및 검증

### 1. Webhook 연결 테스트

**GitLab에서 테스트:**
```
GitLab > Project > Settings > Webhooks
Recent Deliveries 섹션:
  Test > Push events

확인:
  Response: HTTP 200 OK
  Response Body: (Jenkins 응답 확인)
```

**Jenkins에서 확인:**
```
Jenkins > Job > Build History
  최근 빌드가 트리거되었는지 확인
  Build Cause: "Triggered by GitLab: ..."
```

### 2. 실제 Push 테스트

**Master 브랜치 푸시:**
```bash
git checkout master
echo "test" >> test.txt
git add test.txt
git commit -m "test: Webhook trigger test"
git push origin master
```

**Jenkins 자동 빌드 확인:**
```
1. Jenkins에서 빌드 자동 시작
2. Console Output 확인:
   - GIT_BRANCH=master
   - GIT_COMMIT=abc123
   - DEPLOY_ENV=prod
3. 배포 프로세스 진행
4. GitLab Commit에 빌드 상태 표시
```

### 3. Dev 브랜치 테스트

```bash
git checkout dev
echo "test" >> test.txt
git add test.txt
git commit -m "test: Dev webhook test"
git push origin dev
```

**예상 결과:**
- Jenkins 빌드 자동 시작
- DEPLOY_ENV=dev
- 개발 환경에 배포

### 4. Feature 브랜치 테스트 (빌드 안 됨)

```bash
git checkout -b feature/test
git push origin feature/test
```

**예상 결과:**
- Jenkins 빌드 **시작 안 됨**
- Reason: Regexp Filter (master|dev만 허용)

---

## 트러블슈팅

### 1. Webhook이 트리거되지 않음

**증상:**
```
GitLab에서 Push했지만 Jenkins 빌드가 시작되지 않음
```

**해결 방법:**

**A. GitLab Webhook 로그 확인:**
```
GitLab > Project > Settings > Webhooks
Recent Deliveries:
  Request headers, Request body, Response 확인
```

**B. Jenkins URL 접근 가능 여부 확인:**
```bash
# GitLab 서버에서 Jenkins URL 테스트
curl -I https://jenkins.example.com/generic-webhook-trigger/invoke

# 예상 응답: HTTP 200 OK 또는 403 Forbidden (정상)
```

**C. 방화벽 확인:**
```bash
# Jenkins 서버에서 포트 열림 확인
sudo ufw status
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

**D. GitLab Outbound Requests 설정:**
```
GitLab Admin Area > Settings > Network
✓ Allow requests to the local network from webhooks and integrations
```

### 2. 401 Unauthorized 에러

**증상:**
```
GitLab Webhook Test:
  Response: 401 Unauthorized
```

**해결 방법:**

**A. Secret Token 일치 확인:**
```
GitLab Webhook Secret Token
  ===
Jenkins Credentials > gitlab-webhook-secret
```

**B. Jenkins Credentials 재설정:**
```
Jenkins > Manage Jenkins > Credentials
  gitlab-webhook-secret 삭제 후 재생성
```

**C. Webhook URL에 Token 포함 (임시 해결):**
```
URL: https://jenkins.example.com/generic-webhook-trigger/invoke?token=YOUR_SECRET
```

### 3. Jenkins 빌드는 시작되지만 변수가 없음

**증상:**
```
Console Output:
  GIT_BRANCH = null
  GIT_COMMIT = null
```

**해결 방법:**

**A. Generic Webhook Trigger 설정 확인:**
```
Jenkins Job Configuration:
  Build Triggers > Generic Webhook Trigger
  Generic Variables에 모든 변수가 올바르게 설정되었는지 확인
```

**B. JSONPath 표현식 테스트:**
```
GitLab Webhook Payload를 복사해서
https://jsonpath.com/에서 테스트

예시:
  JSONPath: $.ref
  Result: refs/heads/master
```

**C. Print contributed variables 활성화:**
```
Generic Webhook Trigger 설정:
  ✓ Print contributed variables
  ✓ Print post content

Console Output에서 실제 Payload 확인
```

### 4. SSL 인증서 오류

**증상:**
```
GitLab Webhook Response:
  SSL certificate problem: self signed certificate
```

**해결 방법:**

**A. Let's Encrypt 인증서 확인:**
```bash
# 인증서 유효성 확인
openssl s_client -connect jenkins.example.com:443

# 인증서 갱신
./nginx/scripts/renew-certificates.sh
```

**B. GitLab에서 SSL 검증 비활성화 (테스트 환경만):**
```
GitLab Webhook 설정:
  ☐ Enable SSL verification
```

### 5. 브랜치 필터가 작동하지 않음

**증상:**
```
feature 브랜치도 빌드가 트리거됨
```

**해결 방법:**

**A. Regexp Filter 확인:**
```
Optional Filter:
  Text: $GIT_BRANCH
  Expression: ^(master|dev)$

주의: 정규식 문법 확인
```

**B. GitLab Branch Filter 확인:**
```
GitLab Webhook:
  Push events > Branch filter: master,dev
```

**C. 디버깅:**
```
Generic Webhook Trigger:
  ✓ Print contributed variables

Console Output에서:
  Contributing variables:
    GIT_BRANCH = feature/test

  Checking: ^(master|dev)$
  Against: feature/test
  Result: NO MATCH (빌드 안 함) ✓
```

### 6. Multiple Jobs Triggered

**증상:**
```
하나의 Push로 여러 Jenkins Job이 동시에 실행됨
```

**해결 방법:**

**A. 각 Job마다 다른 Token 사용:**
```
backend-deployment:
  Token: backend-webhook-token

frontend-deployment:
  Token: frontend-webhook-token
```

**B. 각 Job마다 다른 Webhook 생성:**
```
GitLab > Settings > Webhooks

Webhook 1:
  URL: https://jenkins.example.com/job/backend/build?token=backend-token

Webhook 2:
  URL: https://jenkins.example.com/job/frontend/build?token=frontend-token
```

---

## 고급 설정

### 1. Merge Request 빌드

**GitLab Webhook 설정:**
```
✓ Merge request events
```

**Jenkins Pipeline:**
```groovy
when {
    expression { env.EVENT_TYPE == 'merge_request' }
}
steps {
    // MR 검증 로직
    sh './scripts/validate-pr.sh'
}
```

### 2. GitLab Commit Status 업데이트

**Jenkins Pipeline:**
```groovy
post {
    success {
        sh """
            curl --request POST \
                --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                --data "state=success&target_url=${BUILD_URL}" \
                "https://gitlab.example.com/api/v4/projects/${PROJECT_ID}/statuses/${GIT_COMMIT}"
        """
    }
    failure {
        sh """
            curl --request POST \
                --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                --data "state=failed&target_url=${BUILD_URL}" \
                "https://gitlab.example.com/api/v4/projects/${PROJECT_ID}/statuses/${GIT_COMMIT}"
        """
    }
}
```

**GitLab에서 확인:**
```
GitLab > Project > Repository > Commits
각 Commit 옆에 Jenkins 빌드 상태 표시:
  ✓ Success (녹색)
  ✗ Failed (빨간색)
  ◷ Pending (회색)
```

### 3. Tag 기반 릴리즈

**GitLab Webhook:**
```
✓ Tag push events
```

**Jenkins Pipeline:**
```groovy
when {
    expression { env.EVENT_TYPE == 'tag_push' }
}
steps {
    script {
        def tagName = env.GIT_BRANCH.replaceFirst('refs/tags/', '')
        sh "docker tag app:latest app:${tagName}"
        sh "docker push app:${tagName}"
    }
}
```

---

## 요약

### 설정 체크리스트

**GitLab:**
- [ ] Personal Access Token 생성 (api 권한)
- [ ] Webhook Secret Token 생성
- [ ] Webhook 등록 (스크립트 또는 UI)
- [ ] Webhook 테스트 (Push events)
- [ ] Outbound requests 허용 (Admin 설정)

**Jenkins:**
- [ ] Generic Webhook Trigger 플러그인 설치
- [ ] Credentials에 Secret Token 저장
- [ ] Pipeline Job 생성
- [ ] Generic Webhook Trigger 설정
  - [ ] Generic Variables 정의
  - [ ] Token 설정
  - [ ] Optional Filter 설정
- [ ] Pipeline Script 또는 SCM 연결

**테스트:**
- [ ] GitLab에서 Webhook Test (200 OK)
- [ ] Master 브랜치 Push → 운영 배포
- [ ] Dev 브랜치 Push → 개발 배포
- [ ] Feature 브랜치 Push → 빌드 안 됨 (정상)
- [ ] GitLab Commit Status 표시 확인

### 주요 파일

| 파일 | 설명 |
|------|------|
| `gitlab/scripts/setup-webhook.sh` | Webhook 자동 설정 스크립트 |
| `gitlab/webhook-config.example.json` | Webhook 설정 예시 |
| `jenkins/job-configs/webhook-job-dsl.groovy` | Jenkins Job DSL |
| `jenkins/job-configs/Jenkinsfile.webhook-example` | Pipeline 예시 |

### 다음 단계

1. **Webhook 설정 완료 후:**
   - 실제 배포 프로세스 테스트
   - Blue-Green 배포 연동
   - 모니터링 및 알림 설정

2. **추가 설정:**
   - Slack/Discord 알림
   - Merge Request 자동 검증
   - Tag 기반 릴리즈 자동화

---

**작성일:** 2025-10-27
**버전:** 1.0
**작성자:** Claude Code
