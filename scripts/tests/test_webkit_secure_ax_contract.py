import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / 'Experiments/OwnedWebKitNetworkBoundary/source-ports/db6a98765e/neantik-webkit-detached-accessibility.patch'


class SecureAccessibilityContractTests(unittest.TestCase):
    def test_secure_field_is_present_without_value_and_focus_only(self):
        source = PATCH.read_text()
        snapshot = source.split('+void WebPage::neAntikDetachedAXSnapshot', 1)[1].split('+void WebPage::neAntikDetachedAXAction', 1)[0]
        action = source.split('+void WebPage::neAntikDetachedAXAction', 1)[1].split('\n void WebPage::', 1)[0]
        self.assertNotRegex(snapshot, r'\|\| node\.isSecureField\(\) \|\|')
        self.assertIn('node.isSecureField() ? "AXTextField"_s', snapshot)
        self.assertIn('entry->setBoolean("secure"_s, true)', snapshot)
        self.assertIn('!node.isSecureField() && node.isFocused()', snapshot)
        self.assertIn('!node.isSecureField() && detachedAccessibilityCanPress(node)', snapshot)
        self.assertIn('press && !node->isSecureField() && detachedAccessibilityCanPress(*node)', action)
        self.assertIn('!press && node->canSetFocusAttribute()', action)
        self.assertIn('node->setFocused(true)', action)


if __name__ == '__main__':
    unittest.main()
