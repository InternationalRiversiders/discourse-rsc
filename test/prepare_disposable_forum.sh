#!/usr/bin/env bash
set -euo pipefail

# ONLY called inside a new, network-isolated container with NO live volumes.
test "${RSC_DISPOSABLE_CONTAINER:-}" = 1
test "${DISCOURSE_DB_NAME:-}" = rsc_discourse_smoke
test ! -e /tmp/rsc-forum-prepared
touch /tmp/rsc-forum-prepared

install -d -o postgres -g postgres /tmp/rsc-pg /tmp/rsc-pg-socket
runuser -u postgres -- /usr/lib/postgresql/15/bin/initdb -D /tmp/rsc-pg -A trust >/tmp/rsc-initdb.log
runuser -u postgres -- /usr/lib/postgresql/15/bin/pg_ctl -D /tmp/rsc-pg -l /tmp/rsc-pg/server.log -o '-h 127.0.0.1 -k /tmp/rsc-pg-socket' -w start
redis-server --bind 127.0.0.1 --save '' --appendonly no --daemonize yes
createdb -h 127.0.0.1 -U postgres rsc_discourse_smoke

cd /var/www/discourse
git config --global --add safe.directory /var/www/discourse
mkdir -p /shared/log/rails
mkdir -p /shared/uploads /shared/backups /shared/tmp
if [[ "${RSC_KEEP_BUNDLED_PLUGINS:-0}" != 1 ]]; then
  mv plugins /tmp/rsc-original-plugins
  mkdir plugins
fi
mkdir -p plugins/discourse-rsc
cp -a /rsc/. plugins/discourse-rsc/
psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -U postgres -d rsc_discourse_smoke -f db/structure.sql >/tmp/rsc-schema.log
bundle exec rake db:migrate >/tmp/rsc-migrate.log 2>&1 || { tail -50 /tmp/rsc-migrate.log; exit 1; }
bundle exec rake db:seed >/tmp/rsc-seed.log 2>&1 || { tail -50 /tmp/rsc-seed.log; exit 1; }
bundle exec rails runner /rsc/test/native_adaptation_test.rb
