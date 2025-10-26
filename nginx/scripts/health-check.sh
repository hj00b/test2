#!/bin/sh
# Nginx 헬스체크 스크립트

if wget --quiet --tries=1 --spider http://localhost/health 2>/dev/null; then
    echo "Nginx is healthy"
    exit 0
else
    echo "Nginx health check failed"
    exit 1
fi
