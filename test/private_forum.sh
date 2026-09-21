#!/usr/bin/env bash
set -euo pipefail
rsc_preview_mode=${1:?Choose snapshot or demo}
case "$rsc_preview_mode" in
  snapshot) rsc_preview_db=rsc_readiness_snapshot; rsc_preview_redis=2; rsc_preview_port=3001; rsc_preview_host=127.0.0.1 ;;
  demo) rsc_preview_db=rsc_discourse_smoke; rsc_preview_redis=0; rsc_preview_port=3000; rsc_preview_host=localhost ;;
  *) exit 2 ;;
esac
rsc_preview_name=rsc-private-preview
docker inspect "$rsc_preview_name" | python3 -c 'import json,sys; i=json.load(sys.stdin)[0]; assert i["HostConfig"]["NetworkMode"]=="none" and "RSC_DISPOSABLE_CONTAINER=1" in i["Config"]["Env"]'
docker start "$rsc_preview_name" >/dev/null
docker exec "$rsc_preview_name" bash -lc 'pg_isready -h 127.0.0.1 -U postgres >/dev/null || runuser -u postgres -- /usr/lib/postgresql/15/bin/pg_ctl -D /tmp/rsc-pg -l /tmp/rsc-pg/server.log -o "-h 127.0.0.1 -k /tmp/rsc-pg-socket" -w start; redis-cli ping >/dev/null 2>&1 || redis-server --bind 127.0.0.1 --save "" --appendonly no --daemonize yes'
exec docker exec -e DISCOURSE_DB_NAME="$rsc_preview_db" -e DISCOURSE_REDIS_DB="$rsc_preview_redis" -e DISCOURSE_HOSTNAME="$rsc_preview_host" -e DISCOURSE_MESSAGE_BUS_REDIS_DB="$rsc_preview_redis" -e RSC_PREVIEW_MODE="$rsc_preview_mode" -e RSC_PREVIEW_PORT="$rsc_preview_port" "$rsc_preview_name" bash -lc 'echo $$ > "/tmp/rsc-private-${RSC_PREVIEW_MODE}.pid"; cd /var/www/discourse; exec bundle exec rackup /rsc/test/private_server.ru -s webrick -o 127.0.0.1 -p "$RSC_PREVIEW_PORT"'
