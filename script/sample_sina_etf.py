#!/usr/bin/env python3
"""Finite, read-only ETF quote study. Never writes quotes or executes trades."""
import argparse
from collections import Counter
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
import fcntl
import json
from pathlib import Path
import re
import subprocess
import time
import urllib.error
import urllib.request
from zoneinfo import ZoneInfo

CN = ZoneInfo('Asia/Shanghai')
SYMBOLS = {'sh588370': '588370.SS', 'sh588000': '588000.SS',
           'sh510300': '510300.SS', 'sz159915': '159915.SZ'}
START, END = '2026-11-05', '2026-11-06'
URL = 'https://hq.sinajs.cn/?list=' + ','.join(SYMBOLS)


def active(at):
    local = at.astimezone(CN)
    minute = local.hour * 60 + local.minute
    return START <= local.date().isoformat() <= END and local.weekday() < 5 and (
        570 <= minute < 690 or 780 <= minute < 900 or
        (minute in (690, 900) and local.second <= 15))


def parse_quotes(body, received):
    result = {}
    for code, content in re.findall(r'var\s+hq_str_(\w+)="([^"\n]*)"\s*;', body):
        if code not in SYMBOLS:
            continue
        if code in result:
            raise ValueError('duplicate_symbol')
        fields = content.split(',')
        try:
            if len(fields) < 32:
                raise ValueError('missing_fields')
            price, bid, ask = (Decimal(fields[i]) for i in (3, 6, 7))
            if not all(x.is_finite() for x in (price, bid, ask)) or price <= 0 or min(bid, ask) < 0:
                raise ValueError('invalid_price')
            if bid > 0 and ask > 0 and bid > ask:
                raise ValueError('crossed_book')
            stamp = datetime.fromisoformat(fields[30] + 'T' + fields[31]).replace(tzinfo=CN)
            age = (received - stamp).total_seconds()
            fresh = stamp.date() == received.astimezone(CN).date() and -5 <= age <= 90
            result[code] = {'symbol': SYMBOLS[code], 'name': fields[0], 'price': str(price),
                            'bid': str(bid), 'ask': str(ask), 'volume': fields[8],
                            'source_time': stamp.isoformat(), 'age_seconds': round(age, 3),
                            'fresh': fresh, 'valid': True}
        except (ValueError, InvalidOperation) as exc:
            result[code] = {'symbol': SYMBOLS[code], 'valid': False, 'error': str(exc)}
    for code, symbol in SYMBOLS.items():
        result.setdefault(code, {'symbol': symbol, 'valid': False, 'error': 'missing_symbol'})
    return result


def database_quotes():
    # Fixed public instrument list; read-only transaction. No credentials or user data.
    codes = ','.join("'" + value + "'" for value in SYMBOLS.values())
    sql = ("BEGIN READ ONLY; SET LOCAL statement_timeout='3s'; "
           "SELECT coalesce(json_agg(x),'[]'::json) FROM (SELECT symbol, "
           "quote->>'source' AS source, quote->>'local_currency' AS currency, "
           "quote->>'local_price' AS price, quote->>'source_time' AS source_time, "
           "quote->>'received_at' AS received_at, quote->>'delay_seconds' AS delay_seconds "
           f"FROM discourse_rsc_instruments WHERE symbol IN ({codes})) x; COMMIT;")
    output = subprocess.run(['docker', 'exec', '-u', 'postgres', 'data', 'psql', '-X', '-A', '-t',
                             '-v', 'ON_ERROR_STOP=1', '-d', 'discourse', '-c', sql],
                            capture_output=True, text=True, timeout=6, check=True).stdout
    return json.loads(next(line for line in output.splitlines() if line.startswith('[')))


