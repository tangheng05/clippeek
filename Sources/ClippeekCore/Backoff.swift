public enum Backoff {
    private static let steps: [Double] = [5, 30, 120, 600]
    /// After the steps, a rare retry so a server that comes back is noticed without a network change.
    public static let slowest: Double = 1800

    /// Seconds before retry `attempt` (from 0).
    public static func delay(attempt: Int) -> Double {
        attempt < steps.count ? steps[attempt] : slowest
    }

    public static func isPastSteps(_ attempt: Int) -> Bool {
        attempt >= steps.count
    }
}

/// What uploads care about in a network path, so repeated updates for the same network are ignored.
public struct NetworkPath: Equatable, Sendable {
    public var satisfied: Bool
    public var interface: String?
    public var constrained: Bool

    public init(satisfied: Bool, interface: String?, constrained: Bool) {
        self.satisfied = satisfied
        self.interface = interface
        self.constrained = constrained
    }

    /// True when this path could let through an upload that the previous one stopped.
    public func isReturn(from previous: NetworkPath?) -> Bool {
        guard satisfied else { return false }
        guard let previous, previous.satisfied else { return true }
        return interface != previous.interface || (previous.constrained && !constrained)
    }
}
