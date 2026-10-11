import Foundation

// Pure startup logic: callers persist the flags and execute each returned index request once.
public struct WelcomeState {
    public private(set) var didFinishOnboarding: Bool
    public private(set) var skippedFullDiskAccess: Bool
    public private(set) var granted: Bool
    public private(set) var indexLimited: Bool?
    public var isShowing: Bool { !didFinishOnboarding }

    public init(didFinishOnboarding: Bool, skippedFullDiskAccess: Bool, granted: Bool) {
        self.didFinishOnboarding = didFinishOnboarding
        self.skippedFullDiskAccess = skippedFullDiskAccess
        self.granted = granted
    }
    public mutating func launch() -> Bool? {
        requestIndex(granted ? false : didFinishOnboarding ? true : nil)
    }
    public mutating func permissionDetected(_ granted: Bool) -> Bool? {
        self.granted = granted
        return granted && isShowing ? requestIndex(false) : nil
    }
    public mutating func finish() -> Bool? {
        guard isShowing else { return nil }
        didFinishOnboarding = true
        if !granted && indexLimited == nil { skippedFullDiskAccess = true }
        return requestIndex(granted ? false : true)
    }
    public mutating func close() -> Bool? { finish() }
    private mutating func requestIndex(_ limited: Bool?) -> Bool? {
        guard let limited, indexLimited == nil else { return nil }
        indexLimited = limited
        return limited
    }
}
