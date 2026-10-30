import Foundation
import Testing
@testable import DirectUpdateCore
@testable import NeAntik

struct DirectUpdateCoreBoundaryTests {
    @Test func sharedFilesystemLimitsMatchExistingBackupFormat() {
        #expect(DirectFileIOLimits.maximumEntries == EncryptedBackupArchive.maximumEntries)
        #expect(DirectFileIOLimits.hashChunkBytes == EncryptedBackupFraming.maximumPayload)
        #expect(DirectFileIOLimits.maximumReadBytes == EncryptedBackupFraming.maximumPayload + EncryptedBackupFraming.recordOverhead + 16)
        #expect(DirectFileIOLimits.maximumReadBytes > DirectFileIOLimits.hashChunkBytes)
    }
}
