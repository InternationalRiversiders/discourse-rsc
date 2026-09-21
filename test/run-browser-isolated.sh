#!/usr/bin/env bash
set -euo pipefail

# Host-side runner: creates a new forum and enters ONLY its network namespace.
# No live containers or live volumes are used.
repo=$(cd "$(dirname "$0")/.." && pwd)
: "${RSC_PLAYWRIGHT:?Set RSC_PLAYWRIGHT to an installed playwright module's absolute path}"
: "${RSC_CHROMIUM:?Set RSC_CHROMIUM to a Chromium executable's absolute path}"
node_bin=$(command -v node)
image=${RSC_DISCOURSE_IMAGE:-local_discourse/web_a:latest}
container="rsc-browser-$$-$(date +%s)"
work=$(mktemp -d /tmp/rsc-browser-run.XXXXXX)
output=$(realpath -m "${RSC_BROWSER_OUTPUT:-/tmp/rsc-browser-artifacts}")
mkdir -p "$output"
docker=(docker)
if ! docker info >/dev/null 2>&1; then docker=(sudo -n docker); fi
cleanup() {
  if [[ "${RSC_KEEP_TEST_CONTAINER:-}" == 1 ]]; then
    printf "Kept isolated test container: %s; logs: %s\n" "$container" "$work"
  else
    "${docker[@]}" rm -fv "$container" >/dev/null 2>&1 || true
    rm -rf "$work"
  fi
  sudo -n chown -R --reference="$repo" "$output" 2>/dev/null || true
}
trap cleanup EXIT

"${docker[@]}" run -d --name "$container" --network none --memory 3g \
  -v "$repo:/rsc:ro" -e RSC_DISPOSABLE_CONTAINER=1 -e RAILS_ENV=production \
  -e RSC_KEEP_BUNDLED_PLUGINS="${RSC_KEEP_BUNDLED_PLUGINS:-0}" \
  -e RSC_BROWSER_REFRESH_QUOTES="${RSC_BROWSER_REFRESH_QUOTES:-0}" \
  -e DISCOURSE_DB_NAME=rsc_discourse_smoke -e DISCOURSE_DB_HOST=127.0.0.1 \
  -e DISCOURSE_DB_USERNAME=postgres -e DISCOURSE_DB_PASSWORD= \
  -e DISCOURSE_REDIS_HOST=127.0.0.1 -e DISCOURSE_REDIS_PASSWORD= \
  -e DISCOURSE_MESSAGE_BUS_REDIS_ENABLED=false -e DISCOURSE_HOSTNAME=rsc.test \
  --entrypoint bash "$image" -c 'tail -f /dev/null' >/dev/null
"${docker[@]}" exec "$container" bash /rsc/test/prepare_disposable_forum.sh >"$work/prepare.log" 2>&1 || { tail -60 "$work/prepare.log"; exit 1; }
"${docker[@]}" exec "$container" bash -lc \
  'cd /var/www/discourse && bundle exec rake assets:precompile:build_plugins && SKIP_EMBER_CLI_COMPILE=1 bundle exec rake assets:precompile && bundle exec rails runner /rsc/test/seed_browser.rb' >"$work/build.log" 2>&1 || { tail -60 "$work/build.log"; exit 1; }
"${docker[@]}" exec -d "$container" bash -lc \
  'cd /var/www/discourse && exec bundle exec rackup /rsc/test/browser_server.ru -s webrick -o 0.0.0.0 -p 3000 > /tmp/rsc-server.log 2>&1'
"${docker[@]}" exec -d "$container" bash -lc \
  'cd /var/www/discourse && exec bundle exec rails runner /rsc/test/demo_tick.rb > /tmp/rsc-demo.log 2>&1'
"${docker[@]}" cp "$container:/tmp/rsc-browser-key.json" "$work/credentials.json" >/dev/null
sudo -n chmod 600 "$work/credentials.json"
ready=0
for attempt in $(seq 1 30); do
  if "${docker[@]}" exec "$container" curl -sf -H 'Host: rsc.test' http://127.0.0.1:3000/session/csrf.json >/dev/null; then ready=1; break; fi
  sleep 1
done
if [[ "$ready" != 1 ]]; then "${docker[@]}" exec "$container" tail -60 /tmp/rsc-server.log; exit 1; fi
pid=$("${docker[@]}" inspect -f '{{.State.Pid}}' "$container")
sudo -n nsenter -t "$pid" -n env \
  RSC_PLAYWRIGHT="$RSC_PLAYWRIGHT" RSC_CHROMIUM="$RSC_CHROMIUM" \
  RSC_BROWSER_REFRESH_QUOTES="${RSC_BROWSER_REFRESH_QUOTES:-0}" \
  RSC_BROWSER_CREDENTIALS="$work/credentials.json" RSC_BROWSER_OUTPUT="$output" \
  "$node_bin" "$repo/test/browser.cjs"
printf 'Browser artifacts: %s\n' "$output"
