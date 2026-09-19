"""Source wiring guard; coordinator disk semantics are covered by Swift tests."""
from pathlib import Path
import unittest


class ProfileLaunchCompatibilityContractTests(unittest.TestCase):
    def test_memory_admission_precedes_snapshot_and_version_reservation(self):
        source = (Path(__file__).resolve().parents[2] / 'Sources/NeAntik/ContentView.swift').read_text()
        launch = source.split('private func launchPreparedProfile(', 1)[1].split('private func validateLaunchPreflight(', 1)[0]
        guard = launch.index('try processes.validateMemoryForLaunch()')
        self.assertLess(guard, launch.index('AtomicProfileSnapshotStore('))
        self.assertLess(guard, launch.index('try compatibility.record('))

    def test_marker_failure_stops_browser_and_cannot_report_success(self):
        source = (Path(__file__).resolve().parents[2] / 'Sources/NeAntik/ContentView.swift').read_text()
        launch = source.split('private func launchPreparedProfile(', 1)[1].split('private func validateLaunchPreflight(', 1)[0]
        self.assertNotIn('try? compatibility.record', launch)
        record = launch.index('try compatibility.record(')
        start = launch.index('try processes.launch(')
        self.assertLess(record, start)
        reservation_failure = launch[record:start].split('} catch {', 1)[1]
        self.assertIn('throw NeAntikError.runtimeValidationFailed(', reservation_failure)
        self.assertNotIn('processes.stop(', reservation_failure)
        record = launch.index('try compatibility.record(', start)
        self.assertLess(record, launch.index('telemetry.record(.browserLaunched'))
        self.assertLess(record, launch.index('store.markLaunched('))
        failure = launch[record:].split('} catch {', 1)[1].split('telemetry.record', 1)[0]
        self.assertIn('processes.stop(profileID: profile.id)', failure)
        self.assertIn('throw NeAntikError.runtimeValidationFailed(', failure)


if __name__ == '__main__':
    unittest.main()
