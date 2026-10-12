import Foundation

/// Compare authenticated plist content, preserving arrays, scalar types and
/// every dictionary entry. This does not authenticate a plist or grant trust.
package enum DirectUpdateSignedPlistComparison {
    package static func equal(_ lhs: Data, _ rhs: Data) -> Bool {
        guard let a = try? PropertyListSerialization.propertyList(from: lhs, format: nil),
              let b = try? PropertyListSerialization.propertyList(from: rhs, format: nil) else { return false }
        return equalValue(a as AnyObject, b as AnyObject)
    }
    private static func equalValue(_ lhs: AnyObject, _ rhs: AnyObject) -> Bool {
        guard CFGetTypeID(lhs) == CFGetTypeID(rhs) else { return false }
        if let a = lhs as? NSDictionary, let b = rhs as? NSDictionary {
            guard a.count == b.count else { return false }
            for (key, value) in a {
                guard let key = key as? String, let other = b[key],
                      equalValue(value as AnyObject, other as AnyObject) else { return false }
            }
            return true
        }
        if let a = lhs as? NSArray, let b = rhs as? NSArray {
            return a.count == b.count && zip(a, b).allSatisfy { equalValue($0 as AnyObject, $1 as AnyObject) }
        }
        if let a = lhs as? NSNumber, let b = rhs as? NSNumber {
            let floating = ["f", "d"]
            guard floating.contains(String(cString: a.objCType)) == floating.contains(String(cString: b.objCType)) else { return false }
            return a.isEqual(to: b)
        }
        guard let a = lhs as? NSObject, let b = rhs as? NSObject else { return false }
        return a.isEqual(b)
    }
}
