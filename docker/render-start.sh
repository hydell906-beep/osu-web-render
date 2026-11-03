
#!/bin/sh
set -eu

cd /app

echo "Starting MariaDB and Redis..."

mkdir -p /var/lib/mysql /run/mysqld
chown -R mysql:mysql /var/lib/mysql /run/mysqld

if [ ! -d /var/lib/mysql/mysql ]; then
    echo "Initializing MariaDB..."
    mariadb-install-db \
      --user=mysql \
      --datadir=/var/lib/mysql
fi

mariadbd \
  --user=mysql \
  --datadir=/var/lib/mysql \
  --socket=/run/mysqld/mysqld.sock \
  --bind-address=127.0.0.1 &

echo "Waiting for database..."

i=0
until mariadb-admin \
  --socket=/run/mysqld/mysqld.sock \
  ping --silent; do
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then
        echo "ERROR: MariaDB did not start"
        exit 1
    fi
    sleep 1
done

: "${DB_PASSWORD:?DB_PASSWORD must be set}"

case "$DB_PASSWORD" in
  *[!a-zA-Z0-9_]*)
    echo "ERROR: Use only letters, numbers, and underscores in DB_PASSWORD"
    exit 1
    ;;
esac

echo "Creating database..."

mariadb \
  --socket=/run/mysqld/mysqld.sock \
  -u root <<SQL
CREATE DATABASE IF NOT EXISTS osu
CHARACTER SET utf8mb4
COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'osuweb'@'127.0.0.1'
IDENTIFIED BY '${DB_PASSWORD}';

ALTER USER 'osuweb'@'127.0.0.1'
IDENTIFIED BY '${DB_PASSWORD}';

GRANT ALL PRIVILEGES ON osu.*
TO 'osuweb'@'127.0.0.1';

FLUSH PRIVILEGES;
SQL

echo "Starting Redis..."

redis-server \
  --bind 127.0.0.1 \
  --daemonize yes \
  --save "" \
  --appendonly no

echo "Running database migrations..."

runuser -u osuweb -- php artisan migrate --force

echo "Starting osu-web..."

exec runuser -u osuweb -- \
  /app/docker/deployment/entrypoint.sh octane