def comparisons(sina, cached):
    results = []
    for old in cached:
        current = next((q for q in sina.values() if q['symbol'] == old['symbol']), None)
        if not current or not current.get('valid') or old.get('source') != 'yahoo' or old.get('currency') != 'CNY':
            continue
        try:
            delta = (datetime.fromisoformat(current['source_time']) -
                     datetime.fromisoformat(old['source_time'].replace('Z', '+00:00'))).total_seconds()
            gap = (Decimal(current['price']) / Decimal(old['price']) - 1) * 100
            # This is RSC's existing cache, not a new direct Yahoo request.
            results.append({'symbol': old['symbol'], 'sina_ahead_seconds': delta,
                            'price_gap_percent': str(gap), 'time_aligned': abs(delta) <= 60,
                            'reference': 'rsc_cached_yahoo'})
        except (ValueError, TypeError, InvalidOperation, ZeroDivisionError):
            continue
    return results


def percentile(values, proportion):
    values = sorted(values)
    return values[min(len(values)-1, int((len(values)-1)*proportion))] if values else None


def report(folder):
    path = folder / 'samples.jsonl'
    rows = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
    # Out-of-hours connectivity probes are never evidence of intraday latency.
    live = [r for r in rows if r.get('scheduled')]
    requested = [r for r in live if r.get('requested')]
    success = [r for r in requested if r.get('http_status') == 200]
    per_symbol = {}
    historical_pairs = []
    for code, symbol in SYMBOLS.items():
        quotes = [(r, r.get('quotes', {}).get(code, {})) for r in success]
        valid = [(r, q) for r, q in quotes if q.get('valid')]
        ages = [q['age_seconds'] for _, q in valid]
        times = [datetime.fromisoformat(q['source_time']).timestamp() for _, q in valid]
        seen_yahoo = set()
        for row in success:
            for old in row.get('cached_yahoo', []):
                if old.get('symbol') != symbol or old.get('source') != 'yahoo' or old.get('currency') != 'CNY':
                    continue
                key = (old.get('source_time'), old.get('price'))
                if key in seen_yahoo or not valid:
                    continue
                seen_yahoo.add(key)
                try:
                    at = datetime.fromisoformat(old['source_time'].replace('Z', '+00:00')).timestamp()
                    closest = min(range(len(times)), key=lambda n: abs(times[n] - at))
                    if abs(times[closest] - at) <= 30:
                        q = valid[closest][1]
                        historical_pairs.append({'symbol': symbol, 'yahoo_time': old['source_time'],
                            'sina_time': q['source_time'], 'gap_seconds': times[closest] - at,
                            'price_gap_percent': str((Decimal(q['price']) / Decimal(old['price']) - 1) * 100)})
                except (ValueError, TypeError, InvalidOperation, ZeroDivisionError):
                    continue
        per_symbol[symbol] = {
            'valid_samples': len(valid), 'fresh_samples': sum(q['fresh'] for _, q in valid),
            'fresh_rate_of_requests': sum(q['fresh'] for _, q in valid) / len(requested) if requested else None,
            'age_p50_seconds': percentile(ages, .5), 'age_p95_seconds': percentile(ages, .95),
            'age_max_seconds': max(ages) if ages else None,
            'distinct_source_times': len({q['source_time'] for _, q in valid}),
            'backwards_timestamps': sum(b < a for a, b in zip(times, times[1:])),
            'dates': dict(Counter(datetime.fromisoformat(r['at']).astimezone(CN).date().isoformat() for r, _ in valid)),
            'windows': dict(Counter(datetime.fromisoformat(r['at']).astimezone(CN).strftime('%Y-%m-%d') +
                                   (' morning' if datetime.fromisoformat(r['at']).astimezone(CN).hour < 12 else ' afternoon') for r, _ in valid)),
        }
    matched = [c for r in success for c in r.get('comparisons', []) if c['time_aligned']]
    result = {'updated_at': datetime.now(timezone.utc).isoformat(), 'period_beijing': [START, END],
              'status': 'awaiting_market_samples' if not live else 'collecting',
              'scheduled_observations': len(live), 'requests': len(requested), 'http_successes': len(success),
              'cooldown_skips': sum(r.get('outcome') == 'cooldown' for r in live),
              'http_success_rate': len(success) / len(requested) if requested else None,
              'request_p95_ms': percentile([r['duration_ms'] for r in requested], .95),
              'per_symbol': per_symbol, 'time_aligned_comparisons': len(matched),
              'retrospective_comparisons': len(historical_pairs),
              'retrospective_gap_p95_percent': percentile([abs(float(p['price_gap_percent'])) for p in historical_pairs], .95),
              'largest_retrospective_gaps': sorted(historical_pairs, key=lambda p: abs(Decimal(p['price_gap_percent'])), reverse=True)[:10],
              'planned_observations': 964,
              'review_targets': {'minimum_coverage': .95, 'minimum_http_success_rate': .995,
                                 'minimum_fresh_rate': .99, 'timestamp_age_p95_seconds_at_most': 30,
                                 'backwards_timestamps': 0,
                                 'note': 'Targets only; no automatic activation. Inspect missing windows, long gaps and price mismatches.'},
              'comparison_limitation': 'RSC cached Yahoo may lag because of both upstream delay and polling. Same-time differences are diagnostic, not proof of a bad price.',
              'integration': 'disabled; requires review of intraday observations, coverage, timestamp advancement and mismatches'}
    if datetime.now(CN).date().isoformat() > END or (datetime.now(CN).date().isoformat() == END and datetime.now(CN).hour >= 15):
        result['status'] = 'sampling_finished_review_required'
    temporary = folder / 'summary.tmp'
    temporary.write_text(json.dumps(result, ensure_ascii=False, indent=2))
    temporary.replace(folder / 'summary.json')
    return result


