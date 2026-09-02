import json
import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
MATRIX = ROOT / "docs" / "ANTIDETECT_RECOMMENDATION_MATRIX_2026-09-02_V3.md"
TRACEABILITY = (
    ROOT
    / "docs"
    / "ANTIDETECT_RECOMMENDATION_TRACEABILITY_2026-09-02_V3.json"
)


class RecommendationMatrixV3Tests(unittest.TestCase):
    def test_matrix_has_exactly_one_hundred_ordered_items(self) -> None:
        text = MATRIX.read_text(encoding="utf-8")
        identifiers = re.findall(r"^\| (ND3-\d{3}) \|", text, re.MULTILINE)
        self.assertEqual(
            identifiers,
            [f"ND3-{index:03d}" for index in range(1, 101)],
        )

    def test_matrix_selects_exactly_twenty_five(self) -> None:
        text = MATRIX.read_text(encoding="utf-8")
        rows = [line for line in text.splitlines() if line.startswith("| ND3-")]
        self.assertEqual(sum("| SELECT |" in row for row in rows), 25)
        self.assertEqual(sum("| BACKLOG |" in row for row in rows), 65)
        self.assertEqual(sum("| DEFER |" in row for row in rows), 10)

    def test_matrix_names_thirty_official_products(self) -> None:
        text = MATRIX.read_text(encoding="utf-8")
        source_section = text.split("## Official source index", 1)[1].split(
            "## Ranked matrix", 1
        )[0]
        sources = re.findall(r"^\d+\. \[", source_section, re.MULTILINE)
        self.assertEqual(len(sources), 30)

    def test_every_selected_item_has_existing_code_and_test_evidence(
        self,
    ) -> None:
        text = MATRIX.read_text(encoding="utf-8")
        selected = {
            line.split("|", 2)[1].strip()
            for line in text.splitlines()
            if line.startswith("| ND3-") and "| SELECT |" in line
        }
        payload = json.loads(TRACEABILITY.read_text(encoding="utf-8"))
        self.assertEqual(payload["schemaVersion"], 1)
        entries = payload["selected"]
        self.assertEqual({entry["id"] for entry in entries}, selected)
        self.assertEqual(len(entries), len(selected))
        for entry in entries:
            for field in ("implementation", "tests"):
                self.assertTrue(entry[field], f"{entry['id']} {field}")
                for relative in entry[field]:
                    path = pathlib.PurePosixPath(relative)
                    self.assertFalse(path.is_absolute())
                    self.assertNotIn("..", path.parts)
                    self.assertTrue(
                        (ROOT / path).is_file(),
                        f"{entry['id']} missing {relative}",
                    )


if __name__ == "__main__":
    unittest.main()
