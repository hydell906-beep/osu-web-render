# Render Free Docker deployment

This is a disposable demonstration deployment, not a persistent production service.
MariaDB data, uploads, sessions and Valkey contents are local to the container and
can disappear on redeploy, restart or replacement. The app is much larger than a
simple Laravel site; successful startup does not mean all osu! features work.

## Render service settings

- Runtime: Docker; Dockerfile path: `./Dockerfile.deployment`; context: `.`.
- Branch: merge the deployment fix branch into `master`, or select the fix branch.
- Leave Docker Command empty so `/bin/sh /usr/local/bin/render-start.sh` runs.
- Health check path: `/` (checks the actual landing page, not just an open port).
- Set `APP_URL=https://osu-web-1.onrender.com` in the environment. This is also
  consumed during the asset build; set it before building.
- Set a stable `APP_KEY` in Laravel's `base64:` format (32 random bytes encoded
  as base64). Keep the existing valid key; do not regenerate it on every boot.
- Set a long random `DB_PASSWORD` using only letters, numbers and underscores.
  This restriction prevents SQL interpolation of quotes or shell-like text.
- Set `APP_ENV=production`, `APP_DEBUG=false`, `CLOCKWORK_ENABLE=false`.
- Set `DOCS_URL=https://osu-web-1.onrender.com/docs` if using this instance's
  generated API documentation. The upstream asset-build default links to ppy.sh.
- Optional `GIT_SHA` build argument identifies the build version.

The startup script reads Render's `PORT` (default `10000`) and binds Octane to
`0.0.0.0`. Render handles public TLS; do not add Octane's `--https` flag. The
script defaults `OCTANE_HTTPS=true`, `SESSION_SECURE_COOKIE=true` and
`TRUSTED_PROXIES=0.0.0.0/0,::/0`. Trusting all proxies is intended only for this
container behind Render's ingress; restrict it for other hosting arrangements.
FrankenPHP's bundled Octane Caddyfile serves files from `public/` as well as PHP,
so an additional nginx process is unnecessary for this deployment.

## Local services and memory

The entrypoint explicitly selects `127.0.0.1:3306`, user `osuweb`, and databases
`osu`, `osu_mp`, `osu_charts`, `osu_chat`, `osu_store`, `osu_updates`. It creates
all six and grants access before running migrations. Existing `DB_HOST`,
`DB_PORT`, `DB_USERNAME`, and `DB_DATABASE*` settings are overridden because this
entrypoint specifically owns the embedded database. External database hosting
requires a different entrypoint; do not point this initializer at production data.

Leave `REDIS_HOST=127.0.0.1` and `REDIS_PORT=6379` or unset them. Remove
`REDIS_PASSWORD`, `CACHE_REDIS_PASSWORD`, and `NOTIFICATION_REDIS_PASSWORD` for
this local, loopback-only Valkey service. Leave the cache and notification Redis
host/port overrides unset unless deliberately using external services.

The defaults use one Octane worker, a 64 MiB InnoDB buffer pool, 32 MariaDB
connections, a 32 MiB Valkey data limit and a 192 MiB PHP memory limit. These are
component limits, **not a guarantee that total RSS fits the free instance**.
Valkey rejects writes at its limit rather than silently evicting queue entries
or sessions. Large uploads, migrations or requests can still exhaust memory.
Watch Render's memory metrics and logs during migration and real requests.

Startup waits for both databases, clears stale Laravel config, and runs
`php artisan migrate --force`. It stops on failure and never uses
`migrate:fresh` or drops existing databases to hide migration errors. The parent
shell forwards shutdown and exits if MariaDB, Valkey or the web process dies.
A migration that partially applied before failing may need targeted repair;
do not blindly rerun destructive reset commands on data you need.

## Features needing additional setup

- **Elasticsearch:** search features use Elasticsearch (`ES_HOST`, with separate
  `ES_SOLO_SCORES_HOST` for score search). It is not started in this container;
  upstream SETUP.md describes its substantial memory requirements. Use a
  compatible external cluster and populate indices for search-dependent pages.
  The anonymous landing-page controller uses SQL and cache, but that alone does
  not verify every page or the logged-in dashboard.
- **Queues:** `QUEUE_DRIVER=sync` is the default, avoiding an extra worker for
  ordinary queued jobs. Jobs run inside requests and can still require external
  services. If selecting `redis`, run workers separately for `default`,
  `beatmap_default`, `beatmap_high`, `notification`, and `store-notifications`.
  Explicit Redis processing queues and realtime notification services are not
  replaced by the synchronous Laravel queue setting.
- **Scheduling:** `artisan schedule:run` needs an external scheduler; none is
  launched here. Scheduled maintenance will not run automatically.
- **Users/data:** migrations create schema, not a clone of osu.ppy.sh's data.
  Registration requires baseline groups and other data (see SETUP.md). Do not
  automatically run the full sample seeder: it may call external APIs and search.
- **OAuth/API:** provision matching `PASSPORT_PRIVATE_KEY` and
  `PASSPORT_PUBLIC_KEY` or key files, and the appropriate OAuth client before
  using OAuth features. These should be stable secrets, not committed keys.
- **Mail, uploads, beatmap processing and realtime chat:** configure their
  documented external services as needed. `MAIL_DRIVER=log` is useful for a
  demo but does not deliver verification emails. Local uploads are ephemeral.

## Verification

Local regression checks (Python 3, no application dependencies required):

```sh
sh -n docker/render-start.sh
python3 tests/deployment/test_render_start.py
git diff --check
```

The tests execute the real entrypoint against fake services. They check SQL
boundaries and all six grants, port/worker arguments, readiness, fail-fast
behavior, and exit-code propagation. They do **not** execute MariaDB migrations
or build the image.

For deployment verification, build the image, inspect Render logs for completed
migrations and Octane startup, then check the actual HTTP response:

```sh
curl -sS -o /dev/null -w '%{http_code}\n' https://osu-web-1.onrender.com/
```

Require a successful application response, check an asset URL from that page,
and exercise any features you intend to use. A platform proxy's connection
success or an open port is not enough. If `/` returns 500, inspect the matching
Laravel stderr log before changing application behavior.
