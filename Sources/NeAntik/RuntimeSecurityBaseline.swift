import Foundation

enum NeAntikRuntimeSecurityBaseline {
    static let minimumPublicChromiumVersion = [153, 0, 8010, 52]
    static let minimumPublicChromiumVersionText = "153.0.8010.52"

    static func meetsPublicChromiumVersion(_ value: String) -> Bool {
        guard let components = versionComponents(value) else {
            return false
        }
        return !components.lexicographicallyPrecedes(
            minimumPublicChromiumVersion
        )
    }

    private static func versionComponents(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts.allSatisfy({
                  !$0.isEmpty &&
                      $0.allSatisfy(\.isNumber) &&
                      ($0.count == 1 || $0.first != "0")
              })
        else {
            return nil
        }
        let components = parts.compactMap { Int($0) }
        return components.count == 4 ? components : nil
    }
}
