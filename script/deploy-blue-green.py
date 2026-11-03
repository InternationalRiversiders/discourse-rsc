#!/usr/bin/env python3
"""Deploy a prebuilt, schema-compatible image without stopping the live slot.

Run as root on the forum host. No build, migration, or credential output occurs.
Images must contain the previous release's assets as well as their own assets.
"""
import argparse
import fcntl
import http.client
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import time
import urllib.request


class Docker(http.client.HTTPConnection):
    def __init__(self):
        super().__init__('localhost', timeout=150)

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect('/var/run/docker.sock')


def api(method, path, body=None):
    connection = Docker()
    connection.request(method, '/v1.47' + path,
                       body=json.dumps(body) if body is not None else None,
                       headers={'Content-Type': 'application/json'})
    response = connection.getresponse()
    data = response.read()
    connection.close()
    if response.status >= 300:
        raise RuntimeError(f'Docker {method} {path}: HTTP {response.status}')
    return json.loads(data) if data else None


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def asset_paths(container):
    # All frontend assets, including split bundles and old open browser tabs.
    data = json.loads(run('docker', 'exec', container, 'cat',
                          '/var/www/discourse/public/assets/.manifest.json'))
    paths = {item['digested_path'] for item in data.values()}
    # Generated plugin manifests are authoritative, even for an asset URL hotfix.
    manifests = run('docker', 'exec', container, 'python3', '-c',
        "import glob,json; print(json.dumps([v['fileName'] for p in glob.glob('/var/www/discourse/app/assets/generated/*/manifest.json') for v in json.load(open(p)).values() if isinstance(v,dict) and 'fileName' in v]))")
    paths.update('js/plugins/' + name for name in json.loads(manifests))
    return paths


def check_assets(container, paths):
    code = """import json,sys,pathlib
root=pathlib.Path('/var/www/discourse/public/assets')
missing=[p for p in json.load(sys.stdin) if not (root/p).is_file()]
if missing: raise SystemExit('Missing release assets: '+str(missing[:10]))
"""
    subprocess.run(['docker', 'exec', '-i', container, 'python3', '-c', code],
                   input=json.dumps(sorted(paths)), text=True, check=True)


def healthy(port):
    # Ignore host proxy environment; never send health probes to a proxy.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for path in ['/srv/status', '/session/csrf.json']:
        request = urllib.request.Request(f'http://127.0.0.1:{port}{path}',
                                         headers={'Host': 'river-side.cc', 'X-Forwarded-Proto': 'https'})
        with opener.open(request, timeout=5) as response:
            body = response.read()
            if response.status != 200:
                return False
            if path == '/srv/status' and body.strip() != b'ok':
                return False
            if path.endswith('.json') and not json.loads(body).get('csrf'):
                return False
    return True


def wait_ready(port):
    deadline = time.monotonic() + 180
    consecutive = 0
    while time.monotonic() < deadline:
        try:
            consecutive = consecutive + 1 if healthy(port) else 0
            if consecutive >= 3:
                return
        except Exception:
            consecutive = 0
        time.sleep(2)
    raise RuntimeError('New slot failed application health checks; live slot untouched')


def write_config(path, content):
    stat = path.stat()
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.rollout-')
    try:
        with os.fdopen(fd, 'w') as file:
            file.write(content)
        os.chmod(temporary, stat.st_mode & 0o777)
        os.chown(temporary, stat.st_uid, stat.st_gid)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def worker_pids():
    master = int(Path('/run/nginx.pid').read_text())
    rows = run('ps', '-eo', 'pid,ppid,args').splitlines()
    return {int(parts[0]) for row in rows if len(parts := row.split(None, 2)) == 3
            and parts[1] == str(master) and parts[2].startswith('nginx: worker process')}


