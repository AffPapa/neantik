import Darwin
import DirectInstallFilesystem
import Foundation

// This executable is a fresh-process crash fixture, never a shipping installer.
#if DEBUG
_ = signal(SIGALRM, SIG_DFL)
var signals = sigset_t(); sigemptyset(&signals); sigaddset(&signals, SIGALRM)
_ = sigprocmask(SIG_UNBLOCK, &signals, nil); alarm(30)
let args = CommandLine.arguments
guard args.count == 4, ["begin", "recover", "ack", "hold", "transfer", "inspectTransfer", "transferBegin"].contains(args[1]),
      args[2].hasPrefix("/private/tmp/neantik-install-fixture-"),
      URL(fileURLWithPath: args[2]).deletingLastPathComponent().path == "/private/tmp" else { exit(64) }
do {
    let root = URL(fileURLWithPath: args[2])
    guard try String(contentsOf: root.appendingPathComponent("fixture.marker"), encoding: .utf8) == "isolated-install-filesystem-qa\n" else { exit(64) }
    let lease = try InstallFilesystemLease(parentURL: root)
    let fault: (InstallFilesystemPoint) throws -> Void = { point in
        if point.rawValue == args[3] { _exit(73) }
    }
    switch args[1] {
    case "begin":
        let name = try String(contentsOf: root.appendingPathComponent("candidate.name"), encoding: .utf8)
        _ = try InstallFilesystemTransaction.begin(lease: lease, candidateName: name,
            candidateReceiptSHA256: String(repeating: "a", count: 64), validateStoppedAuthority: {}, fault: fault)
    case "transfer", "transferBegin":
        let sourceURL = root.appendingPathComponent("source")
        let source = open(sourceURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { exit(74) }; defer { close(source) }
        let name = try String(contentsOf: root.appendingPathComponent("candidate.name"), encoding: .utf8)
        guard let id = UUID(uuidString: String(name.dropFirst(14).dropLast(4))) else { exit(74) }
        let slot = try InstallPreparation.transfer(lease: lease, sourceParentURL: sourceURL, sourceParentDescriptor: source,
            candidateID: id, candidateReceiptSHA256: String(repeating: "a", count: 64), validateSource: {}, didTransfer: {},
            fault: { if $0.rawValue == args[3] { _exit(73) } })
        if args[1] == "transferBegin" {
            _ = try InstallFilesystemTransaction.begin(lease: lease, preparedSlot: slot, validateStoppedAuthority: {}, fault: fault)
        }
    case "inspectTransfer":
        let name = try String(contentsOf: root.appendingPathComponent("candidate.name"), encoding: .utf8)
        let record = ".neantik-install-transfer-" + String(name.dropFirst(14).dropLast(4))
        let result = try InstallPreparation.inspect(lease: lease, recordName: record, sourceParentURL: root.appendingPathComponent("source"))
        guard result.rawValue == args[3] else { exit(74) }
    case "recover":
        _ = try InstallFilesystemTransaction.recover(lease: lease, validateStoppedAuthority: {}, fault: fault)
    case "ack":
        guard let receipt = try InstallFilesystemTransaction.pendingReceipt(lease: lease) else { exit(65) }
        _ = try InstallFilesystemTransaction.acknowledge(lease: lease, expected: receipt, validateLaunchAuthority: {}, fault: fault)
    default:
        FileHandle.standardOutput.write(Data("held\n".utf8))
        _ = FileHandle.standardInput.readData(ofLength: 1)
    }
    exit(0)
} catch InstallFilesystemError.busy { exit(75) }
catch let error as InstallFilesystemError {
    FileHandle.standardError.write(Data(("fixture refusal: " + String(describing: error) + "\n").utf8)); exit(74)
} catch { FileHandle.standardError.write(Data("fixture system refusal\n".utf8)); exit(74) }
#else
exit(64)
#endif
