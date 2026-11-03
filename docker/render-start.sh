#!/bin/sh
set -eu

cd /app

# Check password
: "${DB_PASSWORD:?DB_PASSWORD must be configured}"

case "$DB_PASSWORD" in
    *[!a-zA-Z0-9_]*)
        echo "ERROR: DB_PASSWORD must contain only letters, numbers, and underscores"
        exit 1
        ;;
esac

: "${APP_KEY:?APP_KEY must be configured and kept stable across deploys}"
: "${APP_URL:?APP_URL must be configured with the public HTTPS URL}"

# This entrypoint runs a local, ephemeral database with these fixed names.
export DB_HOST=127.0.0.1 DB_PORT=3306 DB_USERNAME=osuweb
export DB_DATABASE=osu DB_DATABASE_MP=osu_mp DB_DATABASE_CHARTS=osu_charts
export DB_DATABASE_CHAT=osu_chat DB_DATABASE_STORE=osu_store DB_DATABASE_UPDATES=osu_updates
export APP_ENV="${APP_ENV:-production}" APP_DEBUG="${APP_DEBUG:-false}"
export CLOCKWORK_ENABLE="${CLOCKWORK_ENABLE:-false}"
export OCTANE_HTTPS="${OCTANE_HTTPS:-true}" SESSION_SECURE_COOKIE="${SESSION_SECURE_COOKIE:-true}"
export TRUSTED_PROXIES="${TRUSTED_PROXIES:-0.0.0.0/0,::/0}"
export QUEUE_DRIVER="${QUEUE_DRIVER:-sync}"

mysql_pid=
valkey_pid=
web_pid=
cleanup() {
    trap - EXIT TERM INT
    for pid in "$web_pid" "$valkey_pid" "$mysql_pid"; do
        if [ -n "$pid" ]; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done
    wait 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

echo "Starting MariaDB and Valkey..."

# Prepare database directories
mkdir -p /var/lib/mysql /run/mysqld
chown -R mysql:mysql /var/lib/mysql /run/mysqld

# Initialize database if needed
if [ ! -d /var/lib/mysql/mysql ]; then
    echo "Initializing MariaDB..."
    mariadb-install-db \
        --user=mysql \
        --datadir=/var/lib/mysql
fi

# Start MariaDB
echo "Starting MariaDB server..."
mariadbd \
    --user=mysql \
    --datadir=/var/lib/mysql \
    --socket=/run/mysqld/mysqld.sock \
    --bind-address=127.0.0.1 \
    --skip-name-resolve \
    --innodb-buffer-pool-size=64M \
    --innodb-log-buffer-size=8M \
    --key-buffer-size=8M \
    --aria-pagecache-buffer-size=8M \
    --max-connections=32 \
    --table-open-cache=256 \
    --tmp-table-size=8M \
    --max-heap-table-size=8M \
    --performance-schema=OFF &
mysql_pid=$!

# Wait for MariaDB
echo "Waiting for MariaDB..."
i=0

until mariadb-admin \
    --socket=/run/mysqld/mysqld.sock \
    ping --silent; do

    if ! kill -0 "$mysql_pid" 2>/dev/null; then
        echo "ERROR: MariaDB exited during startup" >&2
        exit 1
    fi
    i=$((i + 1))

    if [ "$i" -ge 60 ]; then
        echo "ERROR: MariaDB failed to start"
        exit 1
    fi

    sleep 1
done

# Create database and user
echo "Creating all six osu databases and grants..."

mariadb \
    --socket=/run/mysqld/mysqld.sock \
    -u root <<SQL

CREATE DATABASE IF NOT EXISTS osu
CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE DATABASE IF NOT EXISTS osu_mp
CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE DATABASE IF NOT EXISTS osu_charts
CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE DATABASE IF NOT EXISTS osu_chat
CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE DATABASE IF NOT EXISTS osu_store
CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE DATABASE IF NOT EXISTS osu_updates
CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'osuweb'@'127.0.0.1'
IDENTIFIED BY '${DB_PASSWORD}';

ALTER USER 'osuweb'@'127.0.0.1'
IDENTIFIED BY '${DB_PASSWORD}';

GRANT ALL PRIVILEGES ON osu.*
TO 'osuweb'@'127.0.0.1';

GRANT ALL PRIVILEGES ON osu_mp.*
TO 'osuweb'@'127.0.0.1';

GRANT ALL PRIVILEGES ON osu_charts.*
TO 'osuweb'@'127.0.0.1';

GRANT ALL PRIVILEGES ON osu_chat.*
TO 'osuweb'@'127.0.0.1';

GRANT ALL PRIVILEGES ON osu_store.*
TO 'osuweb'@'127.0.0.1';

GRANT ALL PRIVILEGES ON osu_updates.*
TO 'osuweb'@'127.0.0.1';

FLUSH PRIVILEGES;
SQL

# Start Redis-compatible Valkey
echo "Starting Valkey..."

valkey-server \
    --bind 127.0.0.1 \
    --daemonize no \
    --save "" \
    --appendonly no \
    --maxmemory 32mb \
    --maxmemory-policy noeviction &
valkey_pid=$!

i=0
until valkey-cli -h 127.0.0.1 ping | grep -qx PONG; do
    i=$((i + 1))
    if [ "$i" -ge 30 ] || ! kill -0 "$valkey_pid" 2>/dev/null; then
        echo "ERROR: Valkey failed to start" >&2
        exit 1
    fi
    sleep 1
done

# Run database migrations
echo "Running Laravel migrations..."

# Discard config cached during a previous container start before migrations.
runuser -u osuweb -- php artisan config:clear
runuser -u osuweb -- php artisan migrate --force

# Start osu-web
echo "Starting osu-web..."

# Render terminates TLS at its proxy; the container itself serves plain HTTP.
runuser -u osuweb -- /bin/sh /app/docker/deployment/entrypoint.sh octane \
    --server=frankenphp --port="${PORT:-10000}" --workers=1 --max-requests=100 &
web_pid=$!

# Stop the whole container when any required service dies, and forward shutdown.
while kill -0 "$web_pid" 2>/dev/null; do
    if ! kill -0 "$mysql_pid" 2>/dev/null || ! kill -0 "$valkey_pid" 2>/dev/null; then
        echo "ERROR: a required database service exited" >&2
        exit 1
    fi
    sleep 2
done
wait "$web_pid"
