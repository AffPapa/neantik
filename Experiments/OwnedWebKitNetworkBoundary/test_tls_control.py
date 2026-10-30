"""Retained real observations plus controlled broken route/trust fixtures."""
import unittest
from tls_control import evaluate


class TLSControlTests(unittest.TestCase):
    def observation(self, **changes):
        value = dict(event={'case': 'own', 'success': True}, label='own', expected_success=True,
                     responses=1, tcp=1, tunnels=1, expected_responses=1, route='relay',
                     trust_events=[True], expected_trust=True)
        value.update(changes)
        return evaluate(**value)

    def test_real_direct_positive_with_two_tcp_attempts_and_one_request(self):
        self.assertTrue(self.observation(route='direct', tcp=2, tunnels=0, trust_events=[True, True]))

    def test_real_certificate_refusal_retries_all_use_tunnel(self):
        self.assertTrue(self.observation(event={'case': 'own', 'success': False}, expected_success=False,
                                        responses=0, expected_responses=0, tcp=2, tunnels=2,
                                        trust_events=[False, False], expected_trust=False))

    def test_direct_tcp_escape_is_detected_even_without_extra_http(self):
        self.assertFalse(self.observation(tcp=2, tunnels=1))

    def test_blocked_path_cannot_complete_even_tcp(self):
        self.assertFalse(self.observation(event={'case': 'own', 'success': False}, expected_success=False,
                                         responses=0, expected_responses=0, tcp=1, tunnels=0,
                                         route='blocked', expected_trust=None))

    def test_any_accepted_trust_invalidates_certificate_refusal(self):
        self.assertFalse(self.observation(event={'case': 'own', 'success': False}, expected_success=False,
                                         responses=0, expected_responses=0, tcp=2, tunnels=2,
                                         trust_events=[False, True], expected_trust=False))

    def test_missing_trust_is_not_a_certificate_pass(self):
        self.assertFalse(self.observation(trust_events=[]))

    def test_stale_navigation_event_is_refused(self):
        self.assertFalse(self.observation(event={'case': 'previous', 'success': True}))


if __name__ == '__main__': unittest.main()
