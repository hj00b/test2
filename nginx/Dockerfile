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
