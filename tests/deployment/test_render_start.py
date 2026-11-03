"""Run the actual POSIX entrypoint against fake services; no Docker required."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RenderStartupTest(unittest.TestCase):
    def run_start(self, **overrides):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            bin_dir = tmp / 'bin'
            bin_dir.mkdir()
            commands = {
                'chown': 'exit 0',
                'mariadb-install-db': 'exit 0',
                'mariadbd': 'exec /bin/sleep 60',
                'mariadb-admin': 'exit 0',
                'mariadb': 'cat > "$TEST_DIR/sql"; exit "${SQL_EXIT:-0}"',
                'valkey-server': 'exec /bin/sleep 60',
                'valkey-cli': 'echo "${VALKEY_REPLY:-PONG}"',
                'sleep': 'exec /bin/sleep 0.02',
                'runuser': '''printf '%s\\n' "$*" >> "$TEST_DIR/calls"
case "$*" in
    *'migrate --force'*) exit "${MIGRATE_EXIT:-0}";;
    *'entrypoint.sh octane'*) /bin/sleep 0.08; exit "${WEB_EXIT:-0}";;
esac''',
            }
            for name, body in commands.items():
                file = bin_dir / name
                file.write_text('#!/bin/sh\n' + body + '\n')
                file.chmod(0o755)
            script = (ROOT / 'docker/render-start.sh').read_text()
            script = script.replace('cd /app', 'cd "$TEST_DIR"')
            script = script.replace('/var/lib/mysql', str(tmp / 'mysql'))
            script = script.replace('/run/mysqld', str(tmp / 'run'))
            entry = tmp / 'start.sh'
            entry.write_text(script)
            env = dict(os.environ, PATH=f'{bin_dir}:/usr/bin:/bin', TEST_DIR=str(tmp),
                       DB_PASSWORD='test_password', APP_KEY='test_key',
                       APP_URL='https://example.test', PORT='12345')
            env.update(overrides)
            result = subprocess.run(['/bin/sh', str(entry)], env=env,
                                    capture_output=True, text=True, timeout=8)
            sql = (tmp / 'sql').read_text() if (tmp / 'sql').exists() else ''
            calls = (tmp / 'calls').read_text() if (tmp / 'calls').exists() else ''
            return result, sql, calls

    def test_six_databases_and_render_port(self):
        result, sql, calls = self.run_start()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('mariadb', sql)
        self.assertNotIn('<<SQL', sql)
        self.assertEqual(sql.count('CREATE DATABASE IF NOT EXISTS'), 6)
        self.assertEqual(sql.count('GRANT ALL PRIVILEGES'), 6)
        for database in ('osu', 'osu_mp', 'osu_charts', 'osu_chat', 'osu_store', 'osu_updates'):
            self.assertIn(f'CREATE DATABASE IF NOT EXISTS {database}\n', sql)
            self.assertIn(f'GRANT ALL PRIVILEGES ON {database}.*', sql)
        self.assertLess(calls.index('config:clear'), calls.index('migrate --force'))
        self.assertIn('--port=12345 --workers=1', calls)
        self.assertNotIn('--https', calls)

    def test_sql_failure_stops_before_migrations(self):
        result, _, calls = self.run_start(SQL_EXIT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, '')

    def test_migration_failure_never_starts_web(self):
        result, _, calls = self.run_start(MIGRATE_EXIT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('entrypoint.sh octane', calls)

    def test_web_exit_status_propagates(self):
        result, _, _ = self.run_start(WEB_EXIT='7')
        self.assertEqual(result.returncode, 7)

    def test_missing_key_fails_before_services(self):
        result, sql, _ = self.run_start(APP_KEY='')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sql, '')

    def test_password_cannot_inject_sql(self):
        result, sql, _ = self.run_start(DB_PASSWORD="bad'password")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sql, '')

    def test_valkey_must_be_ready_before_migrations(self):
        result, _, calls = self.run_start(VALKEY_REPLY='LOADING')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, '')


if __name__ == '__main__':
    unittest.main()
