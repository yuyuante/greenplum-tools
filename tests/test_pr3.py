"""Regression checks for PR #3. GP178 checks require RUN_GP178_TESTS=1."""

import datetime as dt
import importlib.util
import os
from pathlib import Path
import unittest
import uuid

from psycopg2 import sql


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("flx_testdata", ROOT / "flx-testdata" / "flx_testdata.py")
flx = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(flx)


class ProductIdTests(unittest.TestCase):
    def test_date_shift_and_century_rollover(self):
        cases = [
            ("ABCDE240229XYZ", dt.date(2024, 3, 1), 7, "ABCDE240307XYZ"),
            ("ABCDE991231XYZ", dt.date(1999, 12, 31), 1, "ABCDE000101XYZ"),
            ("ABCDE000101XYZ", dt.date(2000, 1, 1), -1, "ABCDE991231XYZ"),
        ]
        for value, reference, days, expected in cases:
            with self.subTest(value=value, days=days):
                self.assertEqual(flx.product_id_expected(value, reference, days), (expected, "shifted"))

    def test_blank_invalid_and_null_are_preserved(self):
        cases = [(None, "blank"), ("   ", "blank"),
                 ("ABCDE240230XYZ", "invalid"), ("ABCDE24AB01XYZ", "invalid")]
        for value, status in cases:
            with self.subTest(value=value):
                self.assertEqual(flx.product_id_expected(value, dt.date(2024, 3, 1), 7), (value, status))

    def test_ambiguous_century_rejected(self):
        with self.assertRaisesRegex(ValueError, "ambiguous product ID century"):
            flx.product_id_expected("ABCDE750101XYZ", dt.date(2025, 1, 1), 7)

    def test_all_product_id_columns_selected(self):
        columns = [("hpoi_prod_id", "text", None), ("hpoi_prod_id1", "text", None),
                   ("hpoi_prod_id2", "text", None), ("hpoi_yymmdd", "text", None)]
        self.assertEqual([c[0] for c in flx.product_columns(("db_owner", "hpoi_flx"), columns)],
                         ["hpoi_prod_id", "hpoi_prod_id1", "hpoi_prod_id2"])


@unittest.skipUnless(os.environ.get("RUN_GP178_TESTS") == "1", "Set RUN_GP178_TESTS=1 for GP178 tests")
class DependencyFunctionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = flx.connect("GP178")
        cls.conn.autocommit = False

    @classmethod
    def tearDownClass(cls):
        cls.conn.rollback()
        cls.conn.close()

    def tearDown(self):
        self.conn.rollback()

    def call(self, object_type="f", object_name="proc_gen_dep", level=0, direction=1, flag=""):
        with self.conn.cursor() as cur:
            cur.execute("SET LOCAL statement_timeout = '30s'")
            cur.execute("SELECT db_owner.proc_gen_dep(%s, 'db_owner', %s, %s, 1, %s, %s)",
                        (object_type, object_name, level, direction, flag))
            result = cur.fetchone()[0]
            if result == "S":
                cur.execute("SELECT count(*), min(dep_level), max(dep_level) FROM tmp_dep_result")
                summary = cur.fetchone()
                cur.execute("SELECT count(*) FROM tmp_dep_func_detail")
                details = cur.fetchone()[0]
                return result, summary, details
            return result, None, None

    def test_both_directions_and_result_tables(self):
        for direction in (1, 2):
            with self.subTest(direction=direction):
                result, (count, minimum, maximum), details = self.call(direction=direction)
                self.assertEqual(result, "S")
                self.assertGreaterEqual(count, 1)
                self.assertEqual((minimum, maximum), (0, 0))
                self.assertEqual(details, count)

    def test_first_dependency_level(self):
        result, (count, minimum, maximum), details = self.call(level=1)
        self.assertEqual(result, "S")
        self.assertGreaterEqual(count, 1)
        self.assertEqual(minimum, 0)
        self.assertLessEqual(maximum, 1)
        self.assertEqual(details, count)

    def test_invalid_type_and_missing_object(self):
        for object_type, object_name, message in (
            ("x", "proc_gen_dep", "Unsupported object type"),
            ("f", "__missing_pr3_object__", "does not exists"),
        ):
            with self.subTest(object_type=object_type, object_name=object_name):
                with self.assertRaisesRegex(Exception, message):
                    self.call(object_type=object_type, object_name=object_name)
                self.conn.rollback()

    def test_early_stop_flag(self):
        result, _, _ = self.call(flag="00010")
        self.assertEqual(result, "xxx")

    def test_repository_sql_keeps_permanent_tables_with_temp_names(self):
        source = (ROOT / "object-dependency-finder" / "DB_OWNER.fun_proc_gen_dep.sql").read_text(encoding="utf-8-sig")
        fixture_schema = "pr3_review_" + uuid.uuid4().hex[:12]
        source = source.replace("CREATE OR REPLACE FUNCTION db_owner.proc_gen_dep(",
                                f"CREATE OR REPLACE FUNCTION {fixture_schema}.proc_gen_dep(", 1)
        self.assertIn(f"CREATE OR REPLACE FUNCTION {fixture_schema}.proc_gen_dep(", source)
        self.assertNotIn("CREATE OR REPLACE FUNCTION db_owner.proc_gen_dep(", source)
        names = ("tmp_object_list", "tmp_dep_loop", "tmp_dep_result", "tmp_dep_func_detail")
        with self.conn.cursor() as cur:
            cur.execute("SET LOCAL statement_timeout = '60s'")
            cur.execute(sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(fixture_schema)))
            for name in names:
                cur.execute(sql.SQL("CREATE TABLE {}.{} (marker integer) DISTRIBUTED RANDOMLY").format(
                    sql.Identifier(fixture_schema), sql.Identifier(name)))
            cur.execute(sql.SQL("SET LOCAL search_path TO {}, public").format(sql.Identifier(fixture_schema)))
            cur.execute(source)
            cur.execute(sql.SQL("SELECT {}.proc_gen_dep('f', 'db_owner', 'proc_gen_dep', 0, 1, 1, '00030')").format(
                sql.Identifier(fixture_schema)))
            self.assertEqual(cur.fetchone()[0], "xxx")
            cur.execute("""SELECT relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                           WHERE n.nspname = %s AND c.relname = ANY(%s) ORDER BY relname""",
                        (fixture_schema, list(names)))
            self.assertEqual([row[0] for row in cur.fetchall()], sorted(names))


if __name__ == "__main__":
    unittest.main()
