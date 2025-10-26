# Docker Compose 컨테이너 트러블슈팅 가이드

## 📋 목차
1. [문제 개요](#문제-개요)
2. [진단 과정](#진단-과정)
3. [문제별 해결 방안](#문제별-해결-방안)
4. [최종 결과](#최종-결과)
5. [예방 방법](#예방-방법)

---

## 🔍 문제 개요

### 발생 상황
Docker Compose로 관리되는 개발 환경에서 다수의 컨테이너가 재시작 루프에 빠지거나 시작 실패 상태에 놓임.

### 영향 받은 서비스
- MySQL (Restarting, exit 1)
- Kafka (Restarting, exit 1)
- Spring Boot Blue/Green (Restarting/Created, exit 1)
- React Blue/Green (Restarting, exit 127)
- Qdrant (Unhealthy)

---

## 🔬 진단 과정

### 1단계: 컨테이너 상태 확인

```bash
# 실행 중인 컨테이너 확인
docker ps

# 모든 컨테이너 상태 확인 (중지된 것 포함)
docker ps -a
```

**확인된 문제:**
- 5개의 컨테이너가 재시작 중 (Restarting)
- 1개의 컨테이너가 Created 상태로 멈춤
- 1개의 컨테이너가 Unhealthy 상태

### 2단계: 로그 분석

```bash
# 각 컨테이너별 로그 확인
docker logs --tail 50 <container-name>
```

**주요 에러 메시지:**

| 컨테이너 | 에러 메시지 | Exit Code |
|----------|------------|-----------|
| MySQL | `Database is uninitialized and password option is not specified` | 1 |
| Kafka | `environment variable "KAFKA_PROCESS_ROLES" is not set` | 1 |
| React | `sh: react-scripts: not found` | 127 |
| Spring Boot | `Error: Unable to access jarfile /app/app.jar` | 1 |

### 3단계: 설정 파일 검토

```bash
# Docker Compose 파일 확인
cat docker-compose.dev.yml

# 환경 변수 파일 확인
ls -la .env*
```

**발견된 문제:**
- `.env.dev` 파일이 존재하지 않음 (`.env.dev.example`만 존재)
- Volume 마운트로 인한 빌드 결과물 덮어쓰기
- 포트 충돌 가능성

---

## 🛠️ 문제별 해결 방안

### 문제 1: MySQL 컨테이너 재시작

#### 원인 분석
```
2025-10-26 09:36:17+00:00 [ERROR] [Entrypoint]: Database is uninitialized and password option is not specified
    You need to specify one of the following as an environment variable:
    - MYSQL_ROOT_PASSWORD
    - MYSQL_ALLOW_EMPTY_PASSWORD
    - MYSQL_RANDOM_ROOT_PASSWORD
```

- `.env.dev` 파일 누락으로 환경 변수가 전달되지 않음
- MySQL 컨테이너가 필수 환경 변수 없이 시작 시도

#### 해결 방법
```bash
# 1. .env.dev 파일 생성
cp .env.dev.example .env.dev

# 2. 컨테이너 재시작
docker-compose -f docker-compose.dev.yml --env-file .env.dev up -d mysql-dev
```

#### 설정 내용 (`.env.dev`)
```bash
MYSQL_ROOT_PASSWORD=dev_root_password
MYSQL_DATABASE=dev_db
MYSQL_USER=dev_user
MYSQL_PASSWORD=dev_password
MYSQL_PORT=13306
```

---

### 문제 2: Kafka 컨테이너 재시작

#### 원인 분석
```
error in executing the command: environment variable "KAFKA_PROCESS_ROLES" is not set
```

- Kafka `latest` 이미지가 KRaft 모드로 전환됨
- 기존 Zookeeper 기반 설정과 호환되지 않음
- KRaft 모드 필수 환경 변수 누락

#### 해결 방법

**docker-compose.dev.yml 수정:**
```yaml
# Before
kafka-dev:
  image: confluentinc/cp-kafka:latest
  # ...

# After
kafka-dev:
  image: confluentinc/cp-kafka:7.5.0  # 안정 버전으로 고정
  # ...
```

#### 교훈
- 프로덕션/개발 환경에서는 `latest` 태그 사용 지양
- 버전을 명시적으로 지정하여 예상치 못한 업데이트 방지

---

### 문제 3: React 컨테이너 재시작 (Exit 127)

#### 원인 분석
```bash
> react-scripts start
sh: react-scripts: not found
```

**근본 원인:**
1. `package.json`에 `react-scripts: ^0.0.0` 설정 오류
2. `package-lock.json`이 구버전으로 동기화되지 않음
3. `npm ci` 명령어가 lock 파일 불일치로 실패

#### 해결 방법

**1. package.json 수정 (`frontend/react/package.json:10`):**
```json
{
  "dependencies": {
    "react-scripts": "^5.0.1"  // ^0.0.0 → ^5.0.1
  }
}
```

**2. package-lock.json 제거:**
```bash
rm frontend/react/package-lock.json
```

**3. Dockerfile 수정 (`frontend/react/Dockerfile`):**
```dockerfile
# Before
RUN npm ci

# After
RUN npm install  # lock 파일 재생성
```

**4. 컨테이너 재빌드:**
```bash
docker-compose -f docker-compose.dev.yml build react-blue-dev react-green-dev
docker-compose -f docker-compose.dev.yml up -d react-blue-dev react-green-dev
```

#### 빌드 성공 로그
```
#57 66.43 added 1330 packages, and audited 1331 packages in 1m
#57 66.43
#57 66.43 271 packages are looking for funding
#57 66.44
#57 66.44 9 vulnerabilities (3 moderate, 6 high)
```

---

### 문제 4: Spring Boot 컨테이너 재시작

#### 원인 분석
```
Error: Unable to access jarfile /app/app.jar
```

**근본 원인:**
- Dockerfile에서 multi-stage build로 JAR 파일 생성
- Volume 마운트 `./backend/spring-boot:/app`로 인해 빌드 결과물 덮어씌워짐
- 호스트의 빈 디렉토리가 컨테이너 내부 `/app` 디렉토리를 대체

#### 해결 방법

**docker-compose.dev.yml 수정:**
```yaml
# Before
spring-boot-blue-dev:
  build:
    context: ./backend/spring-boot
    dockerfile: Dockerfile
  volumes:
    - ./backend/spring-boot:/app  # 이 부분 제거
  # ...

# After
spring-boot-blue-dev:
  build:
    context: ./backend/spring-boot
    dockerfile: Dockerfile
  # volumes 제거
  # ...
```

#### Dockerfile 구조 분석
```dockerfile
# Stage 1: Build
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn dependency:go-offline -B
COPY src ./src
RUN mvn clean package -DskipTests

# Stage 2: Runtime
FROM eclipse-temurin:17-jre-alpine
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar  # 이 파일이 volume으로 덮어씌워짐
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
```

#### 교훈
- Multi-stage build 사용 시 volume 마운트 위치 주의
- 개발 중 코드 변경이 필요하면 hot-reload 도구 사용 고려

---

### 문제 5: 포트 충돌

#### 원인 분석
```
Error response from daemon: failed to set up container networking:
driver failed programming external connectivity on endpoint spring-boot-blue-dev:
Bind for 0.0.0.0:18080 failed: port is already allocated
```

- Jenkins와 Spring Boot Blue가 동일한 포트(18080) 사용
- `.env.dev` 파일에 포트 설정 중복

#### 해결 방법

**.env.dev 수정:**
```bash
# Before
JENKINS_PORT=18080
BLUE_BACKEND_PORT=18080

# After
JENKINS_PORT=18090  # Jenkins 포트 변경
BLUE_BACKEND_PORT=18080
```

#### 포트 할당 현황
| 서비스 | 포트 | 용도 |
|--------|------|------|
| React Blue | 13000 | 개발 프론트엔드 |
| React Green | 13001 | 개발 프론트엔드 |
| MySQL | 13306 | 데이터베이스 |
| Zookeeper | 12181 | Kafka 조정 |
| FastAPI Blue | 18000 | API 서버 |
| FastAPI Green | 18001 | API 서버 |
| Spring Boot Blue | 18080 | API 서버 |
| Spring Boot Green | 18081 | API 서버 |
| Jenkins | 18090 | CI/CD |
| Adminer | 18888 | DB 관리 |
| Kafka | 19092 | 메시지 큐 |
| Qdrant | 16333, 16334 | 벡터 DB |

---

### 문제 6: Qdrant Unhealthy 상태

#### 원인 분석
- Health check에서 `wget` 명령어 사용
- Alpine 기반 이미지에 `wget` 미포함 가능성

#### 현재 상태
- 컨테이너는 정상 실행 중
- Health check만 실패 (서비스 자체는 작동)

#### 해결 방법 (선택사항)
Health check를 `curl`로 변경하거나 제거:
```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:6333/health"]
  # 또는 health check 비활성화
  # test: ["NONE"]
```

---

## ✅ 최종 결과

### 컨테이너 상태 확인

```bash
docker ps
```

```
CONTAINER ID   IMAGE                              STATUS
2cf77a197a0b   dev-spring-boot-blue-dev           Up (healthy)
919015639a6b   dev-spring-boot-green-dev          Up (healthy)
6f5caedda6b4   dev-fastapi-green-dev              Up (healthy)
d08a74e24bab   dev-fastapi-blue-dev               Up (healthy)
a04bc5d27561   confluentinc/cp-kafka:7.5.0        Up (health: starting)
91f68350f744   adminer:latest                     Up
e1f81a230b04   mysql:8.0                          Up (healthy)
1966db210e12   confluentinc/cp-zookeeper:latest   Up
e058f09fc70a   qdrant/qdrant:latest               Up (health: starting)
095af7b0ace8   dev-react-blue-dev                 Up
b1a0811ce773   dev-jenkins-dev                    Up
09765903660f   dev-react-green-dev                Up
```

### 해결된 문제 요약

| 문제 | 상태 | 해결 방법 |
|------|------|-----------|
| MySQL 재시작 | ✅ 해결 | `.env.dev` 파일 생성 |
| Kafka 재시작 | ✅ 해결 | 버전 7.5.0으로 고정 |
| React 재시작 | ✅ 해결 | `react-scripts` 버전 수정, lock 파일 재생성 |
| Spring Boot 재시작 | ✅ 해결 | Volume 마운트 제거 |
| 포트 충돌 | ✅ 해결 | Jenkins 포트 변경 |
| Qdrant Unhealthy | ⚠️ 부분 해결 | 서비스는 정상 작동, health check만 실패 |

---

## 🛡️ 예방 방법

### 1. 환경 설정 관리

#### .env 파일 체크리스트
```bash
# 프로젝트 루트에 .env.example 항상 유지
# 새 환경 설정 시 자동 복사 스크립트 작성

#!/bin/bash
# setup-env.sh
if [ ! -f .env.dev ]; then
    echo "Creating .env.dev from example..."
    cp .env.dev.example .env.dev
    echo "⚠️  Please update .env.dev with your configuration"
fi
```

### 2. Docker 이미지 버전 관리

#### 권장 사항
```yaml
# ❌ 피해야 할 방식
image: confluentinc/cp-kafka:latest

# ✅ 권장하는 방식
image: confluentinc/cp-kafka:7.5.0

# 또는 변수로 관리
image: confluentinc/cp-kafka:${KAFKA_VERSION:-7.5.0}
```

### 3. Volume 마운트 전략

#### 개발 환경
```yaml
# 소스 코드 hot-reload가 필요한 경우
volumes:
  - ./src:/app/src:ro  # read-only로 소스만 마운트
  # /app 전체를 마운트하지 않음

# 또는 개발용 Dockerfile 별도 작성
# Dockerfile.dev: nodemon, spring-boot-devtools 등 사용
```

#### 프로덕션 환경
```yaml
# Volume 마운트 없이 이미지에 모든 것 포함
# 빌드 시점에 모든 의존성 해결
```

### 4. 포트 관리

#### 포트 할당 규칙 문서화
```markdown
## 포트 할당 규칙

- 10000-11999: 데이터베이스 관련
  - 10000-10099: PostgreSQL
  - 11000-11099: Redis
  - 13306: MySQL

- 18000-18999: 애플리케이션 서버
  - 18000-18009: FastAPI
  - 18080-18089: Spring Boot
  - 18090-18099: CI/CD (Jenkins)

- 19000-19999: 메시징
  - 19092: Kafka
```

### 5. 헬스체크 표준화

```yaml
# 범용적인 health check 템플릿
healthcheck:
  test: ["CMD-SHELL", "wget --quiet --tries=1 --spider http://localhost:8080/health || exit 1"]
  interval: 30s
  timeout: 10s
  retries: 3
  start_period: 40s
```

### 6. 의존성 관리

#### package.json (Node.js)
```json
{
  "dependencies": {
    "react": "^18.2.0",  // 메이저 버전 고정
    "react-scripts": "5.0.1"  // 패치 버전까지 고정 (중요 패키지)
  }
}
```

#### pom.xml (Java)
```xml
<properties>
    <spring-boot.version>3.2.0</spring-boot.version>
</properties>
```

### 7. 로그 모니터링

#### 정기 헬스체크 스크립트
```bash
#!/bin/bash
# health-check.sh

echo "=== Docker Containers Health Check ==="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo -e "\n=== Failed Containers ==="
docker ps -a --filter "status=exited" --format "table {{.Names}}\t{{.Status}}"

echo -e "\n=== Unhealthy Containers ==="
docker ps --filter "health=unhealthy" --format "table {{.Names}}\t{{.Status}}"
```

### 8. 문서화

#### 필수 문서
1. `README.md`: 프로젝트 개요 및 시작 가이드
2. `SETUP.md`: 환경 설정 상세 가이드
3. `TROUBLESHOOTING.md`: 이 문서
4. `PORTS.md`: 포트 할당 현황
5. `.env.example`: 환경 변수 템플릿

---

## 📚 참고 자료

### 관련 문서
- [Docker Compose 공식 문서](https://docs.docker.com/compose/)
- [Kafka Configuration Reference](https://kafka.apache.org/documentation/#configuration)
- [Spring Boot Docker 가이드](https://spring.io/guides/gs/spring-boot-docker/)
- [React 프로덕션 배포](https://create-react-app.dev/docs/deployment/)

### 유용한 명령어

```bash
# 모든 컨테이너 상태 확인
docker-compose ps

# 특정 서비스 로그 실시간 확인
docker-compose logs -f <service-name>

# 컨테이너 재시작 (빌드 없이)
docker-compose restart <service-name>

# 컨테이너 재빌드 및 시작
docker-compose up -d --build <service-name>

# 모든 컨테이너 정지 및 제거
docker-compose down

# 볼륨까지 포함하여 모두 제거
docker-compose down -v

# 컨테이너 내부 접속
docker exec -it <container-name> /bin/bash  # 또는 /bin/sh
```

---

## 📝 변경 이력

| 날짜 | 작성자 | 내용 |
|------|--------|------|
| 2025-10-26 | Claude Code | 초기 문서 작성 - 컨테이너 재시작 문제 해결 |

---

**작성일**: 2025-10-26
**환경**: Docker Compose 개발 환경
**문서 버전**: 1.0
