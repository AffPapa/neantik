import Foundation
import Testing
@testable import NeAntik

struct ProfilePrivacyPanelTests {
    @Test
    func panelMapsOnlyBoundedMediaAndPermissionFacts() throws {
        let profileID = UUID()
        let capture = FingerprintCapture(
            profileID: profileID,
            profileName: "Профиль",
            identityCode: "raw-identity-must-not-escape",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            values: [
                "media_devices": "available",
                "media_device_count": "3",
                "permissions_api": "available",
                "permission_camera": "prompt",
                "permission_microphone": "denied",
                "media_device_label": "Webcam secret label",
                "device_id": "raw-device-id"
            ]
        )

        let snapshot = ProfilePrivacyPanelSnapshot.from(capture: capture)

        #expect(snapshot.profileID == profileID)
        #expect(snapshot.mediaDevices == .available)
        #expect(snapshot.mediaDeviceCount == 3)
        #expect(snapshot.permissionsAPI == .available)
        #expect(snapshot.camera == .prompt)
        #expect(snapshot.microphone == .denied)
        #expect(!snapshot.mediaDevices.title.contains("Webcam"))
        #expect(!snapshot.camera.title.contains("raw-device-id"))
    }

    @Test
    func malformedAndUnboundedFactsBecomeUnknownOrUnavailable() {
        let capture = FingerprintCapture(
            profileID: UUID(),
            profileName: "Профиль",
            identityCode: "identity",
            capturedAt: Date(),
            values: [
                "media_devices": "raw-value",
                "media_device_count": "999999",
                "permissions_api": "raw-value",
                "permission_camera": "raw-value",
                "permission_microphone": "raw-value"
            ]
        )

        let snapshot = ProfilePrivacyPanelSnapshot.from(capture: capture)

        #expect(snapshot.mediaDevices == .unknown)
        #expect(snapshot.mediaDeviceCount == nil)
        #expect(snapshot.permissionsAPI == .unknown)
        #expect(snapshot.camera == .unknown)
        #expect(snapshot.microphone == .unknown)
    }
}
