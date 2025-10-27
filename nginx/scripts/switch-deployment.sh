#!/bin/bash
# Blue-Green 배포 트래픽 전환 스크립트
# 사용법: ./switch-deployment.sh [blue|green]

set -e

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 환경 변수
TARGET_ENV=$1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NGINX_CONF_DIR="${PROJECT_ROOT}/nginx/conf.d"
ACTIVE_ENV_FILE="${NGINX_CONF_DIR}/active-env.conf"

# 사용법 출력
usage() {
    echo "Usage: $0 [blue|green]"
    echo "  blue   - Switch traffic to Blue environment"
    echo "  green  - Switch traffic to Green environment"
    exit 1
}

# 인자 검증
if [ -z "$TARGET_ENV" ]; then
    echo -e "${RED}Error: Target environment not specified${NC}"
    usage
fi

if [ "$TARGET_ENV" != "blue" ] && [ "$TARGET_ENV" != "green" ]; then
    echo -e "${RED}Error: Invalid environment. Must be 'blue' or 'green'${NC}"
    usage
fi

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Blue-Green Deployment Traffic Switch${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""

# 현재 활성 환경 확인
CURRENT_ENV="unknown"
if [ -f "$ACTIVE_ENV_FILE" ]; then
    CURRENT_ENV=$(grep 'set $active_env' "$ACTIVE_ENV_FILE" | awk -F'"' '{print $2}')
fi

echo -e "Current active environment: ${GREEN}${CURRENT_ENV}${NC}"
echo -e "Target environment: ${GREEN}${TARGET_ENV}${NC}"
echo ""

# 이미 동일한 환경이면 종료
if [ "$CURRENT_ENV" = "$TARGET_ENV" ]; then
    echo -e "${YELLOW}Target environment is already active. No switch needed.${NC}"
    exit 0
fi

# 대상 환경 헬스체크
echo -e "${YELLOW}Step 1: Health check for ${TARGET_ENV} environment...${NC}"

# Docker Compose 실행 확인
COMPOSE_FILE="${PROJECT_ROOT}/docker-compose.prod.yml"
if [ ! -f "$COMPOSE_FILE" ]; then
    COMPOSE_FILE="${PROJECT_ROOT}/docker-compose.dev.yml"
fi

# Spring Boot 헬스체크
SPRING_CONTAINER="spring-boot-${TARGET_ENV}"
if docker ps --format '{{.Names}}' | grep -q "^${SPRING_CONTAINER}$"; then
    echo -n "  - Checking Spring Boot (${SPRING_CONTAINER})... "
    if docker exec "$SPRING_CONTAINER" wget --quiet --tries=1 --spider http://localhost:8080/actuator/health 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
        echo -e "${RED}Health check failed for Spring Boot ${TARGET_ENV}. Aborting switch.${NC}"
        exit 1
    fi
else
    echo -e "${RED}Container ${SPRING_CONTAINER} is not running. Aborting switch.${NC}"
    exit 1
fi

# FastAPI 헬스체크
FASTAPI_CONTAINER="fastapi-${TARGET_ENV}"
if docker ps --format '{{.Names}}' | grep -q "^${FASTAPI_CONTAINER}$"; then
    echo -n "  - Checking FastAPI (${FASTAPI_CONTAINER})... "
    if docker exec "$FASTAPI_CONTAINER" curl -f http://localhost:8000/health 2>/dev/null >/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
        echo -e "${RED}Health check failed for FastAPI ${TARGET_ENV}. Aborting switch.${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}Warning: Container ${FASTAPI_CONTAINER} is not running.${NC}"
fi

# React 헬스체크
REACT_CONTAINER="react-${TARGET_ENV}"
if docker ps --format '{{.Names}}' | grep -q "^${REACT_CONTAINER}$"; then
    echo -n "  - Checking React (${REACT_CONTAINER})... "
    if docker exec "$REACT_CONTAINER" wget --quiet --tries=1 --spider http://localhost:80 2>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
        echo -e "${RED}Health check failed for React ${TARGET_ENV}. Aborting switch.${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}Warning: Container ${REACT_CONTAINER} is not running.${NC}"
fi

echo ""

# active-env.conf 파일 업데이트
echo -e "${YELLOW}Step 2: Updating NGINX configuration...${NC}"

# 백업 생성
if [ -f "$ACTIVE_ENV_FILE" ]; then
    cp "$ACTIVE_ENV_FILE" "${ACTIVE_ENV_FILE}.backup"
    echo "  - Backup created: ${ACTIVE_ENV_FILE}.backup"
fi

# 새로운 설정 작성
cat > "$ACTIVE_ENV_FILE" << EOF
# 활성 환경 설정 (Blue or Green)
# 이 파일은 switch-deployment.sh 스크립트에 의해 자동 업데이트됩니다
# Last updated: $(date '+%Y-%m-%d %H:%M:%S')
set \$active_env "${TARGET_ENV}";
EOF

echo -e "  - Active environment set to: ${GREEN}${TARGET_ENV}${NC}"
echo ""

# NGINX 설정 테스트
echo -e "${YELLOW}Step 3: Testing NGINX configuration...${NC}"

NGINX_CONTAINER=$(docker ps --format '{{.Names}}' | grep -E '^nginx' | head -1)
if [ -z "$NGINX_CONTAINER" ]; then
    echo -e "${RED}Error: NGINX container not found${NC}"
    # 롤백
    if [ -f "${ACTIVE_ENV_FILE}.backup" ]; then
        mv "${ACTIVE_ENV_FILE}.backup" "$ACTIVE_ENV_FILE"
        echo -e "${YELLOW}Rolled back to previous configuration${NC}"
    fi
    exit 1
fi

if docker exec "$NGINX_CONTAINER" nginx -t 2>&1 | grep -q "successful"; then
    echo -e "  - NGINX configuration test: ${GREEN}PASSED${NC}"
else
    echo -e "  - NGINX configuration test: ${RED}FAILED${NC}"
    # 롤백
    if [ -f "${ACTIVE_ENV_FILE}.backup" ]; then
        mv "${ACTIVE_ENV_FILE}.backup" "$ACTIVE_ENV_FILE"
        echo -e "${YELLOW}Rolled back to previous configuration${NC}"
    fi
    exit 1
fi

echo ""

# NGINX 리로드
echo -e "${YELLOW}Step 4: Reloading NGINX...${NC}"

if docker exec "$NGINX_CONTAINER" nginx -s reload; then
    echo -e "  - NGINX reload: ${GREEN}SUCCESS${NC}"
else
    echo -e "  - NGINX reload: ${RED}FAILED${NC}"
    # 롤백
    if [ -f "${ACTIVE_ENV_FILE}.backup" ]; then
        mv "${ACTIVE_ENV_FILE}.backup" "$ACTIVE_ENV_FILE"
        docker exec "$NGINX_CONTAINER" nginx -s reload
        echo -e "${YELLOW}Rolled back to previous configuration${NC}"
    fi
    exit 1
fi

echo ""

# 전환 완료
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Traffic switch completed successfully!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "Traffic is now routed to: ${GREEN}${TARGET_ENV}${NC}"
echo -e "Previous environment (${CURRENT_ENV}) is still running and can be used for rollback."
echo ""
echo -e "${YELLOW}To rollback, run:${NC}"
echo -e "  $0 ${CURRENT_ENV}"
echo ""

# 백업 파일 삭제 (성공 시)
if [ -f "${ACTIVE_ENV_FILE}.backup" ]; then
    rm "${ACTIVE_ENV_FILE}.backup"
fi

exit 0
