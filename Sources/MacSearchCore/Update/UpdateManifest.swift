import Foundation

public struct SemanticVersion: Equatable, Comparable {
    public let text: String
    private let numbers: [UInt64]
    private let prerelease: [String]

    public init?(_ text: String) {
        let metadata = text.split(separator: "+", omittingEmptySubsequences: false)
        guard metadata.count <= 2,
              metadata.count == 1 || Self.identifiers(String(metadata[1]), numericLeadingZeros: true) != nil else { return nil }
        let pieces = metadata[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3 else { return nil }
        var numbers: [UInt64] = []
        for value in core {
            guard Self.numeric(String(value)), value.count == 1 || value.first != "0", let number = UInt64(value) else { return nil }
            numbers.append(number)
        }
        var prerelease: [String] = []
        if pieces.count == 2 {
            guard let identifiers = Self.identifiers(String(pieces[1]), numericLeadingZeros: false) else { return nil }
            prerelease = identifiers
        }
        self.text = text; self.numbers = numbers; self.prerelease = prerelease
    }
    private static func numeric(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (48...57).contains($0) }
    }
    private static func identifiers(_ text: String, numericLeadingZeros: Bool) -> [String]? {
        let values = text.components(separatedBy: ".")
        guard values.allSatisfy({ value in
            !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
                && (numericLeadingZeros || !numeric(value) || value.count == 1 || value.first != "0")
        }) else { return nil }
        return values
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.numbers == rhs.numbers && lhs.prerelease == rhs.prerelease
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let ln = numeric(left), rn = numeric(right)
            if ln != rn { return ln }
            if ln && left.count != right.count { return left.count < right.count }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

public struct UpdateVersion: Equatable, Comparable {
    public let version: SemanticVersion
    public let build: Int
    public init?(_ version: String, build: Int) {
        guard let parsed = SemanticVersion(version), build >= 0 else { return nil }
        self.version = parsed; self.build = build
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.version == rhs.version ? lhs.build < rhs.build : lhs.version < rhs.version
    }
}

public enum UpdateFailure: String, Error {
    case network, integrity, signature, permission, other
}

public struct UpdateManifest: Codable, Equatable {
    public struct Notes: Codable, Equatable {
        public let zh: [String]
        public let en: [String]
        public init(zh: [String], en: [String]) { self.zh = zh; self.en = en }
    }
    public let version: String
    public let build: Int
    public let url: URL
    public let size: Int64
    public let sha256: String
    public let minimumSystemVersion: String
    public let published: String
    public let notes: Notes
    public var release: UpdateVersion { UpdateVersion(version, build: build)! }

    public static func parse(_ data: Data, allowLocalhost: Bool = false) throws -> Self {
        guard data.count <= 1_048_576, let value = try? JSONDecoder().decode(Self.self, from: data),
              UpdateVersion(value.version, build: value.build) != nil, value.size > 0,
              value.sha256.count == 64, value.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              systemComponents(value.minimumSystemVersion) != nil,
              value.published.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              !value.notes.zh.isEmpty, !value.notes.en.isEmpty,
              (value.notes.zh + value.notes.en).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 16_384 }),
              validURL(value.url, allowLocalhost: allowLocalhost) else { throw UpdateFailure.other }
        return value
    }
    static func validURL(_ url: URL, allowLocalhost: Bool) -> Bool {
        guard url.user == nil, url.password == nil, url.fragment == nil, let host = url.host, !host.isEmpty else { return false }
        return url.scheme == "https" || (allowLocalhost && url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
    }
    private static func systemComponents(_ text: String) -> [Int]? {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count) else { return nil }
        var values: [Int] = []
        for part in pieces {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int(part) else { return nil }
            values.append(n)
        }
        return values + Array(repeating: 0, count: 3 - values.count)
    }
    public func supports(_ system: OperatingSystemVersion) -> Bool {
        guard let minimum = Self.systemComponents(minimumSystemVersion) else { return false }
        return ![system.majorVersion, system.minorVersion, system.patchVersion].lexicographicallyPrecedes(minimum)
    }
}

public final class UpdatePreferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var automatic: Bool {
        get { defaults.object(forKey: "automaticUpdates") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "automaticUpdates") }
    }
    public func skip(_ manifest: UpdateManifest) { defaults.set(manifest.version, forKey: "skippedUpdateVersion") }
    public func shouldOffer(_ manifest: UpdateManifest, current: UpdateVersion, system: OperatingSystemVersion, manual: Bool) -> Bool {
        manifest.release > current && manifest.supports(system) && (manual || defaults.string(forKey: "skippedUpdateVersion") != manifest.version)
    }
}
