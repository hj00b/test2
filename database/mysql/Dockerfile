FROM mysql:8.0

# 한국 타임존 설정
ENV TZ=Asia/Seoul
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# 초기화 스크립트 복사
COPY init.sql /docker-entrypoint-initdb.d/

# 설정 파일 복사
COPY my.cnf /etc/mysql/conf.d/

EXPOSE 3306
