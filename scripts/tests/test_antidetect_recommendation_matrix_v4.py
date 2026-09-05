import json
from pathlib import Path
import unittest


class RecommendationMatrixV4Tests(unittest.TestCase):
    def test_ranked_matrix_and_selected_owners_are_complete(self):
        root = Path(__file__).resolve().parents[2]
        rows = json.loads((root / 'docs/ANTIDETECT_RECOMMENDATION_TRACEABILITY_2026-09-05_V4.json').read_text())['recommendations']
        self.assertEqual([row['id'] for row in rows], [f'ND4-{n:03}' for n in range(1, 101)])
        selected = [row for row in rows if row['status'] == 'SELECT']
        self.assertEqual(len(selected), 25)
        self.assertEqual(sum(row['status'] == 'DEFER' for row in rows), 10)
        matrix = (root / 'docs/ANTIDETECT_RECOMMENDATION_MATRIX_2026-09-05_V4.md').read_text()
        for row in rows:
            self.assertIn(f"| {row['id']} | {row['title']} | {row['status']} |", matrix)
        for row in selected:
            self.assertTrue((root / row['owner']).is_file(), row['id'])
            self.assertTrue((root / row['test']).is_file(), row['id'])
