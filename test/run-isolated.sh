#!/usr/bin/env bash
set -euo pipefail

# The only host mount is this source directory, read-only. No host ports or
# production volumes are used. Every database is disposable.
rsc_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
rsc_image=${RSC_DISCOURSE_IMAGE:-local_discourse/web_a:latest}
rsc_suffix="$$-$(date +%s)"
rsc_pg="rsc-test-pg-${rsc_suffix}"
rsc_forum="rsc-test-forum-${rsc_suffix}"
rsc_created=()
rsc_docker=(docker)
if ! docker info >/dev/null 2>&1; then
  rsc_docker=(sudo -n docker)
fi

cleanup() {
  for container in "${rsc_created[@]}"; do
    "${rsc_docker[@]}" rm -fv "$container" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

"${rsc_docker[@]}" run -d --name "$rsc_pg" --network none --memory 512m \
  -e POSTGRES_USER=rsc_test -e POSTGRES_PASSWORD=rsc_test_only -e POSTGRES_DB=rsc_native_test \
  postgres:16-bookworm >/dev/null
rsc_created+=("$rsc_pg")
for attempt in {1..30}; do
  if "${rsc_docker[@]}" exec "$rsc_pg" pg_isready -U rsc_test -d rsc_native_test >/dev/null; then
    break
  fi
  sleep 1
done

"${rsc_docker[@]}" run --rm --network "container:$rsc_pg" --memory 768m --entrypoint /bin/bash \
  -e RSC_TEST_DATABASE=rsc_native_test -v "$rsc_root:/rsc:ro" "$rsc_image" \
  -lc 'cd /var/www/discourse && bundle exec ruby /rsc/test/accounting_test.rb'

"${rsc_docker[@]}" run -d --name "$rsc_forum" --network none --memory 2g --entrypoint /bin/bash \
  -e RSC_DISPOSABLE_CONTAINER=1 -e RAILS_ENV=production \
  -e RSC_KEEP_BUNDLED_PLUGINS="${RSC_KEEP_BUNDLED_PLUGINS:-0}" \
  -e DISCOURSE_DB_NAME=rsc_discourse_smoke -e DISCOURSE_DB_HOST=127.0.0.1 \
  -e DISCOURSE_DB_USERNAME=postgres -e DISCOURSE_DB_PASSWORD='' \
  -e DISCOURSE_REDIS_HOST=127.0.0.1 -e DISCOURSE_REDIS_PASSWORD='' \
  -e DISCOURSE_MESSAGE_BUS_REDIS_ENABLED=false -e DISCOURSE_HOSTNAME=rsc.test \
  -v "$rsc_root:/rsc:ro" "$rsc_image" -c 'tail -f /dev/null' >/dev/null
rsc_created+=("$rsc_forum")
"${rsc_docker[@]}" exec "$rsc_forum" bash /rsc/test/prepare_disposable_forum.sh
