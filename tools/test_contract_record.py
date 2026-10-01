"""Keep the source record limited to public contract inputs."""
import hashlib
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class ContractRecordTests(unittest.TestCase):
    def test_record_has_no_private_file_inventory(self):
        record = json.loads((ROOT / "specs/api-source-verification.json").read_text())
        self.assertEqual(set(record["files"]), {
            "docs/api-reference/sending-openapi.json",
            "docs/api-reference/team-openapi.json",
            "docs/scripts/split-openapi.cjs",
        })
        self.assertNotIn("source_patterns", record)
        fixture = ROOT / "test/fixtures/api-source.json"
        self.assertEqual(record["fixtures_sha256"], hashlib.sha256(fixture.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
