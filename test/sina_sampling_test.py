import importlib.util
import tempfile
from pathlib import Path
from datetime import datetime, timezone
import unittest
from unittest.mock import patch
from types import SimpleNamespace

spec=importlib.util.spec_from_file_location('study',Path(__file__).resolve().parents[1]/'script/sample_sina_etf.py')
s=importlib.util.module_from_spec(spec);spec.loader.exec_module(s)

class SamplingTest(unittest.TestCase):
    def test_database_comparison_reads_multiline_json(self):
        output = '[{"symbol":"588370.SS"},\n {"symbol":"588000.SS"}]\n'
        with patch.object(s.subprocess, 'run', return_value=SimpleNamespace(stdout=output)) as run:
            self.assertEqual([q['symbol'] for q in s.database_quotes()], ['588370.SS', '588000.SS'])
            self.assertIn('-q', run.call_args.args[0])

    def quote(self, stamp='2026-11-05,09:31:00', price='1.373'):
        fields=['ETF','1.3','1.3',price,'1.4','1.2','1.372','1.374','100','137']+['0']*20+stamp.split(',')
        return 'var hq_str_sh588370="'+','.join(fields)+'";'
    def at(self, value):
        return datetime.fromisoformat(value).replace(tzinfo=s.CN)
    def test_session_windows_and_finite_dates(self):
        for value in ['2026-11-05T09:30:00','2026-11-06T14:59:30','2026-11-05T15:00:05']:
            self.assertTrue(s.active(self.at(value)))
        for value in ['2026-11-04T10:00:00','2026-11-05T09:29:59','2026-11-05T12:00:00','2026-11-06T15:00:30','2026-11-07T10:00:00']:
            self.assertFalse(s.active(self.at(value)))
    def test_timestamp_and_decimal_parsing(self):
        q=s.parse_quotes(self.quote(),self.at('2026-11-05T09:31:10'))['sh588370']
        self.assertTrue(q['fresh']); self.assertEqual(q['age_seconds'],10);self.assertEqual(q['price'],'1.373')
    def test_old_and_future_prices_are_not_fresh(self):
        for stamp in ['2026-11-04,09:31:00','2026-11-05,09:20:00','2026-11-05,09:32:00']:
            self.assertFalse(s.parse_quotes(self.quote(stamp),self.at('2026-11-05T09:31:10'))['sh588370']['fresh'])
    def test_invalid_and_missing_quotes(self):
        for price in ['NaN','0','-1','invalid']:
            self.assertFalse(s.parse_quotes(self.quote(price=price),self.at('2026-11-05T09:31:10'))['sh588370']['valid'])
        self.assertTrue(all(not q['valid'] for q in s.parse_quotes('garbage',datetime.now(timezone.utc)).values()))
    def test_duplicate_rejected(self):
        with self.assertRaises(ValueError):s.parse_quotes(self.quote()*2,datetime.now(timezone.utc))
    def test_misaligned_prices_are_flagged(self):
        quotes=s.parse_quotes(self.quote(),self.at('2026-11-05T09:31:10'))
        old={'symbol':'588370.SS','source':'yahoo','currency':'CNY','source_time':'2026-11-05T01:16:00Z','price':'1.3'}
        result=s.comparisons(quotes,[old])[0]
        self.assertFalse(result['time_aligned']);self.assertEqual(result['sina_ahead_seconds'],900)
        self.assertEqual([],s.comparisons(quotes,[{**old,'currency':'RSC'}]))
    def test_report_excludes_probes_and_matches_later_yahoo_to_saved_sina(self):
        import json
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp);at=self.at('2026-11-05T09:31:10')
            q=s.parse_quotes(self.quote(),at)
            row={'at':at.isoformat(),'scheduled':True,'requested':True,'http_status':200,'duration_ms':100,'quotes':q}
            later={**row,'at':self.at('2026-11-05T09:46:10').isoformat(),'quotes':{},'cached_yahoo':[{'symbol':'588370.SS','source':'yahoo','currency':'CNY','source_time':'2026-11-05T01:31:00Z','price':'1.373'}]}
            (p/'samples.jsonl').write_text('\n'.join(json.dumps(r) for r in [row,later,{**row,'scheduled':False}]))
            out=s.report(p)
            self.assertEqual(out['requests'],2);self.assertEqual(out['per_symbol']['588370.SS']['valid_samples'],1)
            self.assertEqual(out['retrospective_comparisons'],1);self.assertEqual(out['retrospective_gap_p95_percent'],0)

if __name__=='__main__': unittest.main()
