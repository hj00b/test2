#!/bin/bash
# Blue-Green 배포 헬스체크 스크립트
# 사용법: ./health-check.sh [blue|green]

set -e

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 환경 변수
TARGET_ENV=$1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 기본값 설정 (인자가 없으면 현재 활성 환경 체크)
if [ -z "$TARGET_ENV" ]; then
    ACTIVE_ENV_FILE="${PROJECT_ROOT}/nginx/conf.d/active-env.conf"
    if [ -f "$ACTIVE_ENV_FILE" ]; then
        TARGET_ENV=$(grep 'set $active_env' "$ACTIVE_ENV_FILE" | awk -F'"' '{print $2}')
    else
        TARGET_ENV="blue"
    fi
fi

# 사용법 출력
usage() {
    echo "Usage: $0 [blue|green]"
    echo "  blue   - Check Blue environment health"
    echo "  green  - Check Green environment health"
    echo "  (no arg) - Check currently active environment"
    exit 1
}

# 인자 검증
if [ "$TARGET_ENV" != "blue" ] && [ "$TARGET_ENV" != "green" ]; then
    echo -e "${RED}Error: Invalid environment. Must be 'blue' or 'green'${NC}"
    usage
fi

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Health Check for ${TARGET_ENV} environment${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""

# 헬스체크 결과 저장
HEALTH_CHECK_FAILED=0

# 헬스체크 함수
check_service() {
    local service_name=$1
    local container_name=$2
    local health_command=$3

    echo -n "Checking ${service_name} (${container_name})... "

    # 컨테이너 실행 확인
    if ! docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo -e "${RED}NOT RUNNING${NC}"
        HEALTH_CHECK_FAILED=1
        return 1
    fi

    # 헬스체크 실행
    if eval "$health_command" > /dev/null 2>&1; then
        echo -e "${GREEN}HEALTHY${NC}"
        return 0
    else
        echo -e "${RED}UNHEALTHY${NC}"
        HEALTH_CHECK_FAILED=1
        return 1
    fi
}

# 1. Spring Boot 헬스체크
SPRING_CONTAINER="spring-boot-${TARGET_ENV}"
check_service "Spring Boot" "$SPRING_CONTAINER" \
    "docker exec $SPRING_CONTAINER wget --quiet --tries=1 --spider http://localhost:8080/actuator/health"

# 추가 정보 출력 (Spring Boot)
if docker ps --format '{{.Names}}' | grep -q "^${SPRING_CONTAINER}$"; then
    # 상세 헬스 정보 (실패해도 계속 진행)
    SPRING_HEALTH=$(docker exec "$SPRING_CONTAINER" wget -qO- http://localhost:8080/actuator/health 2>/dev/null || echo "")
    if [ -n "$SPRING_HEALTH" ]; then
        echo "  Details: $SPRING_HEALTH"
    fi
fi

echo ""

# 2. FastAPI 헬스체크
FASTAPI_CONTAINER="fastapi-${TARGET_ENV}"
check_service "FastAPI" "$FASTAPI_CONTAINER" \
    "docker exec $FASTAPI_CONTAINER curl -sf http://localhost:8000/health"

# 추가 정보 출력 (FastAPI)
if docker ps --format '{{.Names}}' | grep -q "^${FASTAPI_CONTAINER}$"; then
    FASTAPI_HEALTH=$(docker exec "$FASTAPI_CONTAINER" curl -s http://localhost:8000/health 2>/dev/null || echo "")
    if [ -n "$FASTAPI_HEALTH" ]; then
        echo "  Details: $FASTAPI_HEALTH"
    fi
fi

echo ""

# 3. React 헬스체크
REACT_CONTAINER="react-${TARGET_ENV}"
check_service "React Frontend" "$REACT_CONTAINER" \
    "docker exec $REACT_CONTAINER wget --quiet --tries=1 --spider http://localhost:80"

# React는 정적 파일이므로 상세 정보 없음

echo ""

# 4. 추가 체크: 컨테이너 리소스 사용량
echo -e "${YELLOW}Container Resource Usage:${NC}"
echo ""

if docker ps --format '{{.Names}}' | grep -q "^${SPRING_CONTAINER}$"; then
    echo "Spring Boot:"
    docker stats --no-stream --format "  CPU: {{.CPUPerc}}\tMemory: {{.MemUsage}}" "$SPRING_CONTAINER" 2>/dev/null || echo "  Unable to get stats"
fi

if docker ps --format '{{.Names}}' | grep -q "^${FASTAPI_CONTAINER}$"; then
    echo "FastAPI:"
    docker stats --no-stream --format "  CPU: {{.CPUPerc}}\tMemory: {{.MemUsage}}" "$FASTAPI_CONTAINER" 2>/dev/null || echo "  Unable to get stats"
fi

if docker ps --format '{{.Names}}' | grep -q "^${REACT_CONTAINER}$"; then
    echo "React:"
    docker stats --no-stream --format "  CPU: {{.CPUPerc}}\tMemory: {{.MemUsage}}" "$REACT_CONTAINER" 2>/dev/null || echo "  Unable to get stats"
fi

echo ""

# 5. 로그 확인 (최근 에러 로그)
echo -e "${YELLOW}Recent Error Logs:${NC}"
echo ""

if docker ps --format '{{.Names}}' | grep -q "^${SPRING_CONTAINER}$"; then
    SPRING_ERRORS=$(docker logs "$SPRING_CONTAINER" --tail 50 2>&1 | grep -i "error\|exception\|failed" | tail -3 || echo "")
    if [ -n "$SPRING_ERRORS" ]; then
        echo "Spring Boot errors (last 3):"
        echo "$SPRING_ERRORS"
        echo ""
    fi
fi

if docker ps --format '{{.Names}}' | grep -q "^${FASTAPI_CONTAINER}$"; then
    FASTAPI_ERRORS=$(docker logs "$FASTAPI_CONTAINER" --tail 50 2>&1 | grep -i "error\|exception\|failed" | tail -3 || echo "")
    if [ -n "$FASTAPI_ERRORS" ]; then
        echo "FastAPI errors (last 3):"
        echo "$FASTAPI_ERRORS"
        echo ""
    fi
fi

# 최종 결과
echo -e "${YELLOW}========================================${NC}"
if [ $HEALTH_CHECK_FAILED -eq 0 ]; then
    echo -e "${GREEN}Health Check: PASSED${NC}"
    echo -e "${GREEN}All services in ${TARGET_ENV} environment are healthy${NC}"
    echo -e "${YELLOW}========================================${NC}"
    exit 0
else
    echo -e "${RED}Health Check: FAILED${NC}"
    echo -e "${RED}Some services in ${TARGET_ENV} environment are not healthy${NC}"
    echo -e "${YELLOW}========================================${NC}"
    exit 1
fi
