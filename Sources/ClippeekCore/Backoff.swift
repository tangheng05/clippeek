public enum Backoff {
    private static let steps: [Double] = [5, 30, 120, 600]

    /// Seconds before retry `attempt` (from 0). Nil means wait for the next network change.
    public static func delay(attempt: Int) -> Double? {
        attempt < steps.count ? steps[attempt] : nil
    }
}
