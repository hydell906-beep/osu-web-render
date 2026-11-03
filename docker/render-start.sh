
#!/bin/sh
set -eu

cd /app

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
    --bind-address=127.0.0.1 &

# Wait for MariaDB
echo "Waiting for MariaDB..."
i=0

until mariadb-admin \
    --socket=/run/mysqld/mysqld.sock \
    ping --silent; do

    i=$((i + 1))

    if [ "$i" -ge 60 ]; then
        echo "ERROR: MariaDB failed to start"
        exit 1
    fi

    sleep 1
done

# Check password
: "${DB_PASSWORD:?DB_PASSWORD must be configured}"

case "$DB_PASSWORD" in
    *[!a-zA-Z0-9_]*)
        echo "ERROR: DB_PASSWORD must contain only letters, numbers, and underscores"
        exit 1
        ;;
esac

# Create database and user
echo "Creating osu database..."

mariadb \
    --socket=/run/mysqld/mysqld.sock \
    -u root <<SQL


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

SQL

# Start Redis-compatible Valkey
echo "Starting Valkey..."

valkey-server \
    --bind 127.0.0.1 \
    --daemonize yes \
    --save "" \
    --appendonly no

# Run database migrations
echo "Running Laravel migrations..."

runuser -u osuweb -- php artisan migrate --force

# Start osu-web
echo "Starting osu-web..."

exec runuser -u osuweb -- \
    /app/docker/deployment/entrypoint.sh octane
