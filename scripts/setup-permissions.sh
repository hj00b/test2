#!/bin/bash
# 스크립트 실행 권한 설정
# 사용법: ./scripts/setup-permissions.sh

echo "========================================="
echo "Setting up script permissions..."
echo "========================================="
echo ""

# NGINX 스크립트
echo "NGINX scripts:"
chmod +x nginx/scripts/switch-deployment.sh && echo "  ✓ switch-deployment.sh"
chmod +x nginx/scripts/health-check.sh && echo "  ✓ health-check.sh"
chmod +x nginx/scripts/reload-nginx.sh && echo "  ✓ reload-nginx.sh"

# 프로젝트 스크립트
echo ""
echo "Project scripts:"
chmod +x scripts/health-check.sh && echo "  ✓ health-check.sh"

# GitLab 스크립트
echo ""
echo "GitLab scripts:"
chmod +x gitlab/scripts/setup-webhook.sh && echo "  ✓ setup-webhook.sh"

echo ""
echo "========================================="
echo "✓ All scripts are now executable"
echo "========================================="
echo ""
echo "Available scripts:"
echo ""
echo "Blue-Green Deployment:"
echo "  ./nginx/scripts/switch-deployment.sh [blue|green]"
echo "  ./scripts/health-check.sh [blue|green]"
echo ""
echo "NGINX Management:"
echo "  ./nginx/scripts/health-check.sh"
echo "  ./nginx/scripts/reload-nginx.sh"
echo ""
echo "GitLab Integration:"
echo "  ./gitlab/scripts/setup-webhook.sh <gitlab-url> <project-id> <token> <jenkins-url> <secret>"
echo ""
