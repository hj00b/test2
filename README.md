# DevOps 인프라 포팅 메뉴얼

이 문서는 GitLab + Jenkins CI/CD 파이프라인과 Docker 기반 마이크로서비스 아키텍처의 전체 구축 과정을 단계별로 안내합니다.

## 목차

1. [아키텍처 개요](#1-아키텍처-개요)
2. [사전 요구사항](#2-사전-요구사항)
3. [디렉토리 구조](#3-디렉토리-구조)
4. [환경 구성](#4-환경-구성)
5. [Let's Encrypt SSL 인증서 발급](#5-lets-encrypt-ssl-인증서-발급)
6. [GitLab 설정](#6-gitlab-설정)
7. [Jenkins 설정](#7-jenkins-설정)
8. [NGINX 리버스 프록시 설정](#8-nginx-리버스-프록시-설정)
9. [블루-그린 배포](#9-블루-그린-배포)
10. [백엔드 서비스 배포](#10-백엔드-서비스-배포)
11. [프론트엔드 배포](#11-프론트엔드-배포)
12. [모니터링 설정](#12-모니터링-설정)
13. [운영 가이드](#13-운영-가이드)

---

## 1. 아키텍처 개요

### 1.1 전체 구성도

```
[GitLab] --webhook--> [Jenkins] --build--> [Docker Registry]
                          |
                          v
                    [Deploy Script]
                          |
    +---------------------+----------------------+
    |                                           |
[NGINX (Blue)]                          [NGINX (Green)]
    |                                           |
    +-------------------------------------------+
                          |
        +-----------------+-----------------+
        |                 |                 |
   [Spring Boot]     [FastAPI]         [React]
        |                 |
        +--------+--------+
                 |
        +--------+--------+
        |        |        |
    [MySQL]  [Qdrant]  [Kafka]
```

### 1.2 주요 컴포넌트

- **GitLab**: 소스 코드 저장소 및 CI 트리거
- **Jenkins**: CI/CD 파이프라인 실행
- **NGINX**: TLS 종료, 리버스 프록시, 블루-그린 스위칭
- **Spring Boot**: Java 백엔드 API
- **FastAPI**: Python 백엔드 API (ML/경량 서비스)
- **React**: 프론트엔드 SPA
- **MySQL**: 관계형 데이터베이스
- **Qdrant**: 벡터 데이터베이스
- **Kafka**: 메시징 시스템

### 1.3 환경 분리 전략

- **운영 (Production)**: `master` 브랜치, 도메인 `api.example.com`, `www.example.com`
- **개발 (Development)**: `dev` 브랜치, 도메인 `dev-api.example.com`, `dev.example.com`

---

## 2. 사전 요구사항

### 2.1 시스템 요구사항

```bash
# OS: Ubuntu 20.04 LTS 이상 또는 CentOS 8 이상
# CPU: 최소 8 Core (운영: 16 Core 권장)
# RAM: 최소 16GB (운영: 32GB 권장)
# Disk: 최소 100GB SSD (운영: 500GB 이상)

# OS 버전 확인
cat /etc/os-release
lsb_release -a

# 시스템 리소스 확인
nproc  # CPU 코어 수
free -h  # 메모리
df -h  # 디스크
```

### 2.2 필수 소프트웨어 설치

#### Docker 설치

```bash
# Docker 설치 (Ubuntu)
sudo apt-get update
sudo apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

# Docker GPG 키 추가
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Docker 리포지토리 추가
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Docker 엔진 설치
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Docker 서비스 시작 및 활성화
sudo systemctl start docker
sudo systemctl enable docker

# 현재 사용자를 docker 그룹에 추가
sudo usermod -aG docker $USER
newgrp docker

# Docker 설치 확인
docker --version
docker compose version
```

#### Docker Compose 설치 (standalone)

```bash
# 최신 버전 확인: https://github.com/docker/compose/releases
DOCKER_COMPOSE_VERSION=v2.24.5

sudo curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose

sudo chmod +x /usr/local/bin/docker-compose

# 설치 확인
docker-compose --version
```

#### Git 설치

```bash
sudo apt-get install -y git
git --version
```

#### 기타 유틸리티

```bash
# jq (JSON 파서), curl, openssl
sudo apt-get install -y jq curl openssl

# certbot (Let's Encrypt)
sudo apt-get install -y certbot
```

### 2.3 도메인 설정

DNS 레코드를 설정합니다. 예시:

```
# 운영 환경
A    www.example.com          -> 운영 서버 IP
A    api.example.com          -> 운영 서버 IP
A    gitlab.example.com       -> 운영 서버 IP
A    jenkins.example.com      -> 운영 서버 IP

# 개발 환경
A    dev.example.com          -> 개발 서버 IP
A    dev-api.example.com      -> 개발 서버 IP
A    dev-gitlab.example.com   -> 개발 서버 IP
A    dev-jenkins.example.com  -> 개발 서버 IP
```

---

## 3. 디렉토리 구조

전체 프로젝트의 디렉토리 구조입니다.

```bash
# 프로젝트 디렉토리 생성
mkdir -p /home/hui4718/test2/{nginx/{conf.d,scripts,certs},jenkins/{pipelines,plugins},gitlab,backend/{spring-boot,fastapi},frontend/react,database/{mysql,qdrant},kafka,monitoring/{prometheus,grafana/dashboards},scripts}

# 구조 확인
tree -L 3
```

```
test2/
├── README.md
├── docker-compose.prod.yml
├── docker-compose.dev.yml
├── .env.prod.example
├── .env.dev.example
├── .gitignore
├── nginx/
│   ├── Dockerfile
│   ├── conf.d/
│   │   ├── default.conf
│   │   ├── blue-green.conf
│   │   └── ssl.conf
│   ├── scripts/
│   │   ├── init-letsencrypt.sh
│   │   └── switch-deployment.sh
│   └── certs/
├── jenkins/
│   ├── Dockerfile
│   ├── plugins.txt
│   └── pipelines/
│       ├── Jenkinsfile.backend
│       └── Jenkinsfile.frontend
├── gitlab/
│   ├── docker-compose.gitlab.yml
│   └── gitlab.rb
├── backend/
│   ├── spring-boot/
│   │   ├── Dockerfile
│   │   ├── Dockerfile.prod
│   │   └── application.yml
│   └── fastapi/
│       ├── Dockerfile
│       ├── Dockerfile.prod
│       └── requirements.txt
├── frontend/
│   └── react/
│       ├── Dockerfile
│       ├── Dockerfile.prod
│       └── nginx.conf
├── database/
│   ├── mysql/
│   │   ├── Dockerfile
│   │   ├── init.sql
│   │   └── my.cnf
│   └── qdrant/
│       └── config.yaml
├── kafka/
│   └── docker-compose.kafka.yml
├── monitoring/
│   ├── prometheus/
│   │   └── prometheus.yml
│   └── grafana/
│       └── dashboards/
└── scripts/
    ├── deploy.sh
    ├── rollback.sh
    ├── health-check.sh
    └── backup.sh
```

---

## 4. 환경 구성

### 4.1 환경 변수 파일 생성

#### 운영 환경 (.env.prod)

```bash
cat > .env.prod.example << 'EOF'
# 운영 환경 설정
ENVIRONMENT=production
COMPOSE_PROJECT_NAME=prod

# 도메인
DOMAIN_FRONTEND=www.example.com
DOMAIN_API=api.example.com
DOMAIN_GITLAB=gitlab.example.com
DOMAIN_JENKINS=jenkins.example.com

# SSL/TLS
SSL_EMAIL=admin@example.com
CERTBOT_STAGING=0

# MySQL
MYSQL_ROOT_PASSWORD=CHANGE_ME_PROD_ROOT_PASSWORD
MYSQL_DATABASE=prod_db
MYSQL_USER=prod_user
MYSQL_PASSWORD=CHANGE_ME_PROD_PASSWORD
MYSQL_PORT=3306

# Spring Boot
SPRING_PROFILE=prod
SPRING_PORT=8080
SPRING_DB_URL=jdbc:mysql://mysql-prod:3306/prod_db
SPRING_DB_USERNAME=prod_user
SPRING_DB_PASSWORD=CHANGE_ME_PROD_PASSWORD

# FastAPI
FASTAPI_ENV=production
FASTAPI_PORT=8000
FASTAPI_DB_URL=mysql+pymysql://prod_user:CHANGE_ME_PROD_PASSWORD@mysql-prod:3306/prod_db

# Qdrant
QDRANT_PORT=6333
QDRANT_GRPC_PORT=6334

# Kafka
KAFKA_BROKER_ID=1
KAFKA_ZOOKEEPER_CONNECT=zookeeper-prod:2181
KAFKA_LISTENERS=PLAINTEXT://0.0.0.0:9092
KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://kafka-prod:9092

# Jenkins
JENKINS_ADMIN_USER=admin
JENKINS_ADMIN_PASSWORD=CHANGE_ME_JENKINS_PASSWORD
JENKINS_PORT=8080

# GitLab
GITLAB_ROOT_PASSWORD=CHANGE_ME_GITLAB_PASSWORD
GITLAB_PORT=80
GITLAB_SSH_PORT=22

# Docker Registry
DOCKER_REGISTRY=registry.example.com
DOCKER_REGISTRY_USER=registry_user
DOCKER_REGISTRY_PASSWORD=CHANGE_ME_REGISTRY_PASSWORD

# Blue-Green Deployment
ACTIVE_ENVIRONMENT=blue
BLUE_BACKEND_PORT=8080
GREEN_BACKEND_PORT=8081
EOF
```

#### 개발 환경 (.env.dev)

```bash
cat > .env.dev.example << 'EOF'
# 개발 환경 설정
ENVIRONMENT=development
COMPOSE_PROJECT_NAME=dev

# 도메인
DOMAIN_FRONTEND=dev.example.com
DOMAIN_API=dev-api.example.com
DOMAIN_GITLAB=dev-gitlab.example.com
DOMAIN_JENKINS=dev-jenkins.example.com

# SSL/TLS
SSL_EMAIL=dev@example.com
CERTBOT_STAGING=1

# MySQL
MYSQL_ROOT_PASSWORD=dev_root_password
MYSQL_DATABASE=dev_db
MYSQL_USER=dev_user
MYSQL_PASSWORD=dev_password
MYSQL_PORT=13306

# Spring Boot
SPRING_PROFILE=dev
SPRING_PORT=18080
SPRING_DB_URL=jdbc:mysql://mysql-dev:3306/dev_db
SPRING_DB_USERNAME=dev_user
SPRING_DB_PASSWORD=dev_password

# FastAPI
FASTAPI_ENV=development
FASTAPI_PORT=18000
FASTAPI_DB_URL=mysql+pymysql://dev_user:dev_password@mysql-dev:3306/dev_db

# Qdrant
QDRANT_PORT=16333
QDRANT_GRPC_PORT=16334

# Kafka
KAFKA_BROKER_ID=1
KAFKA_ZOOKEEPER_CONNECT=zookeeper-dev:2181
KAFKA_LISTENERS=PLAINTEXT://0.0.0.0:9092
KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://kafka-dev:9092

# Jenkins
JENKINS_ADMIN_USER=admin
JENKINS_ADMIN_PASSWORD=dev_jenkins_password
JENKINS_PORT=18080

# GitLab
GITLAB_ROOT_PASSWORD=dev_gitlab_password
GITLAB_PORT=80
GITLAB_SSH_PORT=2222

# Docker Registry
DOCKER_REGISTRY=dev-registry.example.com
DOCKER_REGISTRY_USER=dev_registry_user
DOCKER_REGISTRY_PASSWORD=dev_registry_password

# Blue-Green Deployment
ACTIVE_ENVIRONMENT=blue
BLUE_BACKEND_PORT=18080
GREEN_BACKEND_PORT=18081
EOF
```

### 4.2 환경 변수 파일 복사 및 수정

```bash
# 운영 환경
cp .env.prod.example .env.prod
# .env.prod 파일을 열어서 실제 값으로 변경
nano .env.prod

# 개발 환경
cp .env.dev.example .env.dev
# .env.dev 파일을 열어서 실제 값으로 변경
nano .env.dev
```

### 4.3 .gitignore 설정

```bash
cat > .gitignore << 'EOF'
# 환경 변수 파일
.env
.env.prod
.env.dev
*.env

# SSL 인증서
nginx/certs/*.pem
nginx/certs/*.key
nginx/certs/*.crt

# 로그 파일
*.log
logs/

# 데이터 볼륨
data/
volumes/

# IDE
.idea/
.vscode/
*.swp
*.swo

# OS
.DS_Store
Thumbs.db

# Secrets
secrets/
*.secret

# Jenkins
jenkins/secrets/
jenkins/.jenkins/

# GitLab
gitlab/config/
gitlab/logs/
gitlab/data/
EOF
```

---

## 5. Let's Encrypt SSL 인증서 발급

### 5.1 Certbot 초기화 스크립트 생성

```bash
cat > nginx/scripts/init-letsencrypt.sh << 'EOF'
#!/bin/bash

# Let's Encrypt 인증서 초기화 스크립트
# 사용법: ./init-letsencrypt.sh <도메인> <이메일> [staging]

set -e

DOMAIN=$1
EMAIL=$2
STAGING=${3:-0}  # 0=production, 1=staging

if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
    echo "사용법: $0 <도메인> <이메일> [staging]"
    echo "예시: $0 example.com admin@example.com"
    exit 1
fi

DATA_PATH="./nginx/certs"
RSA_KEY_SIZE=4096

# 기존 데이터 확인
if [ -d "$DATA_PATH/live/$DOMAIN" ]; then
    read -p "기존 인증서가 존재합니다. 삭제하고 재발급하시겠습니까? (y/N) " decision
    if [ "$decision" != "Y" ] && [ "$decision" != "y" ]; then
        exit 0
    fi
    sudo rm -rf "$DATA_PATH/live/$DOMAIN"
    sudo rm -rf "$DATA_PATH/archive/$DOMAIN"
    sudo rm -rf "$DATA_PATH/renewal/$DOMAIN.conf"
fi

echo "### Certbot 디렉토리 생성..."
sudo mkdir -p "$DATA_PATH/live/$DOMAIN"
sudo mkdir -p "$DATA_PATH/www"

echo "### 더미 인증서 생성 (NGINX 초기 구동용)..."
CERT_PATH="/etc/letsencrypt/live/$DOMAIN"
sudo openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
    -keyout "$DATA_PATH/live/$DOMAIN/privkey.pem" \
    -out "$DATA_PATH/live/$DOMAIN/fullchain.pem" \
    -subj "/CN=$DOMAIN"

echo "### NGINX 시작..."
docker-compose up -d nginx

echo "### 더미 인증서 삭제..."
sudo rm -rf "$DATA_PATH/live/$DOMAIN"

echo "### Let's Encrypt 인증서 발급 요청..."

STAGING_ARG=""
if [ $STAGING != "0" ]; then
    STAGING_ARG="--staging"
    echo "### Staging 모드로 발급합니다 (테스트용)"
fi

docker-compose run --rm --entrypoint "\
    certbot certonly --webroot -w /var/www/certbot \
    $STAGING_ARG \
    -d $DOMAIN \
    --email $EMAIL \
    --rsa-key-size $RSA_KEY_SIZE \
    --agree-tos \
    --non-interactive \
    --force-renewal" certbot

echo "### NGINX 재시작..."
docker-compose restart nginx

echo "### 인증서 발급 완료!"
echo "### 인증서 위치: $DATA_PATH/live/$DOMAIN/"
EOF

chmod +x nginx/scripts/init-letsencrypt.sh
```

### 5.2 인증서 자동 갱신 설정

```bash
cat > nginx/scripts/renew-certificates.sh << 'EOF'
#!/bin/bash

# Let's Encrypt 인증서 자동 갱신 스크립트

set -e

echo "### Let's Encrypt 인증서 갱신 시작..."

docker-compose run --rm certbot renew

echo "### NGINX 리로드..."
docker-compose exec nginx nginx -s reload

echo "### 인증서 갱신 완료!"
EOF

chmod +x nginx/scripts/renew-certificates.sh
```

### 5.3 Cron 작업 등록 (자동 갱신)

```bash
# Cron 작업 추가 (매일 오전 3시 실행)
(crontab -l 2>/dev/null; echo "0 3 * * * cd /home/hui4718/test2 && ./nginx/scripts/renew-certificates.sh >> /var/log/letsencrypt-renew.log 2>&1") | crontab -

# Cron 작업 확인
crontab -l
```

### 5.4 다중 도메인 인증서 발급

```bash
cat > nginx/scripts/init-multi-domain.sh << 'EOF'
#!/bin/bash

# 다중 도메인 Let's Encrypt 인증서 발급 스크립트

set -e

# 환경 변수 로드
if [ -f .env.prod ]; then
    export $(cat .env.prod | grep -v '^#' | xargs)
fi

DOMAINS=(
    "$DOMAIN_FRONTEND"
    "$DOMAIN_API"
    "$DOMAIN_GITLAB"
    "$DOMAIN_JENKINS"
)

EMAIL="${SSL_EMAIL}"
STAGING="${CERTBOT_STAGING:-0}"

for DOMAIN in "${DOMAINS[@]}"; do
    echo "### 도메인 인증서 발급: $DOMAIN"
    ./nginx/scripts/init-letsencrypt.sh "$DOMAIN" "$EMAIL" "$STAGING"
    sleep 5
done

echo "### 모든 도메인 인증서 발급 완료!"
EOF

chmod +x nginx/scripts/init-multi-domain.sh
```

---

## 6. GitLab 설정

### 6.1 GitLab Docker Compose 파일 생성

```bash
cat > gitlab/docker-compose.gitlab.yml << 'EOF'
version: '3.8'

services:
  gitlab:
    image: gitlab/gitlab-ce:latest
    container_name: gitlab
    restart: always
    hostname: '${DOMAIN_GITLAB}'
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'https://${DOMAIN_GITLAB}'
        gitlab_rails['gitlab_shell_ssh_port'] = ${GITLAB_SSH_PORT}

        # SSL 설정 (NGINX 프록시 사용 시)
        nginx['listen_port'] = 80
        nginx['listen_https'] = false
        nginx['proxy_set_headers'] = {
          "X-Forwarded-Proto" => "https",
          "X-Forwarded-Ssl" => "on"
        }

        # 이메일 설정
        gitlab_rails['smtp_enable'] = true
        gitlab_rails['smtp_address'] = "smtp.gmail.com"
        gitlab_rails['smtp_port'] = 587
        gitlab_rails['smtp_user_name'] = "your-email@gmail.com"
        gitlab_rails['smtp_password'] = "your-app-password"
        gitlab_rails['smtp_domain'] = "smtp.gmail.com"
        gitlab_rails['smtp_authentication'] = "login"
        gitlab_rails['smtp_enable_starttls_auto'] = true
        gitlab_rails['smtp_tls'] = false

        # 기본 프로젝트 기능
        gitlab_rails['gitlab_default_projects_features_issues'] = true
        gitlab_rails['gitlab_default_projects_features_merge_requests'] = true
        gitlab_rails['gitlab_default_projects_features_wiki'] = true
        gitlab_rails['gitlab_default_projects_features_snippets'] = true
        gitlab_rails['gitlab_default_projects_features_builds'] = true

        # 백업 설정
        gitlab_rails['backup_keep_time'] = 604800  # 7일

    ports:
      - '${GITLAB_PORT}:80'
      - '${GITLAB_SSH_PORT}:22'
    volumes:
      - gitlab_config:/etc/gitlab
      - gitlab_logs:/var/log/gitlab
      - gitlab_data:/var/opt/gitlab
    shm_size: '256m'
    networks:
      - devops-network

volumes:
  gitlab_config:
  gitlab_logs:
  gitlab_data:

networks:
  devops-network:
    driver: bridge
EOF
```

### 6.2 GitLab 시작

```bash
# 환경 변수 로드
export $(cat .env.prod | grep -v '^#' | xargs)

# GitLab 시작
cd gitlab
docker-compose -f docker-compose.gitlab.yml up -d

# 로그 확인
docker-compose -f docker-compose.gitlab.yml logs -f gitlab

# GitLab 초기화 대기 (약 5-10분 소요)
# 준비 상태 확인
docker exec -it gitlab gitlab-ctl status
```

### 6.3 GitLab 초기 설정

```bash
# 1. 브라우저에서 https://gitlab.example.com 접속
# 2. 초기 root 비밀번호 확인
docker exec -it gitlab cat /etc/gitlab/initial_root_password

# 3. root 계정으로 로그인 후 비밀번호 변경
# 4. 새 프로젝트 생성 또는 기존 프로젝트 import
```

### 6.4 GitLab Webhook 설정

GitLab에서 코드 푸시 시 Jenkins 빌드를 자동으로 트리거하는 Webhook을 설정합니다.

**상세 가이드:** [📘 GitLab Webhook 설정 완전 가이드](docs/GITLAB_WEBHOOK_SETUP.md)

#### 빠른 설정 (자동화 스크립트)

```bash
# 1. Webhook Secret Token 생성
WEBHOOK_SECRET=$(openssl rand -hex 32)
echo "Secret Token: $WEBHOOK_SECRET"

# 2. 자동 설정 스크립트 실행
cd gitlab/scripts
chmod +x setup-webhook.sh

./setup-webhook.sh \
  https://gitlab.example.com \
  <PROJECT_ID> \
  <GITLAB_ACCESS_TOKEN> \
  https://jenkins.example.com/generic-webhook-trigger/invoke \
  $WEBHOOK_SECRET
```

#### 수동 설정 (GitLab UI)

```bash
# GitLab 프로젝트: Settings > Webhooks

URL: https://jenkins.example.com/generic-webhook-trigger/invoke
Secret Token: (생성한 Secret Token 입력)

Trigger:
  ✓ Push events (Branch filter: master,dev)
  ✓ Tag push events
  ✓ Merge request events

Enable SSL verification: ✓

Add webhook 클릭
```

#### 테스트

```bash
# GitLab에서 Webhook 테스트
# Settings > Webhooks > Test > Push events

# 예상 응답: HTTP 200 OK

# 실제 Push 테스트
git push origin master  # Jenkins 빌드 자동 시작
```

**관련 파일:**
- `gitlab/scripts/setup-webhook.sh` - 자동 설정 스크립트
- `gitlab/webhook-config.example.json` - 설정 예시
- `jenkins/job-configs/webhook-job-dsl.groovy` - Jenkins Job DSL
- `jenkins/job-configs/Jenkinsfile.webhook-example` - Pipeline 예시

### 6.5 GitLab Access Token 생성

```bash
# Jenkins에서 GitLab 접근용 Personal Access Token 생성
# GitLab 웹 UI: User Settings > Access Tokens

Token name: jenkins-integration
Scopes:
  ✓ api
  ✓ read_repository
  ✓ write_repository

생성 후 토큰 복사 (한 번만 표시됨)

# Jenkins Credentials에 저장:
# Jenkins > Manage Jenkins > Credentials > Global
# Kind: GitLab API token
# ID: gitlab-api-token
```

---

## 7. Jenkins 설정

### 7.1 Jenkins Dockerfile

```bash
cat > jenkins/Dockerfile << 'EOF'
FROM jenkins/jenkins:lts

USER root

# Docker CLI 설치 (Docker-in-Docker)
RUN apt-get update && \
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | \
        gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
        https://download.docker.com/linux/debian $(lsb_release -cs) stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && \
    apt-get install -y docker-ce-cli && \
    rm -rf /var/lib/apt/lists/*

# Docker Compose 설치
RUN curl -L "https://github.com/docker/compose/releases/download/v2.24.5/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose && \
    chmod +x /usr/local/bin/docker-compose

# kubectl 설치 (Kubernetes 사용 시)
RUN curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# 기타 유틸리티
RUN apt-get update && \
    apt-get install -y jq git && \
    rm -rf /var/lib/apt/lists/*

USER jenkins

# Jenkins 플러그인 설치
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt
EOF
```

### 7.2 Jenkins 플러그인 목록

```bash
cat > jenkins/plugins.txt << 'EOF'
git:latest
gitlab-plugin:latest
docker-plugin:latest
docker-workflow:latest
pipeline-stage-view:latest
workflow-aggregator:latest
credentials-binding:latest
blueocean:latest
generic-webhook-trigger:latest
pipeline-utility-steps:latest
slack:latest
email-ext:latest
prometheus:latest
EOF
```

### 7.3 Jenkins Docker Compose (운영 환경에 통합)

Jenkins는 메인 docker-compose 파일에 포함됩니다 (다음 섹션 참조).

### 7.4 Jenkins 초기 설정

```bash
# Jenkins 초기 비밀번호 확인
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword

# 브라우저에서 https://jenkins.example.com 접속
# 초기 비밀번호 입력 후 추천 플러그인 설치

# 관리자 계정 생성
# Username: admin
# Password: (강력한 비밀번호)
```

### 7.5 Jenkins Credentials 설정

```bash
# Jenkins 웹 UI: Manage Jenkins > Manage Credentials

# 1. GitLab Access Token
#    Kind: GitLab API token
#    ID: gitlab-api-token
#    API token: <GitLab에서 생성한 토큰>

# 2. Docker Registry Credentials
#    Kind: Username with password
#    ID: docker-registry-credentials
#    Username: <레지스트리 사용자명>
#    Password: <레지스트리 비밀번호>

# 3. SSH Private Key (배포 서버 접근용)
#    Kind: SSH Username with private key
#    ID: deploy-server-ssh
#    Username: deploy
#    Private Key: <SSH 개인키>

# 4. Webhook Secret Token
#    Kind: Secret text
#    ID: gitlab-webhook-secret
#    Secret: <openssl rand -hex 32로 생성한 토큰>
```

---

## 8. NGINX 리버스 프록시 설정

### 8.1 NGINX Dockerfile

```bash
cat > nginx/Dockerfile << 'EOF'
FROM nginx:alpine

# Certbot 설치
RUN apk add --no-cache certbot certbot-nginx

# 설정 파일 복사
COPY conf.d/ /etc/nginx/conf.d/

# 스크립트 복사
COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh

# 헬스체크 추가
HEALTHCHECK --interval=30s --timeout=3s \
    CMD wget --quiet --tries=1 --spider http://localhost/health || exit 1

EXPOSE 80 443

CMD ["nginx", "-g", "daemon off;"]
EOF
```

### 8.2 NGINX 메인 설정

```bash
cat > nginx/conf.d/default.conf << 'EOF'
# 헬스체크 엔드포인트
server {
    listen 80;
    server_name localhost;

    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}

# HTTP -> HTTPS 리다이렉트
server {
    listen 80;
    server_name ${DOMAIN_FRONTEND} ${DOMAIN_API} ${DOMAIN_GITLAB} ${DOMAIN_JENKINS};

    # Let's Encrypt ACME 챌린지
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}
EOF
```

### 8.3 NGINX SSL 설정

```bash
cat > nginx/conf.d/ssl.conf << 'EOF'
# SSL 프론트엔드 (React)
server {
    listen 443 ssl http2;
    server_name ${DOMAIN_FRONTEND};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN_FRONTEND}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN_FRONTEND}/privkey.pem;

    include /etc/nginx/conf.d/ssl-params.conf;

    # React 정적 파일
    location / {
        proxy_pass http://react-${ACTIVE_ENVIRONMENT}:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

# SSL API 백엔드
server {
    listen 443 ssl http2;
    server_name ${DOMAIN_API};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN_API}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN_API}/privkey.pem;

    include /etc/nginx/conf.d/ssl-params.conf;

    # Spring Boot API
    location /api/v1/ {
        proxy_pass http://spring-boot-${ACTIVE_ENVIRONMENT}:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # FastAPI
    location /api/v2/ {
        proxy_pass http://fastapi-${ACTIVE_ENVIRONMENT}:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

# SSL GitLab
server {
    listen 443 ssl http2;
    server_name ${DOMAIN_GITLAB};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN_GITLAB}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN_GITLAB}/privkey.pem;

    include /etc/nginx/conf.d/ssl-params.conf;

    location / {
        proxy_pass http://gitlab:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # GitLab specific
        proxy_set_header X-Forwarded-Ssl on;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_http_version 1.1;

        client_max_body_size 0;
        proxy_read_timeout 300;
    }
}

# SSL Jenkins
server {
    listen 443 ssl http2;
    server_name ${DOMAIN_JENKINS};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN_JENKINS}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN_JENKINS}/privkey.pem;

    include /etc/nginx/conf.d/ssl-params.conf;

    location / {
        proxy_pass http://jenkins:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Jenkins specific
        proxy_set_header X-Forwarded-Port 443;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_http_version 1.1;
        proxy_set_header Connection "";

        client_max_body_size 50m;
        proxy_read_timeout 90;
    }
}
EOF
```

### 8.4 SSL 파라미터 설정

```bash
cat > nginx/conf.d/ssl-params.conf << 'EOF'
# SSL 설정
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers on;
ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
ssl_ecdh_curve secp384r1;
ssl_session_timeout 10m;
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off;
ssl_stapling on;
ssl_stapling_verify on;

# 보안 헤더
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
add_header X-Frame-Options DENY always;
add_header X-Content-Type-Options nosniff always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "no-referrer-when-downgrade" always;

# Resolver (DNS)
resolver 8.8.8.8 8.8.4.4 valid=300s;
resolver_timeout 5s;
EOF
```

---

## 9. 블루-그린 배포

### 9.1 개요

블루-그린 배포는 무중단 배포 전략으로, Blue와 Green 두 개의 동일한 환경을 유지하면서 트래픽을 전환합니다.

**핵심 구성 요소:**
- NGINX: 트래픽 라우팅 담당 (`active-env.conf`로 제어)
- Blue/Green 컨테이너: 각 서비스(Spring Boot, FastAPI, React)의 두 벌 인스턴스
- 트래픽 전환 스크립트: `nginx/scripts/switch-deployment.sh`
- 헬스체크 스크립트: `scripts/health-check.sh`

**상세 가이드:** [docs/BLUE_GREEN_DEPLOYMENT.md](docs/BLUE_GREEN_DEPLOYMENT.md)

### 9.2 NGINX 설정

NGINX가 `active-env.conf` 파일을 읽어서 Blue 또는 Green으로 트래픽을 라우팅합니다.

```bash
# nginx/conf.d/active-env.conf
set $active_env "blue";  # 또는 "green"
```

### 9.3 빠른 시작 가이드

#### 스크립트 실행 권한 설정

```bash
# 모든 스크립트 실행 가능하게 만들기
chmod +x scripts/setup-permissions.sh
./scripts/setup-permissions.sh
```

#### 배포 프로세스

```bash
# 1. Green 환경에 새 버전 배포 (Jenkins 또는 수동)
docker-compose -f docker-compose.prod.yml up -d \
  spring-boot-green \
  fastapi-green \
  react-green

# 2. Green 환경 헬스체크
./scripts/health-check.sh green

# 3. 트래픽 전환 (Blue → Green)
./nginx/scripts/switch-deployment.sh green

# 4. 문제 발생 시 즉시 롤백
./nginx/scripts/switch-deployment.sh blue
```

#### Jenkins를 통한 자동 배포

```bash
# 1. GitLab에 코드 푸시
git push origin master  # 운영 환경

# 2. Jenkins 파이프라인 자동 실행
#    - 빌드 & 테스트
#    - Docker 이미지 빌드
#    - Green 환경에 배포
#    - 헬스체크 수행

# 3. 수동 승인 후 트래픽 전환
#    Jenkins에서 "Switch Traffic" 승인
```

### 9.4 주요 스크립트

#### 트래픽 전환 스크립트

파일: `nginx/scripts/switch-deployment.sh`

**기능:**
- Blue/Green 환경 헬스체크
- `active-env.conf` 파일 업데이트
- NGINX 설정 테스트 및 리로드
- 실패 시 자동 롤백

**사용법:**
```bash
./nginx/scripts/switch-deployment.sh green  # Green으로 전환
./nginx/scripts/switch-deployment.sh blue   # Blue로 롤백
```

#### 헬스체크 스크립트

파일: `scripts/health-check.sh`

**기능:**
- 모든 서비스 컨테이너 실행 확인
- 헬스 엔드포인트 응답 확인
- 리소스 사용량 모니터링
- 에러 로그 확인

**사용법:**
```bash
./scripts/health-check.sh green  # Green 환경 체크
./scripts/health-check.sh blue   # Blue 환경 체크
./scripts/health-check.sh        # 현재 활성 환경 체크
```

### 9.5 배포 시나리오

**정상 배포 흐름:**
```
1. 초기: Blue 활성 (사용자 트래픽)
         Green 대기

2. 배포: Blue 활성 (계속 서비스)
         Green 새 버전 배포 중

3. 준비: Blue 활성 (계속 서비스)
         Green 헬스체크 통과 ✓

4. 전환: Blue 대기
         Green 활성 (사용자 트래픽 전환)

5. 완료: Blue 롤백 대기
         Green 운영 중
```

**롤백 흐름:**
```
문제 발견 → ./nginx/scripts/switch-deployment.sh blue → 즉시 복구 (5-10초)
```

### 9.6 모니터링

```bash
# 현재 활성 환경 확인
cat nginx/conf.d/active-env.conf

# 컨테이너 상태 확인
docker ps --filter "name=spring-boot"
docker ps --filter "name=fastapi"
docker ps --filter "name=react"

# 로그 확인
docker logs -f spring-boot-blue
docker logs -f spring-boot-green
```

### 9.7 상세 문서

블루-그린 배포의 상세한 작동 원리, 트러블슈팅 가이드, 롤백 절차는 다음 문서를 참조하세요:

**[📘 블루-그린 배포 완전 가이드](docs/BLUE_GREEN_DEPLOYMENT.md)**

이 문서에는 다음 내용이 포함되어 있습니다:
- 아키텍처 상세 설명
- Jenkins 파이프라인 통합
- NGINX 라우팅 메커니즘
- 트러블슈팅 가이드
- 롤백 절차
- 실제 사용 예시

---

**(계속됩니다...)**

이 README.md는 매우 길어서 여러 부분으로 나누어 작성하고 있습니다. 다음 섹션들을 계속 작성하겠습니다.

## 10. 백엔드 서비스 배포

### 10.1 Spring Boot Dockerfile

```bash
cat > backend/spring-boot/Dockerfile << 'EOF'
# 개발 환경용 Dockerfile
FROM maven:3.9-eclipse-temurin-17 AS build

WORKDIR /app

# 의존성 다운로드 (캐싱 최적화)
COPY pom.xml .
RUN mvn dependency:go-offline -B

# 소스 복사 및 빌드
COPY src ./src
RUN mvn clean package -DskipTests

FROM eclipse-temurin:17-jre-alpine

WORKDIR /app

# 빌드된 JAR 파일 복사
COPY --from=build /app/target/*.jar app.jar

# 헬스체크
HEALTHCHECK --interval=30s --timeout=3s \
    CMD wget --quiet --tries=1 --spider http://localhost:8080/actuator/health || exit 1

EXPOSE 8080

ENTRYPOINT ["java", "-jar", "/app/app.jar"]
EOF
```

### 10.2 Spring Boot 운영 환경 Dockerfile

```bash
cat > backend/spring-boot/Dockerfile.prod << 'EOF'
# 운영 환경용 최적화 Dockerfile
FROM maven:3.9-eclipse-temurin-17 AS build

WORKDIR /app

# 의존성 다운로드
COPY pom.xml .
RUN mvn dependency:go-offline -B

# 소스 복사 및 빌드
COPY src ./src
RUN mvn clean package -DskipTests -Pprod

FROM eclipse-temurin:17-jre-alpine

# 보안 및 성능 최적화
RUN addgroup -S spring && adduser -S spring -G spring

WORKDIR /app

# 빌드된 JAR 파일 복사
COPY --from=build --chown=spring:spring /app/target/*.jar app.jar

USER spring

# JVM 최적화
ENV JAVA_OPTS="-Xms512m -Xmx2g -XX:+UseG1GC -XX:MaxGCPauseMillis=200"

# 헬스체크
HEALTHCHECK --interval=30s --timeout=3s --start-period=60s \
    CMD wget --quiet --tries=1 --spider http://localhost:8080/actuator/health || exit 1

EXPOSE 8080

ENTRYPOINT exec java $JAVA_OPTS -jar /app/app.jar
EOF
```

### 10.3 Spring Boot 설정 파일

```bash
cat > backend/spring-boot/application.yml << 'EOF'
spring:
  application:
    name: spring-boot-api
  
  profiles:
    active: ${SPRING_PROFILE:dev}

  datasource:
    url: ${SPRING_DB_URL}
    username: ${SPRING_DB_USERNAME}
    password: ${SPRING_DB_PASSWORD}
    driver-class-name: com.mysql.cj.jdbc.Driver
    hikari:
      maximum-pool-size: 20
      minimum-idle: 5
      connection-timeout: 30000

  jpa:
    hibernate:
      ddl-auto: validate
    show-sql: false
    properties:
      hibernate:
        format_sql: true
        dialect: org.hibernate.dialect.MySQL8Dialect

  kafka:
    bootstrap-servers: ${KAFKA_BOOTSTRAP_SERVERS:kafka:9092}
    producer:
      key-serializer: org.apache.kafka.common.serialization.StringSerializer
      value-serializer: org.springframework.kafka.support.serializer.JsonSerializer
    consumer:
      key-deserializer: org.apache.kafka.common.serialization.StringDeserializer
      value-deserializer: org.springframework.kafka.support.serializer.JsonDeserializer
      group-id: spring-boot-consumer-group

# Actuator (헬스체크, 메트릭)
management:
  endpoints:
    web:
      exposure:
        include: health,info,metrics,prometheus
  endpoint:
    health:
      show-details: always
  metrics:
    export:
      prometheus:
        enabled: true

server:
  port: 8080
  shutdown: graceful

logging:
  level:
    root: INFO
    com.example: DEBUG
  pattern:
    console: "%d{yyyy-MM-dd HH:mm:ss} - %logger{36} - %msg%n"
EOF
```

### 10.4 FastAPI Dockerfile

```bash
cat > backend/fastapi/Dockerfile << 'EOF'
# 개발 환경용 Dockerfile
FROM python:3.11-slim

WORKDIR /app

# 시스템 의존성 설치
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        gcc \
        g++ \
        curl && \
    rm -rf /var/lib/apt/lists/*

# Python 의존성 설치
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 소스 복사
COPY . .

# 헬스체크
HEALTHCHECK --interval=30s --timeout=3s \
    CMD curl -f http://localhost:8000/health || exit 1

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]
EOF
```

### 10.5 FastAPI 운영 환경 Dockerfile

```bash
cat > backend/fastapi/Dockerfile.prod << 'EOF'
# 운영 환경용 최적화 Dockerfile
FROM python:3.11-slim AS builder

WORKDIR /app

# 시스템 의존성 설치
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        gcc \
        g++ && \
    rm -rf /var/lib/apt/lists/*

# Python 의존성 설치
COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt

FROM python:3.11-slim

# 보안 최적화
RUN useradd -m -u 1000 fastapi && \
    apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 빌드된 의존성 복사
COPY --from=builder /root/.local /home/fastapi/.local
COPY --chown=fastapi:fastapi . .

USER fastapi

ENV PATH=/home/fastapi/.local/bin:$PATH

# 헬스체크
HEALTHCHECK --interval=30s --timeout=3s --start-period=30s \
    CMD curl -f http://localhost:8000/health || exit 1

EXPOSE 8000

CMD ["gunicorn", "main:app", "--workers", "4", "--worker-class", "uvicorn.workers.UvicornWorker", "--bind", "0.0.0.0:8000"]
EOF
```

### 10.6 FastAPI requirements.txt

```bash
cat > backend/fastapi/requirements.txt << 'EOF'
fastapi==0.109.0
uvicorn[standard]==0.27.0
gunicorn==21.2.0
pydantic==2.5.3
pydantic-settings==2.1.0
python-multipart==0.0.6
pymysql==1.1.0
sqlalchemy==2.0.25
kafka-python==2.0.2
qdrant-client==1.7.0
prometheus-client==0.19.0
httpx==0.26.0
python-jose[cryptography]==3.3.0
passlib[bcrypt]==1.7.4
python-dotenv==1.0.0
EOF
```

---

## 11. 프론트엔드 배포

### 11.1 React Dockerfile (개발)

```bash
cat > frontend/react/Dockerfile << 'EOF'
# 개발 환경용 Dockerfile
FROM node:20-alpine

WORKDIR /app

# 의존성 설치
COPY package*.json ./
RUN npm ci

# 소스 복사
COPY . .

EXPOSE 3000

CMD ["npm", "start"]
EOF
```

### 11.2 React Dockerfile (운영)

```bash
cat > frontend/react/Dockerfile.prod << 'EOF'
# 운영 환경용 Multi-stage 빌드
FROM node:20-alpine AS builder

WORKDIR /app

# 의존성 설치
COPY package*.json ./
RUN npm ci --only=production

# 소스 복사 및 빌드
COPY . .
RUN npm run build

# NGINX로 정적 파일 서빙
FROM nginx:alpine

# NGINX 설정 복사
COPY nginx.conf /etc/nginx/conf.d/default.conf

# 빌드된 정적 파일 복사
COPY --from=builder /app/build /usr/share/nginx/html

# 헬스체크
HEALTHCHECK --interval=30s --timeout=3s \
    CMD wget --quiet --tries=1 --spider http://localhost:80 || exit 1

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
EOF
```

### 11.3 React NGINX 설정

```bash
cat > frontend/react/nginx.conf << 'EOF'
server {
    listen 80;
    server_name localhost;

    root /usr/share/nginx/html;
    index index.html;

    # Gzip 압축
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/x-javascript application/xml+rss application/json application/javascript;

    # SPA 라우팅 지원
    location / {
        try_files $uri $uri/ /index.html;
    }

    # 정적 파일 캐싱
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    # 보안 헤더
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
}
EOF
```

---

## 12. 모니터링 설정

### 12.1 Prometheus 설정

```bash
cat > monitoring/prometheus/prometheus.yml << 'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: 'prod'
    environment: 'production'

# Alertmanager 설정
alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']

# 스크래핑 대상 설정
scrape_configs:
  # Prometheus 자체 메트릭
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  # NGINX 메트릭
  - job_name: 'nginx'
    static_configs:
      - targets: ['nginx:9113']

  # Spring Boot 메트릭
  - job_name: 'spring-boot-blue'
    metrics_path: '/actuator/prometheus'
    static_configs:
      - targets: ['spring-boot-blue:8080']
    relabel_configs:
      - source_labels: [__address__]
        target_label: instance
        replacement: 'spring-boot-blue'

  - job_name: 'spring-boot-green'
    metrics_path: '/actuator/prometheus'
    static_configs:
      - targets: ['spring-boot-green:8080']
    relabel_configs:
      - source_labels: [__address__]
        target_label: instance
        replacement: 'spring-boot-green'

  # FastAPI 메트릭
  - job_name: 'fastapi-blue'
    static_configs:
      - targets: ['fastapi-blue:8000']
    relabel_configs:
      - source_labels: [__address__]
        target_label: instance
        replacement: 'fastapi-blue'

  - job_name: 'fastapi-green'
    static_configs:
      - targets: ['fastapi-green:8000']
    relabel_configs:
      - source_labels: [__address__]
        target_label: instance
        replacement: 'fastapi-green'

  # MySQL 메트릭
  - job_name: 'mysql'
    static_configs:
      - targets: ['mysql-exporter:9104']

  # Kafka 메트릭
  - job_name: 'kafka'
    static_configs:
      - targets: ['kafka-exporter:9308']

  # Jenkins 메트릭
  - job_name: 'jenkins'
    metrics_path: '/prometheus/'
    static_configs:
      - targets: ['jenkins:8080']

  # Node Exporter (시스템 메트릭)
  - job_name: 'node-exporter'
    static_configs:
      - targets: ['node-exporter:9100']
EOF
```

### 12.2 Grafana 대시보드 설정

Grafana 대시보드는 웹 UI를 통해 설정하거나, JSON 파일로 import할 수 있습니다.

```bash
# 추천 Grafana 대시보드 ID
# - Node Exporter Full: 1860
# - Spring Boot: 12900
# - NGINX: 12708
# - MySQL: 7362
# - Kafka: 7589
```

---

## 13. 운영 가이드

### 13.1 전체 시스템 시작

```bash
# 운영 환경 시작
cd /home/hui4718/test2

# 환경 변수 로드
export $(cat .env.prod | grep -v '^#' | xargs)

# 모든 서비스 시작
docker-compose -f docker-compose.prod.yml up -d

# 로그 확인
docker-compose -f docker-compose.prod.yml logs -f
```

### 13.2 개발 환경 시작

```bash
# 개발 환경 시작
export $(cat .env.dev | grep -v '^#' | xargs)

docker-compose -f docker-compose.dev.yml up -d

# 특정 서비스만 재시작
docker-compose -f docker-compose.dev.yml restart spring-boot
```

### 13.3 배포 스크립트

```bash
cat > scripts/deploy.sh << 'EOF'
#!/bin/bash

# 자동 배포 스크립트
# 사용법: ./deploy.sh [backend|frontend|all] [blue|green] [prod|dev]

set -e

SERVICE_TYPE=$1
TARGET_ENV=$2
ENVIRONMENT=${3:-prod}

if [ -z "$SERVICE_TYPE" ] || [ -z "$TARGET_ENV" ]; then
    echo "사용법: $0 [backend|frontend|all] [blue|green] [prod|dev]"
    exit 1
fi

# 환경 변수 로드
if [ "$ENVIRONMENT" == "prod" ]; then
    export $(cat .env.prod | grep -v '^#' | xargs)
    COMPOSE_FILE="docker-compose.prod.yml"
else
    export $(cat .env.dev | grep -v '^#' | xargs)
    COMPOSE_FILE="docker-compose.dev.yml"
fi

echo "### 배포 시작: $SERVICE_TYPE ($TARGET_ENV 환경, $ENVIRONMENT)"

deploy_backend() {
    echo "### 백엔드 배포 중..."
    
    # 새 이미지 빌드
    docker-compose -f $COMPOSE_FILE build spring-boot-$TARGET_ENV fastapi-$TARGET_ENV
    
    # 컨테이너 재시작
    docker-compose -f $COMPOSE_FILE up -d spring-boot-$TARGET_ENV fastapi-$TARGET_ENV
    
    # 헬스체크 대기
    sleep 10
    ./scripts/health-check.sh $TARGET_ENV
    
    echo "### 백엔드 배포 완료"
}

deploy_frontend() {
    echo "### 프론트엔드 배포 중..."
    
    # 새 이미지 빌드
    docker-compose -f $COMPOSE_FILE build react-$TARGET_ENV
    
    # 컨테이너 재시작
    docker-compose -f $COMPOSE_FILE up -d react-$TARGET_ENV
    
    echo "### 프론트엔드 배포 완료"
}

case $SERVICE_TYPE in
    backend)
        deploy_backend
        ;;
    frontend)
        deploy_frontend
        ;;
    all)
        deploy_backend
        deploy_frontend
        ;;
    *)
        echo "오류: 서비스 타입은 'backend', 'frontend', 'all' 중 하나여야 합니다"
        exit 1
        ;;
esac

echo "### 배포 완료!"
echo "### 환경 전환을 원하시면: ./nginx/scripts/switch-deployment.sh $TARGET_ENV"
EOF

chmod +x scripts/deploy.sh
```

### 13.4 롤백 스크립트

```bash
cat > scripts/rollback.sh << 'EOF'
#!/bin/bash

# 롤백 스크립트
# 사용법: ./rollback.sh [blue|green] [prod|dev]

set -e

TARGET_ENV=$1
ENVIRONMENT=${2:-prod}

if [ -z "$TARGET_ENV" ]; then
    echo "사용법: $0 [blue|green] [prod|dev]"
    exit 1
fi

# 현재 활성 환경 확인
if [ "$ENVIRONMENT" == "prod" ]; then
    CURRENT_ENV=$(grep ACTIVE_ENVIRONMENT .env.prod | cut -d '=' -f2)
else
    CURRENT_ENV=$(grep ACTIVE_ENVIRONMENT .env.dev | cut -d '=' -f2)
fi

if [ "$TARGET_ENV" == "$CURRENT_ENV" ]; then
    echo "오류: $TARGET_ENV는 이미 활성 환경입니다"
    exit 1
fi

echo "### 롤백 시작: $CURRENT_ENV -> $TARGET_ENV"

# 환경 전환
./nginx/scripts/switch-deployment.sh $TARGET_ENV

echo "### 롤백 완료!"
EOF

chmod +x scripts/rollback.sh
```

### 13.5 백업 스크립트

```bash
cat > scripts/backup.sh << 'EOF'
#!/bin/bash

# 데이터베이스 및 볼륨 백업 스크립트
# 사용법: ./backup.sh [prod|dev]

set -e

ENVIRONMENT=${1:-prod}
BACKUP_DIR="/backup/$(date +%Y%m%d_%H%M%S)"

echo "### 백업 시작: $ENVIRONMENT 환경"

# 백업 디렉토리 생성
mkdir -p $BACKUP_DIR

# MySQL 백업
echo "### MySQL 백업 중..."
if [ "$ENVIRONMENT" == "prod" ]; then
    docker exec mysql-prod mysqldump -u root -p${MYSQL_ROOT_PASSWORD} --all-databases > $BACKUP_DIR/mysql_backup.sql
else
    docker exec mysql-dev mysqldump -u root -p${MYSQL_ROOT_PASSWORD} --all-databases > $BACKUP_DIR/mysql_backup.sql
fi

# GitLab 백업
echo "### GitLab 백업 중..."
docker exec gitlab gitlab-backup create

# 볼륨 백업
echo "### Docker 볼륨 백업 중..."
docker run --rm -v ${COMPOSE_PROJECT_NAME}_gitlab_data:/data -v $BACKUP_DIR:/backup alpine tar czf /backup/gitlab_data.tar.gz -C /data .

# Qdrant 백업
docker run --rm -v ${COMPOSE_PROJECT_NAME}_qdrant_data:/data -v $BACKUP_DIR:/backup alpine tar czf /backup/qdrant_data.tar.gz -C /data .

echo "### 백업 완료: $BACKUP_DIR"

# 오래된 백업 정리 (30일 이상)
find /backup -type d -mtime +30 -exec rm -rf {} +

echo "### 백업 정리 완료"
EOF

chmod +x scripts/backup.sh
```

### 13.6 시스템 모니터링 명령어

```bash
# 전체 컨테이너 상태 확인
docker ps -a

# 리소스 사용량 확인
docker stats

# 특정 서비스 로그 확인
docker-compose -f docker-compose.prod.yml logs -f spring-boot-blue

# 디스크 사용량 확인
df -h

# 네트워크 확인
docker network ls
docker network inspect prod_devops-network

# 볼륨 확인
docker volume ls
docker volume inspect prod_mysql_data
```

### 13.7 트러블슈팅

#### 컨테이너가 시작하지 않을 때

```bash
# 로그 확인
docker logs <container_name>

# 컨테이너 상세 정보 확인
docker inspect <container_name>

# 재시작
docker-compose -f docker-compose.prod.yml restart <service_name>
```

#### 포트 충돌 해결

```bash
# 포트 사용 중인 프로세스 확인
sudo lsof -i :<port_number>
sudo netstat -tulpn | grep <port_number>

# 프로세스 종료
sudo kill -9 <PID>
```

#### 디스크 공간 부족

```bash
# Docker 리소스 정리
docker system prune -a --volumes

# 사용하지 않는 이미지 삭제
docker image prune -a

# 로그 파일 정리
sudo truncate -s 0 /var/lib/docker/containers/*/*-json.log
```

#### SSL 인증서 갱신 실패

```bash
# Certbot 수동 갱신
docker-compose run --rm certbot renew --dry-run

# 강제 갱신
docker-compose run --rm certbot renew --force-renewal

# NGINX 재시작
docker-compose restart nginx
```

---

## 14. 보안 체크리스트

### 14.1 필수 보안 조치

- [ ] 모든 기본 비밀번호 변경
- [ ] 방화벽 설정 (UFW 또는 iptables)
- [ ] SSH 키 기반 인증 설정
- [ ] 불필요한 포트 차단
- [ ] Docker 소켓 권한 제한
- [ ] 정기적인 보안 업데이트
- [ ] SSL/TLS 인증서 자동 갱신 확인
- [ ] 로그 모니터링 설정
- [ ] 백업 자동화 및 복구 테스트
- [ ] GitLab/Jenkins 2FA 활성화

### 14.2 방화벽 설정

```bash
# UFW 설치 및 활성화
sudo apt-get install -y ufw

# 기본 정책 설정
sudo ufw default deny incoming
sudo ufw default allow outgoing

# SSH 허용
sudo ufw allow 22/tcp

# HTTP/HTTPS 허용
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# GitLab SSH 허용
sudo ufw allow 22/tcp

# 방화벽 활성화
sudo ufw enable

# 상태 확인
sudo ufw status verbose
```

---

## 15. 성능 최적화

### 15.1 Docker 성능 최적화

```bash
# Docker daemon 설정
cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "dns": ["8.8.8.8", "8.8.4.4"],
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 64000,
      "Soft": 64000
    }
  }
}
EOF

# Docker 재시작
sudo systemctl restart docker
```

### 15.2 시스템 튜닝

```bash
# /etc/sysctl.conf 설정
cat >> /etc/sysctl.conf << 'EOF'
# 네트워크 최적화
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535

# 파일 디스크립터 제한
fs.file-max = 2097152

# 가상 메모리
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
EOF

# 설정 적용
sudo sysctl -p
```

---

## 16. CI/CD 파이프라인 상세

### 16.1 Jenkins 파이프라인 (백엔드)

Jenkins 파이프라인을 생성하려면 다음 파일이 필요합니다.
(이 파일들은 다음 섹션에서 생성됩니다)

---

## 부록

### A. 환경 변수 전체 목록

모든 환경 변수는 `.env.prod` 및 `.env.dev` 파일에 정의되어 있습니다.

### B. 포트 매핑 전체 목록

#### 운영 환경

| 서비스 | 내부 포트 | 외부 포트 | 프로토콜 |
|--------|----------|----------|---------|
| NGINX | 80, 443 | 80, 443 | HTTP/HTTPS |
| Spring Boot (Blue) | 8080 | - | HTTP |
| Spring Boot (Green) | 8080 | - | HTTP |
| FastAPI (Blue) | 8000 | - | HTTP |
| FastAPI (Green) | 8000 | - | HTTP |
| MySQL | 3306 | - | MySQL |
| Qdrant | 6333, 6334 | - | HTTP/gRPC |
| Kafka | 9092 | - | Kafka |
| Zookeeper | 2181 | - | Zookeeper |
| Jenkins | 8080 | - | HTTP |
| GitLab | 80, 22 | - | HTTP/SSH |
| Prometheus | 9090 | - | HTTP |
| Grafana | 3000 | - | HTTP |

#### 개발 환경

개발 환경은 운영 환경과 포트가 겹치지 않도록 오프셋을 사용합니다.

### C. 유용한 Docker Compose 명령어

```bash
# 서비스 빌드
docker-compose build

# 특정 서비스만 빌드
docker-compose build spring-boot-blue

# 백그라운드 실행
docker-compose up -d

# 특정 서비스만 실행
docker-compose up -d nginx jenkins

# 로그 확인
docker-compose logs -f

# 특정 서비스 로그만 확인
docker-compose logs -f spring-boot-blue

# 서비스 중지
docker-compose stop

# 서비스 재시작
docker-compose restart

# 서비스 제거
docker-compose down

# 볼륨까지 제거
docker-compose down -v

# 서비스 스케일링
docker-compose up -d --scale spring-boot-blue=3

# 실행 중인 컨테이너에서 명령 실행
docker-compose exec spring-boot-blue bash

# 환경 변수 확인
docker-compose config
```

### D. 문제 해결 FAQ

**Q: Let's Encrypt 인증서 발급이 실패합니다.**

A: 다음을 확인하세요:
1. 도메인 DNS가 올바르게 설정되었는지 확인
2. 포트 80, 443이 열려있는지 확인
3. Staging 모드로 먼저 테스트 (`CERTBOT_STAGING=1`)

**Q: GitLab Webhook이 작동하지 않습니다.**

A: 다음을 확인하세요:
1. Jenkins URL이 GitLab에서 접근 가능한지 확인
2. Webhook Secret Token이 올바르게 설정되었는지 확인
3. GitLab 프로젝트 설정에서 "Allow requests to the local network from webhooks and integrations" 활성화

**Q: 블루-그린 배포 중 다운타임이 발생합니다.**

A: 헬스체크 시간을 충분히 길게 설정하고, NGINX graceful reload를 사용하세요.

**Q: MySQL 연결이 실패합니다.**

A: 네트워크 설정을 확인하고, 컨테이너가 같은 Docker 네트워크에 있는지 확인하세요.

---

## 맺음말

이 메뉴얼은 GitLab + Jenkins CI/CD 파이프라인과 Docker 기반 마이크로서비스 아키텍처의 전체 구축 과정을 다룹니다.

각 단계를 차근차근 따라하면서, 실제 환경에 맞게 설정 값들을 조정하세요.

### 다음 단계

README.md를 완성한 후, 다음 명령어로 실제 파일들을 생성합니다:

```bash
# 1. 모든 디렉토리가 생성되었는지 확인
tree -L 3

# 2. README.md의 각 섹션에 있는 `cat >` 명령어들을 순서대로 실행

# 3. Docker Compose 파일 생성 (다음 파일 참조)

# 4. 환경 변수 파일 설정
cp .env.prod.example .env.prod
cp .env.dev.example .env.dev
# 각 파일을 열어서 실제 값으로 수정

# 5. 시스템 시작
docker-compose -f docker-compose.prod.yml up -d
```

---

**문서 버전**: 1.0.0  
**최종 업데이트**: 2025-10-26  
**작성자**: DevOps Team

