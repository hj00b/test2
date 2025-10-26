#!/bin/sh
# Nginx 설정 리로드 스크립트

echo "Testing nginx configuration..."
nginx -t

if [ $? -eq 0 ]; then
    echo "Configuration test passed. Reloading nginx..."
    nginx -s reload
    echo "Nginx reloaded successfully"
    exit 0
else
    echo "Configuration test failed. Nginx not reloaded."
    exit 1
fi
