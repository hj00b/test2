# 개발 환경용 Dockerfile
FROM node:20-alpine

WORKDIR /app

# 의존성 설치
COPY package*.json ./
RUN npm install

# 소스 복사
COPY . .

EXPOSE 3000

CMD ["npm", "start"]
