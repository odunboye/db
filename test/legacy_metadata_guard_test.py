"""The nebula_meta legacy-schema check in Migration.idr is a data-safety
guard, not a fallback: it must fail closed before touching flux_db_meta,
never translate/read old history. Static source check, no database needed.

Carried over from Flux's own test suite (tools/test_db_names.py) when this
package moved out to its own repo - see MIGRATION.md.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LegacyMetadataGuardTests(unittest.TestCase):
    def test_legacy_metadata_is_a_guard_not_a_fallback(self):
        text = (ROOT / 'src/DB/Migration.idr').read_text()
        self.assertIn("nspname = 'nebula_meta'", text)
        self.assertNotIn('nebula_meta.migrations', text)
        self.assertIn('INSERT INTO flux_db_meta.migrations', text)
        self.assertIn('pg_try_advisory_lock(723946218534101)', text)
        self.assertLess(text.index('prepareMetadata db |'), text.index('SELECT version, name, checksum'))


if __name__ == '__main__':
    unittest.main()
