# Quick Start Guide

이 가이드는 최소한의 단계로 시스템을 빠르게 구동하는 방법을 안내합니다.

## 1. 사전 준비

```bash
# Docker 및 Docker Compose 설치 확인
docker --version
docker-compose --version

# Git 설치 확인
git --version
```

### Docker 권한 설정

Docker를 sudo 없이 사용하려면 현재 사용자를 docker 그룹에 추가해야 합니다:

```bash
# 현재 사용자를 docker 그룹에 추가
sudo usermod -aG docker $USER

# 그룹 변경사항 확인
id $USER

# 변경사항 적용 (두 가지 방법 중 하나 선택)
# 방법 1: 터미널 재시작 (권장)
# 로그아웃 후 다시 로그인

# 방법 2: 임시로 새 그룹 세션 시작
newgrp docker

# 권한 확인
docker ps
```

**참고**:
- docker 그룹 추가 후에는 반드시 **터미널을 재시작**하거나 **로그아웃/로그인**해야 합니다
- 현재 세션에서만 임시로 사용하려면 `sg docker -c "명령어"` 형식을 사용할 수 있습니다
  - 예: `sg docker -c "docker-compose -f docker-compose.dev.yml up -d"`

## 2. 환경 변수 설정

```bash
# 운영 환경 설정 복사
cp .env.prod.example .env.prod

# 개발 환경 설정 복사
cp .env.dev.example .env.dev

# .env.prod 파일 편집
nano .env.prod

# 최소한 다음 항목들을 수정하세요:
# - 모든 비밀번호 (MYSQL_ROOT_PASSWORD, MYSQL_PASSWORD 등)
# - 도메인 (DOMAIN_* 변수들)
# - SSL 이메일 (SSL_EMAIL)
```

## 3. 개발 환경 시작 (추천)

```bash
# 환경 변수 로드
export $(cat .env.dev | grep -v '^#' | xargs)

# 개발 환경 시작
docker-compose -f docker-compose.dev.yml up -d

# 로그 확인
docker-compose -f docker-compose.dev.yml logs -f
```

접속 주소:
- MySQL: `localhost:13306`
- React: `http://localhost:13000`
- Spring Boot: `http://localhost:18080`
- FastAPI: `http://localhost:18000`
- Jenkins: `http://localhost:18080`
- Adminer (DB 관리): `http://localhost:18888`

## 4. 운영 환경 시작 (도메인 설정 필요)

```bash
# 1. DNS 설정 확인 (도메인이 서버 IP를 가리켜야 함)
# 2. 환경 변수 로드
export $(cat .env.prod | grep -v '^#' | xargs)

# 3. Let's Encrypt 인증서 발급
# 주의: 실제 도메인이 설정되어 있어야 합니다
./nginx/scripts/init-multi-domain.sh

# 4. 운영 환경 시작
docker-compose -f docker-compose.prod.yml up -d

# 5. 로그 확인
docker-compose -f docker-compose.prod.yml logs -f
```

## 5. 상태 확인

```bash
# 모든 컨테이너 상태 확인
docker ps

# 특정 서비스 헬스체크
docker exec mysql-dev mysqladmin ping -h localhost
docker exec spring-boot-blue-dev wget --quiet --tries=1 --spider http://localhost:8080/actuator/health

# 리소스 사용량 확인
docker stats
```

## 6. 문제 해결

### Docker 권한 에러 (Permission Denied)

```bash
# 에러 예시:
# PermissionError: [Errno 13] Permission denied
# docker.errors.DockerException: Error while fetching server API version

# 해결 방법: 사용자를 docker 그룹에 추가
sudo usermod -aG docker $USER

# 로그아웃 후 다시 로그인하거나, 임시로 사용하려면:
sg docker -c "docker-compose -f docker-compose.dev.yml up -d"
```

### 컨테이너가 시작하지 않을 때

```bash
# 로그 확인
docker logs <container_name>

# 컨테이너 재시작
docker-compose -f docker-compose.dev.yml restart <service_name>
```

### 포트 충돌

```bash
# 포트 사용 확인
sudo lsof -i :18080

# 프로세스 종료
sudo kill -9 <PID>
```

### 전체 리셋

```bash
# 모든 컨테이너 중지 및 삭제
docker-compose -f docker-compose.dev.yml down

# 볼륨까지 삭제 (주의: 데이터 삭제됨)
docker-compose -f docker-compose.dev.yml down -v

# 다시 시작
docker-compose -f docker-compose.dev.yml up -d
```

## 7. GitLab 설정 (선택사항)

```bash
# GitLab 시작
cd gitlab
docker-compose -f docker-compose.gitlab.yml up -d

# 초기 root 비밀번호 확인 (24시간 후 자동 삭제됨)
docker exec -it gitlab cat /etc/gitlab/initial_root_password

# 브라우저에서 접속
# http://localhost:80 (또는 설정한 도메인)
```

## 8. Jenkins 설정 (선택사항)

```bash
# Jenkins 초기 비밀번호 확인
docker exec jenkins-dev cat /var/jenkins_home/secrets/initialAdminPassword

# 브라우저에서 접속
# http://localhost:18080
```

## 9. 다음 단계

시스템이 정상적으로 실행되면:

1. README.md의 전체 문서를 읽고 각 컴포넌트에 대해 학습하세요
2. GitLab과 Jenkins를 연동하여 CI/CD 파이프라인을 구축하세요
3. 블루-그린 배포를 테스트하세요
4. 모니터링 대시보드를 설정하세요 (Grafana)
5. 백업 자동화를 설정하세요

## 유용한 명령어

```bash
# 전체 시스템 중지
docker-compose -f docker-compose.dev.yml stop

# 전체 시스템 시작
docker-compose -f docker-compose.dev.yml start

# 특정 서비스 재시작
docker-compose -f docker-compose.dev.yml restart spring-boot-blue-dev

# 로그 실시간 확인
docker-compose -f docker-compose.dev.yml logs -f spring-boot-blue-dev

# 컨테이너 쉘 접속
docker exec -it spring-boot-blue-dev sh

# Docker 리소스 정리
docker system prune -a
```

## 지원

문제가 발생하면 README.md의 "트러블슈팅" 섹션을 참조하세요.
