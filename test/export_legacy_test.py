"""Exporter regression checks using synthetic SQLite files only."""
import hashlib
import json
import pathlib
import sqlite3
import subprocess
import tempfile
import unittest


EXPORTER = pathlib.Path(__file__).resolve().parents[1] / "script/export_legacy.py"


class ExportLegacyTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.database = self.root / "source.sqlite"
        self.output = self.root / "export.json"
        with sqlite3.connect(self.database) as connection:
            connection.executescript("""
                CREATE TABLE world_cup_campaign_rewards(id INTEGER PRIMARY KEY, rebate_rsc TEXT);
                INSERT INTO world_cup_campaign_rewards VALUES (1, '1.000000000000000001');
                CREATE TABLE game_rooms(status TEXT, pot_rsc TEXT);
                INSERT INTO game_rooms VALUES ('finished', '0');
            """)

    def export(self):
        return subprocess.run(
            ["python3", str(EXPORTER), str(self.database), str(self.output)],
            capture_output=True, text=True,
        )

    def test_preserves_campaign_precision_without_changing_source(self):
        before = hashlib.sha256(self.database.read_bytes()).hexdigest()
        self.assertEqual(0, self.export().returncode)
        tables = json.loads(self.output.read_text())["tables"]
        self.assertEqual("1.000000000000000001", tables["world_cup_campaign_rewards"][0]["rebate_rsc"])
        self.assertNotIn("game_rooms", tables)
        self.assertEqual(before, hashlib.sha256(self.database.read_bytes()).hexdigest())
        self.assertEqual(0o600, self.output.stat().st_mode & 0o777)

    def test_refuses_unknown_business_table(self):
        with sqlite3.connect(self.database) as connection:
            connection.execute("CREATE TABLE future_rewards(id INTEGER)")
        result = self.export()
        self.assertNotEqual(0, result.returncode)
        self.assertIn("Unmapped legacy tables", result.stderr)
        self.assertFalse(self.output.exists())

    def test_refuses_unsettled_game_funds(self):
        with sqlite3.connect(self.database) as connection:
            connection.execute("INSERT INTO game_rooms VALUES ('playing', '0.01')")
        result = self.export()
        self.assertNotEqual(0, result.returncode)
        self.assertIn("Unsettled game funds", result.stderr)
        self.assertFalse(self.output.exists())

    def test_never_overwrites_an_existing_export(self):
        self.output.write_text("existing backup")
        self.assertNotEqual(0, self.export().returncode)
        self.assertEqual("existing backup", self.output.read_text())


if __name__ == "__main__":
    unittest.main()