def drain_background(container, hostname):
    # Quiet stops new jobs, not jobs already running. Observe their heartbeat
    # before stopping the container; a timeout must leave the old slot alive.
    code = """require 'sidekiq/api'
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 90
quiet = 0
loop do
  workers = Sidekiq::ProcessSet.new.select { |p| p['hostname'] == ARGV.fetch(0) }
  busy = workers.sum { |p| p['busy'].to_i }
  quiet = busy.zero? ? quiet + 1 : 0
  exit 0 if quiet >= 2
  exit 2 if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
  sleep 5
end
"""
    try:
        result = subprocess.run(['docker', 'exec', '-w', '/var/www/discourse', container,
            'bundle', 'exec', 'rails', 'runner', code, hostname],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=130)
        return result.returncode == 0
    except subprocess.TimeoutExpired:
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--compatible-schema', action='store_true', required=True)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise SystemExit('Run as root')
    lock = open('/run/discourse-blue-green.lock', 'w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    config_path = Path('/etc/nginx/sites-enabled/discourse.conf').resolve()
    original = config_path.read_text()
    matches = re.findall(r'proxy_pass http://127\.0\.0\.1:(800[12]);', original)
    if len(matches) != 1:
        raise RuntimeError('Cannot uniquely identify active forum slot')
    old_port = int(matches[0]); new_port = 8001 if old_port == 8002 else 8002
    old_name = 'web_a' if old_port == 8001 else 'web_b'
    new_name = 'web_a' if new_port == 8001 else 'web_b'
    old = api('GET', f'/containers/{old_name}/json')
    if not old['State']['Running'] or not healthy(old_port):
        raise RuntimeError('Current slot is not healthy')
    api('GET', f'/images/{args.image}/json')
    print(f'Plan: keep {old_name}:{old_port} serving, warm {new_name}:{new_port}, then switch', flush=True)
    if args.check:
        return
    stamp = time.strftime('%Y%m%d-%H%M%S', time.gmtime())
    names = {name.lstrip('/') for c in api('GET', '/containers/json?all=1') for name in c['Names']}
    if new_name in names:
        previous = api('GET', f'/containers/{new_name}/json')
        if previous['State']['Running']:
            raise RuntimeError('Inactive slot is still running; inspect drain state before replacing it')
        api('POST', f'/containers/{new_name}/rename?name={new_name}-retired-{stamp}')
    cfg = old['Config'].copy()
    # Container Config may retain a legacy explicit MAC. Reusing it while both
    # slots run causes bridge forwarding to flap and database replies to vanish.
    cfg.pop('MacAddress', None)
    cfg.update(Image=args.image, Hostname=new_name)
    cfg['Env'] = [v for v in cfg.get('Env', []) if not v.startswith('MIGRATE_ON_BOOT=')] + ['MIGRATE_ON_BOOT=0']
    host = old['HostConfig'].copy()
    host['Links'] = ['data:data']
    host['PortBindings'] = {'80/tcp': [{'HostIp': '127.0.0.1', 'HostPort': str(new_port)}]}
    cfg['HostConfig'] = host
    api('POST', f'/containers/create?name={new_name}', cfg)
    api('POST', f'/containers/{new_name}/start')
    switched = False
    try:
        candidate = api('GET', f'/containers/{new_name}/json')
        old_macs = {net.get('MacAddress') for net in old['NetworkSettings']['Networks'].values()} - {None, ''}
        new_macs = {net.get('MacAddress') for net in candidate['NetworkSettings']['Networks'].values()} - {None, ''}
        if old_macs & new_macs:
            raise RuntimeError('Candidate shares a MAC address with the live slot')
        wait_ready(new_port)
        actual = run('docker', 'exec', new_name, 'git', '-c',
                     'safe.directory=/var/www/discourse/plugins/discourse-rsc', '-C',
                     '/var/www/discourse/plugins/discourse-rsc', 'rev-parse', 'HEAD')
        if actual != args.commit:
            raise RuntimeError('Candidate commit mismatch')
        check_assets(new_name, asset_paths(old_name) | asset_paths(new_name))
        print('Candidate application and old/new frontend assets verified', flush=True)
        replacement = original.replace(f'proxy_pass http://127.0.0.1:{old_port};',
                                       f'proxy_pass http://127.0.0.1:{new_port};')
        # Preserve the original file before atomically replacing it.
        backup = Path('/var/discourse/shared/rollouts') / stamp
        backup.mkdir(parents=True, mode=0o700)
        (backup / 'nginx-before.conf').write_text(original)
        workers = worker_pids()
        write_config(config_path, replacement)
        run('nginx', '-t')
        run('systemctl', 'reload', 'nginx')
        switched = True
        if not healthy(new_port):
            raise RuntimeError('Candidate lost health after switch')
        print(f'Traffic switched to {new_name}; draining old requests', flush=True)
        # Shared Redis queues and existing RSC mutexes make the short worker
        # overlap safe. Quiet old workers only after the new slot is serving.
        subprocess.run(['docker', 'exec', old_name, 'pkill', '-TSTP', '-f', '^sidekiq '], check=False)
        deadline = time.monotonic() + 90
        while workers & worker_pids() and time.monotonic() < deadline:
            time.sleep(2)
        if workers & worker_pids():
            print('Old nginx requests still draining; keep old container running', flush=True)
        elif not drain_background(old_name, old['Config']['Hostname']):
            print('Old background jobs still draining or status unknown; keep old container running', flush=True)
        else:
            api('POST', f'/containers/{old_name}/stop?t=60')
            print('Old slot stopped after request and background-job drain', flush=True)
        api('POST', f'/images/{args.image}/tag?repo=local_discourse/{new_name}&tag=latest')
        print(f'DEPLOYED {args.commit} on {new_name}', flush=True)
    except Exception:
        if not api('GET', f'/containers/{old_name}/json')['State']['Running']:
            api('POST', f'/containers/{old_name}/start')
            wait_ready(old_port)
        write_config(config_path, original)
        run('nginx', '-t')
        run('systemctl', 'reload', 'nginx')
        if switched:
            # A quiet Sidekiq cannot resume via a signal. Gracefully recycle it;
            # its supervisor starts a fresh worker without restarting the web.
            subprocess.run(['docker', 'exec', old_name, 'pkill', '-TERM', '-f', '^sidekiq '], check=False)
        # Leave a switched candidate up to drain in-flight requests safely.
        if not switched:
            api('POST', f'/containers/{new_name}/stop?t=60')
        print('Previous upstream restored; inspect the failed candidate before retrying', flush=True)
        raise


if __name__ == '__main__':
    main()