def sample(folder, probe=False):
    now = datetime.now(timezone.utc)
    if not active(now) and not probe:
        report(folder)
        return
    state_path = folder / 'state.json'
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    row = {'at': now.isoformat(), 'scheduled': active(now) and not probe, 'requested': False}
    if state.get('next_request', 0) > now.timestamp():
        row['outcome'] = 'cooldown'
    else:
        start = time.monotonic()
        row['requested'] = True
        try:
            request = urllib.request.Request(URL, headers={'Referer': 'https://finance.sina.com.cn/',
                                                          'User-Agent': 'Mozilla/5.0'})
            with urllib.request.urlopen(request, timeout=8) as response:
                row['http_status'] = response.status
                body = response.read(256_001)
                if len(body) > 256_000:
                    raise ValueError('oversized_response')
                row['received_at'] = datetime.now(timezone.utc).isoformat()
                row['quotes'] = parse_quotes(body.decode('gb18030'), datetime.fromisoformat(row['received_at']))
            row['outcome'] = 'ok' if all(q['valid'] for q in row['quotes'].values()) else 'invalid_quotes'
            state = {'failures': 0, 'next_request': now.timestamp() + 25}
        except Exception as exc:
            failures = state.get('failures', 0) + 1
            row['outcome'] = type(exc).__name__
            if isinstance(exc, urllib.error.HTTPError):
                row['http_status'] = exc.code
            cooldown = min(600, 120 * 2 ** min(failures-1, 3))
            if row.get('http_status') in (403, 429):
                cooldown = max(cooldown, 900)
                retry = exc.headers.get('Retry-After', '')
                if retry.isdigit():
                    cooldown = max(cooldown, int(retry))
            state = {'failures': failures, 'next_request': now.timestamp() + cooldown}
        row['duration_ms'] = round((time.monotonic() - start) * 1000, 1)
        if row.get('quotes'):
            try:
                row['cached_yahoo'] = database_quotes()
                row['comparisons'] = comparisons(row['quotes'], row['cached_yahoo'])
            except Exception as exc:
                row['comparison_error'] = type(exc).__name__
    state_path.write_text(json.dumps(state))
    with (folder / 'samples.jsonl').open('a') as handle:
        handle.write(json.dumps(row, ensure_ascii=False) + '\n')
    report(folder)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--probe', action='store_true', help='Connectivity only; excluded from intraday metrics')
    parser.add_argument('--report', action='store_true')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    with (args.output / 'lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.report:
            report(args.output)
        else:
            sample(args.output, args.probe)
