#!/bin/bash
# GitLab Webhook 자동 설정 스크립트
# Jenkins로 Push/Merge Request 이벤트를 자동으로 전송합니다.

set -e

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 사용법
usage() {
    echo "Usage: $0 <gitlab-url> <project-id> <gitlab-token> <jenkins-webhook-url> <webhook-secret>"
    echo ""
    echo "Parameters:"
    echo "  gitlab-url          GitLab 서버 URL (예: https://gitlab.example.com)"
    echo "  project-id          GitLab 프로젝트 ID (프로젝트 설정에서 확인)"
    echo "  gitlab-token        GitLab Personal Access Token (api 권한 필요)"
    echo "  jenkins-webhook-url Jenkins Webhook URL"
    echo "  webhook-secret      Webhook Secret Token (Jenkins와 공유)"
    echo ""
    echo "Example:"
    echo "  $0 https://gitlab.example.com 123 glpat-xxxxx \\"
    echo "     https://jenkins.example.com/generic-webhook-trigger/invoke mySecretToken123"
    exit 1
}

# 인자 확인
if [ $# -ne 5 ]; then
    usage
fi

GITLAB_URL=$1
PROJECT_ID=$2
GITLAB_TOKEN=$3
JENKINS_WEBHOOK_URL=$4
WEBHOOK_SECRET=$5

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}GitLab Webhook Setup${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""
echo -e "GitLab URL: ${GREEN}${GITLAB_URL}${NC}"
echo -e "Project ID: ${GREEN}${PROJECT_ID}${NC}"
echo -e "Jenkins URL: ${GREEN}${JENKINS_WEBHOOK_URL}${NC}"
echo ""

# GitLab API 엔드포인트
API_URL="${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/hooks"

# 기존 Webhook 확인
echo -e "${YELLOW}Step 1: Checking existing webhooks...${NC}"
EXISTING_HOOKS=$(curl -s --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "${API_URL}")

if echo "$EXISTING_HOOKS" | grep -q "${JENKINS_WEBHOOK_URL}"; then
    echo -e "${YELLOW}Warning: Webhook already exists for this Jenkins URL${NC}"
    read -p "Do you want to delete and recreate it? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # 기존 Webhook ID 찾기
        HOOK_ID=$(echo "$EXISTING_HOOKS" | jq -r ".[] | select(.url == \"${JENKINS_WEBHOOK_URL}\") | .id")
        if [ -n "$HOOK_ID" ]; then
            echo -e "Deleting existing webhook (ID: ${HOOK_ID})..."
            curl -s --request DELETE --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
                "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/hooks/${HOOK_ID}"
            echo -e "${GREEN}✓ Deleted${NC}"
        fi
    else
        echo -e "${YELLOW}Skipping webhook creation${NC}"
        exit 0
    fi
fi

# Webhook 생성
echo ""
echo -e "${YELLOW}Step 2: Creating new webhook...${NC}"

WEBHOOK_DATA=$(cat <<EOF
{
  "url": "${JENKINS_WEBHOOK_URL}",
  "token": "${WEBHOOK_SECRET}",
  "push_events": true,
  "push_events_branch_filter": "master,dev",
  "tag_push_events": true,
  "merge_requests_events": true,
  "enable_ssl_verification": true,
  "confidential_note_events": false,
  "wiki_page_events": false,
  "deployment_events": false,
  "job_events": false,
  "pipeline_events": false,
  "releases_events": false
}
EOF
)

RESPONSE=$(curl -s --request POST \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "${WEBHOOK_DATA}" \
    "${API_URL}")

# 결과 확인
if echo "$RESPONSE" | jq -e '.id' > /dev/null 2>&1; then
    HOOK_ID=$(echo "$RESPONSE" | jq -r '.id')
    echo -e "${GREEN}✓ Webhook created successfully!${NC}"
    echo -e "Webhook ID: ${GREEN}${HOOK_ID}${NC}"
    echo ""

    # Webhook 테스트
    echo -e "${YELLOW}Step 3: Testing webhook...${NC}"
    TEST_RESPONSE=$(curl -s --request POST \
        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/hooks/${HOOK_ID}/test/push_events")

    if echo "$TEST_RESPONSE" | jq -e '.message' > /dev/null 2>&1; then
        ERROR_MSG=$(echo "$TEST_RESPONSE" | jq -r '.message')
        echo -e "${RED}✗ Test failed: ${ERROR_MSG}${NC}"
    else
        echo -e "${GREEN}✓ Test successful${NC}"
    fi
else
    echo -e "${RED}✗ Failed to create webhook${NC}"
    echo -e "Response: ${RESPONSE}"
    exit 1
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Webhook Setup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "Webhook Details:"
echo -e "  - ID: ${HOOK_ID}"
echo -e "  - URL: ${JENKINS_WEBHOOK_URL}"
echo -e "  - Triggers: Push (master, dev), Tag Push, Merge Requests"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo -e "1. Configure Jenkins job to use Generic Webhook Trigger"
echo -e "2. Set the same secret token in Jenkins credentials"
echo -e "3. Push to master or dev branch to test the integration"
echo ""
