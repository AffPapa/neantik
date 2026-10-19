"""A missing/timed-out/unsupported realm is never a WebRTC completion PASS."""
import copy
import unittest
from network_bundle_probe import complete_observation, finished_stun_target


class NetworkObservationTests(unittest.TestCase):
    def setUp(self):
        self.event = {'case': 'owned', 'result': {'nonce': 'own-nonce', 'available': True,
            'secureContext': True, 'offerCreated': True, 'gatheringComplete': True,
            'timedOut': False, 'closed': True}}

    def test_completed_owned_operation(self):
        self.assertTrue(complete_observation(self.event, 'owned', 'own-nonce'))

    def test_missing_or_failed_context_never_passes(self):
        for key in ['available', 'secureContext', 'offerCreated', 'gatheringComplete', 'closed']:
            for value in [False, None]:
                event = copy.deepcopy(self.event); event['result'][key] = value
                with self.subTest(key=key, value=value):
                    self.assertFalse(complete_observation(event, 'owned', 'own-nonce'))

    def test_timeout_not_a_successful_denial(self):
        self.event['result']['timedOut'] = True
        self.assertFalse(complete_observation(self.event, 'owned', 'own-nonce'))

    def test_stale_realm_or_case_is_refused(self):
        self.assertFalse(complete_observation(self.event, 'other', 'own-nonce'))
        self.assertFalse(complete_observation(self.event, 'owned', 'other'))

    def test_target_response_does_not_claim_full_ice_completion(self):
        self.event['result'].update(gatheringComplete=False, candidates={'srflx': 1}, errorCodes=[])
        self.assertTrue(finished_stun_target(self.event, 'owned', 'own-nonce', True))
        self.assertFalse(complete_observation(self.event, 'owned', 'own-nonce'))

    def test_target_denial_requires_explicit_server_error(self):
        self.event['result'].update(gatheringComplete=False, candidates={'srflx': 0}, errorCodes=[701])
        self.assertTrue(finished_stun_target(self.event, 'owned', 'own-nonce', False))
        self.event['result']['errorCodes'] = []
        self.assertFalse(finished_stun_target(self.event, 'owned', 'own-nonce', False))

    def test_timeout_is_not_retroactively_a_target_success(self):
        self.event['result'].update(gatheringComplete=False, candidates={'srflx': 1}, errorCodes=[], timedOut=True)
        self.assertFalse(finished_stun_target(self.event, 'owned', 'own-nonce', True))

    def test_reflexive_response_cannot_pass_a_denial(self):
        self.event['result'].update(candidates={'srflx': 1}, errorCodes=[701])
        self.assertFalse(finished_stun_target(self.event, 'owned', 'own-nonce', False))

    def test_actual_complete_gathering_without_candidates_is_finished_denial(self):
        self.event['result'].update(gatheringComplete=True, candidates={'srflx': 0}, errorCodes=[])
        self.assertTrue(finished_stun_target(self.event, 'owned', 'own-nonce', False))
        self.event['result']['timedOut'] = True
        self.assertFalse(finished_stun_target(self.event, 'owned', 'own-nonce', False))


if __name__ == '__main__': unittest.main()
