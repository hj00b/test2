# Blue-Green 배포 가이드

## 목차
1. [개요](#개요)
2. [아키텍처](#아키텍처)
3. [작동 원리](#작동-원리)
4. [배포 프로세스](#배포-프로세스)
5. [수정 내역](#수정-내역)
6. [사용 방법](#사용-방법)
7. [롤백 가이드](#롤백-가이드)
8. [트러블슈팅](#트러블슈팅)

---

## 개요

### Blue-Green 배포란?

Blue-Green 배포는 **무중단 배포(Zero-Downtime Deployment)** 전략의 하나로, 두 개의 동일한 프로덕션 환경을 유지하면서 트래픽을 전환하는 방식입니다.

**장점:**
- ✅ 무중단 배포 (서비스 중단 없음)
- ✅ 즉시 롤백 가능 (문제 발생 시 이전 버전으로 즉시 전환)
- ✅ 프로덕션과 동일한 환경에서 테스트 가능
- ✅ 데이터베이스 마이그레이션 리스크 감소

**단점:**
- ❌ 리소스 2배 필요 (Blue + Green 동시 실행)
- ❌ 데이터베이스 스키마 변경 시 주의 필요
- ❌ 설정 및 관리 복잡도 증가

---

## 아키텍처

### 전체 구조

```
┌─────────────────────────────────────────────────┐
│              NGINX (Port 80/443)                │
│         트래픽 라우팅 & 로드밸런서               │
│   (active-env.conf에 따라 Blue/Green 선택)      │
└────────────────┬────────────────────────────────┘
                 │
        ┌────────┴────────┐
        ▼                 ▼
┌───────────────┐  ┌───────────────┐
│  BLUE 환경    │  │  GREEN 환경   │
├───────────────┤  ├───────────────┤
│ Spring Boot   │  │ Spring Boot   │
│ (Port 8080)   │  │ (Port 8080)   │
├───────────────┤  ├───────────────┤
│ FastAPI       │  │ FastAPI       │
│ (Port 8000)   │  │ (Port 8000)   │
├───────────────┤  ├───────────────┤
│ React         │  │ React         │
│ (Port 80)     │  │ (Port 80)     │
└───────┬───────┘  └───────┬───────┘
        │                  │
        └────────┬─────────┘
                 ▼
    ┌────────────────────────┐
    │     공유 리소스         │
    ├────────────────────────┤
    │ MySQL (Port 3306)      │
    │ Kafka (Port 9092)      │
    │ Qdrant (Port 6333)     │
    │ Zookeeper (Port 2181)  │
    └────────────────────────┘
```

### 네트워크 구성

**운영 환경 (Production):**
- `devops-network`: NGINX, Jenkins, Frontend, Backend
- `backend-network`: Backend, Database, Message Queue
- `monitoring-network`: Prometheus, Grafana

**개발 환경 (Development):**
- `devops-network-dev`: 모든 개발 서비스
- `backend-network-dev`: 개발 백엔드 서비스

---

## 작동 원리

### 1. NGINX 트래픽 라우팅

#### active-env.conf
```nginx
# nginx/conf.d/active-env.conf
set $active_env "blue";  # 또는 "green"
```

#### default.conf (라우팅 로직)
```nginx
# Spring Boot 라우팅 예시
location /api/v1 {
    set $backend_upstream "spring-boot-blue";
    if ($active_env = "green") {
        set $backend_upstream "spring-boot-green";
    }

    proxy_pass http://$backend_upstream;
    # ... 기타 프록시 설정
}
```

### 2. 배포 시나리오

#### 시나리오 1: 정상 배포 (Blue → Green 전환)

```
1. 초기 상태
   ┌─────────┐
   │  NGINX  │
   └────┬────┘
        ├─→ Blue (현재 운영 중, v1.0)
        └─→ Green (대기 중, v1.0)

2. Green에 새 버전 배포 (Jenkins)
   ┌─────────┐
   │  NGINX  │
   └────┬────┘
        ├─→ Blue (계속 트래픽 처리, v1.0) ← 사용자
        └─→ Green (새 버전 배포 중, v1.1)

3. Green 헬스체크 통과
   ┌─────────┐
   │  NGINX  │
   └────┬────┘
        ├─→ Blue (계속 트래픽 처리, v1.0) ← 사용자
        └─→ Green (준비 완료, v1.1) ✓

4. 트래픽 전환 (switch-deployment.sh green)
   ┌─────────┐
   │  NGINX  │
   └────┬────┘
        ├─→ Blue (대기 중, v1.0)
        └─→ Green (트래픽 처리 시작, v1.1) ← 사용자

5. 완료 (Blue는 롤백용 대기)
   ┌─────────┐
   │  NGINX  │
   └────┬────┘
        ├─→ Blue (롤백 대기, v1.0)
        └─→ Green (운영 중, v1.1) ← 사용자
```

#### 시나리오 2: 롤백 (문제 발견 시)

```
문제 발견!
   ┌─────────┐
   │  NGINX  │
   └────┬────┘
        ├─→ Blue (정상 버전, v1.0)
        └─→ Green (문제 있는 버전, v1.1) ← 사용자 🔥

즉시 롤백 (switch-deployment.sh blue)
   ┌─────────┐
   │  NGINX  │
   └────┬────┘
        ├─→ Blue (트래픽 처리 재개, v1.0) ← 사용자 ✓
        └─→ Green (격리, v1.1)

롤백 완료 (수초 내 완료)
```

---

## 배포 프로세스

### Jenkins 파이프라인 기반 배포

#### 1. 파이프라인 트리거

**자동 트리거:**
- GitLab Webhook을 통해 자동 실행
- `master` 브랜치 푸시 → 운영 환경 배포
- `dev` 브랜치 푸시 → 개발 환경 배포

**수동 트리거:**
- Jenkins 콘솔에서 "Build with Parameters" 선택
- 배포 대상 환경 선택 (Blue/Green)

#### 2. 파이프라인 단계

```groovy
// Jenkinsfile.backend 주요 단계

1. Checkout
   - Git 소스 체크아웃
   - 브랜치 감지 (master → prod, dev → dev)

2. Environment Setup
   - .env.prod 또는 .env.dev 로드
   - 환경 변수 설정

3. Test (Optional)
   - Spring Boot: mvn test
   - FastAPI: pytest

4. Build Docker Images
   - Dockerfile.prod (운영) 또는 Dockerfile (개발)
   - 이미지 태그: registry.example.com/service:commit-env

5. Push to Registry
   - Docker Registry에 이미지 푸시

6. Deploy to Target Environment
   - docker-compose up -d spring-boot-${TARGET_ENV}
   - 예: spring-boot-green 컨테이너 재시작

7. Health Check
   - ./scripts/health-check.sh green
   - 모든 서비스 헬스체크 통과 확인

8. Switch Traffic (Optional)
   - AUTO_SWITCH=true 시 자동 전환
   - 수동 승인 후 ./nginx/scripts/switch-deployment.sh green
```

#### 3. 파이프라인 파라미터

| 파라미터 | 설명 | 기본값 |
|---------|------|--------|
| `TARGET_ENV` | 배포 대상 (blue/green) | blue |
| `AUTO_SWITCH` | 자동 트래픽 전환 여부 | false |
| `RUN_TESTS` | 테스트 실행 여부 | true |

---

## 수정 내역

### 구현 전 상태

기존 구조에는 블루-그린 배포를 위한 **컨테이너 구조만 설계**되어 있었고, 실제 **트래픽 라우팅 및 전환 메커니즘이 구현되지 않음**.

#### 누락되었던 부분
1. ❌ NGINX 블루-그린 라우팅 설정
2. ❌ 트래픽 전환 스크립트
3. ❌ 헬스체크 스크립트

### 구현 내용

#### 1. NGINX 설정 추가

**파일: `nginx/conf.d/upstream.conf` (신규)**
```nginx
# Blue/Green upstream 정의
upstream spring-boot-blue {
    server spring-boot-blue:8080;
}

upstream spring-boot-green {
    server spring-boot-green:8080;
}
# ... FastAPI, React도 동일
```

**파일: `nginx/conf.d/active-env.conf` (신규)**
```nginx
# 활성 환경 제어 파일
set $active_env "blue";
```

**파일: `nginx/conf.d/default.conf` (수정)**
- HTTP → HTTPS 리다이렉트 유지
- Blue-Green 라우팅 로직 추가
  - Frontend (React): `/` → `react-${active_env}`
  - API (Spring): `/api/v1` → `spring-boot-${active_env}`
  - AI API (FastAPI): `/api/ai` → `fastapi-${active_env}`
- Jenkins, Prometheus, Grafana 라우팅 추가

**주요 라우팅 코드:**
```nginx
location /api/v1 {
    set $backend_upstream "spring-boot-blue";
    if ($active_env = "green") {
        set $backend_upstream "spring-boot-green";
    }
    proxy_pass http://$backend_upstream;
}
```

#### 2. 트래픽 전환 스크립트

**파일: `nginx/scripts/switch-deployment.sh` (신규)**

**기능:**
- Blue/Green 환경 전환
- 대상 환경 헬스체크 수행
- active-env.conf 파일 업데이트
- NGINX 설정 테스트 및 리로드
- 실패 시 자동 롤백

**사용법:**
```bash
# Green으로 전환
./nginx/scripts/switch-deployment.sh green

# Blue로 롤백
./nginx/scripts/switch-deployment.sh blue
```

**실행 흐름:**
```
1. 인자 검증 (blue/green)
2. 현재 활성 환경 확인
3. 대상 환경 헬스체크
   - Spring Boot: /actuator/health
   - FastAPI: /health
   - React: / (200 OK)
4. active-env.conf 백업 생성
5. active-env.conf 업데이트
6. NGINX 설정 테스트 (nginx -t)
7. NGINX 리로드 (nginx -s reload)
8. 실패 시 자동 롤백
```

#### 3. 헬스체크 스크립트

**파일: `scripts/health-check.sh` (신규)**

**기능:**
- 특정 환경(Blue/Green)의 모든 서비스 헬스체크
- 컨테이너 실행 상태 확인
- 리소스 사용량 모니터링
- 에러 로그 확인

**사용법:**
```bash
# Green 환경 체크
./scripts/health-check.sh green

# Blue 환경 체크
./scripts/health-check.sh blue

# 현재 활성 환경 체크 (인자 없음)
./scripts/health-check.sh
```

**체크 항목:**
```
✓ 컨테이너 실행 여부
✓ 헬스 엔드포인트 응답
✓ CPU/메모리 사용량
✓ 최근 에러 로그
```

---

## 사용 방법

### 1. 초기 설정

#### 스크립트 실행 권한 부여
```bash
chmod +x nginx/scripts/switch-deployment.sh
chmod +x nginx/scripts/health-check.sh
chmod +x scripts/health-check.sh
```

#### 환경 변수 설정
```bash
# .env.prod 또는 .env.dev 생성
cp .env.prod.example .env.prod
cp .env.dev.example .env.dev

# 환경 변수 수정
vi .env.prod
```

#### Docker Compose 실행
```bash
# 운영 환경
docker-compose -f docker-compose.prod.yml up -d

# 개발 환경
docker-compose -f docker-compose.dev.yml up -d
```

### 2. 배포 시나리오

#### A. Jenkins를 통한 자동 배포

1. **GitLab에 코드 푸시**
   ```bash
   git add .
   git commit -m "feat: 새로운 기능 추가"
   git push origin master  # 운영 배포
   # 또는
   git push origin dev     # 개발 배포
   ```

2. **Jenkins 파이프라인 실행**
   - Webhook으로 자동 트리거
   - 또는 Jenkins 콘솔에서 수동 실행

3. **배포 파라미터 선택**
   - `TARGET_ENV`: green (새 버전 배포할 환경)
   - `AUTO_SWITCH`: false (수동 전환)
   - `RUN_TESTS`: true

4. **파이프라인 모니터링**
   - 빌드, 테스트, 배포 진행 상황 확인
   - Health Check 통과 확인

5. **수동 트래픽 전환 승인**
   - Jenkins에서 "Switch Traffic" 승인
   - 또는 서버에서 직접 스크립트 실행:
     ```bash
     ./nginx/scripts/switch-deployment.sh green
     ```

6. **배포 완료 확인**
   ```bash
   # 활성 환경 확인
   cat nginx/conf.d/active-env.conf

   # 헬스체크
   ./scripts/health-check.sh green
   ```

#### B. 수동 배포 (서버 직접 접속)

1. **대상 환경에 새 버전 배포**
   ```bash
   # Green 환경에 배포
   docker-compose -f docker-compose.prod.yml up -d \
     spring-boot-green \
     fastapi-green \
     react-green
   ```

2. **헬스체크 수행**
   ```bash
   ./scripts/health-check.sh green
   ```

3. **트래픽 전환**
   ```bash
   ./nginx/scripts/switch-deployment.sh green
   ```

### 3. 모니터링

#### 활성 환경 확인
```bash
cat nginx/conf.d/active-env.conf
# 출력: set $active_env "blue";
```

#### 컨테이너 상태 확인
```bash
docker ps --filter "name=spring-boot"
docker ps --filter "name=fastapi"
docker ps --filter "name=react"
```

#### 로그 확인
```bash
# Blue 환경
docker logs -f spring-boot-blue
docker logs -f fastapi-blue

# Green 환경
docker logs -f spring-boot-green
docker logs -f fastapi-green
```

---

## 롤백 가이드

### 즉시 롤백 (문제 발견 시)

현재 Green이 활성이고 문제가 발생한 경우:

```bash
# 1. 즉시 Blue로 롤백
./nginx/scripts/switch-deployment.sh blue

# 2. 롤백 확인
./scripts/health-check.sh blue

# 3. Green 환경 로그 확인 (원인 파악)
docker logs spring-boot-green
docker logs fastapi-green
```

**롤백 소요 시간:** 약 5-10초 (NGINX 리로드만 필요)

### 이전 버전으로 재배포

롤백 후 Green 환경을 이전 버전으로 재배포:

```bash
# 1. Green 컨테이너 중지 및 제거
docker-compose -f docker-compose.prod.yml down \
  spring-boot-green \
  fastapi-green \
  react-green

# 2. 이전 이미지로 재배포
docker-compose -f docker-compose.prod.yml up -d \
  spring-boot-green \
  fastapi-green \
  react-green

# 3. 헬스체크
./scripts/health-check.sh green
```

---

## 트러블슈팅

### 1. 트래픽 전환 실패

**증상:**
```
Error: NGINX configuration test failed
```

**원인:**
- active-env.conf 문법 오류
- upstream 컨테이너 미실행

**해결:**
```bash
# NGINX 설정 테스트
docker exec nginx-prod nginx -t

# 컨테이너 상태 확인
docker ps -a | grep -E "spring-boot|fastapi|react"

# 수동 롤백
cp nginx/conf.d/active-env.conf.backup nginx/conf.d/active-env.conf
docker exec nginx-prod nginx -s reload
```

### 2. 헬스체크 실패

**증상:**
```
Health Check: FAILED
Service spring-boot-green is UNHEALTHY
```

**원인:**
- 컨테이너 시작 중 (아직 준비 안 됨)
- 애플리케이션 에러
- 데이터베이스 연결 실패

**해결:**
```bash
# 1. 로그 확인
docker logs spring-boot-green

# 2. 환경 변수 확인
docker exec spring-boot-green env | grep -E "SPRING|MYSQL|KAFKA"

# 3. 네트워크 연결 확인
docker exec spring-boot-green ping -c 3 mysql-prod
docker exec spring-boot-green ping -c 3 kafka-prod

# 4. 재시작
docker-compose -f docker-compose.prod.yml restart spring-boot-green
```

### 3. CORS 에러

**증상:**
```
Access to XMLHttpRequest has been blocked by CORS policy
```

**원인:**
- NGINX CORS 헤더 누락
- Backend CORS 설정 오류

**해결:**
```nginx
# nginx/conf.d/default.conf
location /api/v1 {
    # CORS 헤더 추가
    add_header Access-Control-Allow-Origin * always;
    add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;
    add_header Access-Control-Allow-Headers "Authorization, Content-Type" always;

    if ($request_method = 'OPTIONS') {
        return 204;
    }

    # ... 나머지 설정
}
```

### 4. SSL 인증서 문제

**증상:**
```
nginx: [emerg] cannot load certificate "/etc/letsencrypt/live/example.com/fullchain.pem"
```

**원인:**
- Let's Encrypt 인증서 미발급
- 인증서 경로 오류

**해결:**
```bash
# 1. 인증서 발급 (Certbot)
docker-compose -f docker-compose.prod.yml run --rm certbot certonly \
  --webroot \
  --webroot-path=/var/www/certbot \
  -d example.com \
  -d api.example.com \
  --email admin@example.com \
  --agree-tos

# 2. NGINX 리로드
docker-compose -f docker-compose.prod.yml restart nginx
```

### 5. 데이터베이스 연결 실패

**증상:**
```
java.sql.SQLException: Communications link failure
```

**원인:**
- MySQL 컨테이너 미실행
- 네트워크 분리
- 잘못된 연결 문자열

**해결:**
```bash
# 1. MySQL 상태 확인
docker ps | grep mysql-prod
docker logs mysql-prod

# 2. 네트워크 확인
docker network inspect backend-network

# 3. 연결 테스트
docker exec spring-boot-green ping -c 3 mysql-prod

# 4. 환경 변수 확인
echo $SPRING_DB_URL
# 올바른 형식: jdbc:mysql://mysql-prod:3306/prod_db
```

---

## 참고 자료

### 디렉토리 구조
```
.
├── docker-compose.prod.yml      # 운영 환경 컨테이너 정의
├── docker-compose.dev.yml       # 개발 환경 컨테이너 정의
├── nginx/
│   ├── conf.d/
│   │   ├── upstream.conf        # Upstream 정의 (Blue/Green)
│   │   ├── active-env.conf      # 활성 환경 설정 (blue/green)
│   │   ├── default.conf         # 라우팅 규칙
│   │   └── ssl-params.conf      # SSL 설정
│   └── scripts/
│       ├── switch-deployment.sh # 트래픽 전환 스크립트
│       ├── health-check.sh      # NGINX 헬스체크
│       └── reload-nginx.sh      # NGINX 리로드
├── scripts/
│   └── health-check.sh          # 서비스 헬스체크
├── jenkins/
│   └── pipelines/
│       ├── Jenkinsfile.backend  # Backend 배포 파이프라인
│       └── Jenkinsfile.frontend # Frontend 배포 파이프라인
└── docs/
    └── BLUE_GREEN_DEPLOYMENT.md # 이 문서
```

### 관련 파일

| 파일 | 설명 |
|------|------|
| `nginx/conf.d/active-env.conf` | 활성 환경 제어 파일 (Blue/Green 선택) |
| `nginx/scripts/switch-deployment.sh` | 트래픽 전환 스크립트 |
| `scripts/health-check.sh` | 헬스체크 스크립트 |
| `docker-compose.prod.yml` | 운영 환경 컨테이너 정의 |
| `jenkins/pipelines/Jenkinsfile.backend` | 배포 파이프라인 |

### 환경 변수

**.env.prod 주요 변수:**
```bash
# 도메인
DOMAIN_FRONTEND=www.example.com
DOMAIN_API=api.example.com
DOMAIN_JENKINS=jenkins.example.com

# Blue-Green 설정
ACTIVE_ENVIRONMENT=blue

# 데이터베이스
MYSQL_ROOT_PASSWORD=secure_password
MYSQL_DATABASE=prod_db
```

---

## 요약

### 핵심 개념
1. **두 개의 동일한 환경 유지**: Blue와 Green
2. **NGINX가 트래픽 라우팅**: active-env.conf로 제어
3. **무중단 전환**: 한쪽 환경에 배포 후 트래픽만 전환
4. **즉시 롤백 가능**: 이전 환경이 계속 실행 중

### 배포 흐름
```
코드 푸시 → Jenkins 빌드 → Green 배포 → 헬스체크 →
트래픽 전환 (수동 승인) → 완료
```

### 롤백 흐름
```
문제 발견 → switch-deployment.sh blue → 즉시 복구 (5-10초)
```

### 주요 명령어
```bash
# 트래픽 전환
./nginx/scripts/switch-deployment.sh [blue|green]

# 헬스체크
./scripts/health-check.sh [blue|green]

# 활성 환경 확인
cat nginx/conf.d/active-env.conf
```

---

**작성일:** 2025-10-27
**버전:** 1.0
**작성자:** Claude Code
