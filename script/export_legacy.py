#!/usr/bin/env python3
"""Consistent read-only SQLite export. Never changes the legacy database."""
import argparse, datetime, json, os, pathlib, sqlite3, hashlib
from decimal import Decimal
p = argparse.ArgumentParser()
p.add_argument('database'); p.add_argument('output')
a = p.parse_args()
source = pathlib.Path(a.database).resolve()
conn = sqlite3.connect(source.as_uri() + '?mode=ro', uri=True)
conn.row_factory = sqlite3.Row
conn.execute('PRAGMA query_only=ON'); conn.execute('BEGIN')
allowed = '''users daily_activity reward_payouts point_accounts point_account_status_events point_account_asset_reset_events ledger_entries transfers outgoing_limit_exemptions coin_issuances post_tips rsc_red_packets rsc_red_packet_claims rsc_red_packet_allocations market_instruments fx_rates market_quotes market_reference_quotes market_candles market_quote_points account_performance_periods account_performance_flows positions exchange_orders exchange_trades exchange_order_events exchange_order_rejections exchange_pnl_adjustments market_search_requests market_add_requests world_cup_matches sports_event_odds_snapshots world_cup_predictions world_cup_prediction_updates world_cup_campaign_rewards'''.split()
tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
unmapped = sorted(t for t in tables if t not in allowed and not t.startswith(('sqlite_', 'game_')))
if unmapped:
    raise SystemExit('Unmapped legacy tables; review export coverage before migration: ' + ', '.join(unmapped))
if 'game_rooms' in tables:
    for row in conn.execute('SELECT pot_rsc FROM game_rooms WHERE status NOT IN (\'finished\', \'cancelled\', \'canceled\')'):
        if Decimal(row[0]) != 0: raise SystemExit('Unsettled game funds exist; export refused. Games are excluded from migration.')
data = {table: [dict(r) for r in conn.execute(f'SELECT * FROM "{table}"')] for table in allowed if table in tables}
conn.rollback(); conn.close()
payload = {'format': 'rsc-native-export-v1', 'exported_at': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'tables': data}
raw = json.dumps(payload, ensure_ascii=False, separators=(',', ':')).encode()
fd = os.open(a.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'wb') as out: out.write(raw)
print(json.dumps({'tables': {k: len(v) for k, v in data.items()}, 'sha256': hashlib.sha256(raw).hexdigest()}, indent=2))
