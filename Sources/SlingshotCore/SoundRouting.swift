import Foundation

// MARK: - Sound-trigger routing

/// Which action one sound-classification window fires.
public enum SoundTrigger { case snap, clap }

/// Confidence a window needs on "finger_snapping" to count as a snap.
public let snapConfidenceThreshold = 0.5

/// Claps get a lower bar: a single real-room clap scores well under a crisp
/// close-mic snap, and a misfire costs one reversible action.
public let clapConfidenceThreshold = 0.35

/// Routes one classification window to at most one action. A snap and a clap
/// are near-identical transients, so per-window jitter decides which class the
/// classifier ranks higher. The rules are therefore:
/// - Only enabled actions compete: a class nobody consumes can never win the
///   window (and burn the caller's debounce) for the one that would have acted.
/// - Of the eligible actions, the higher-confidence class wins, so one physical
///   sound never fires two actions.
public func routeSoundWindow(snapConfidence: Double, clapConfidence: Double,
                             snapEnabled: Bool, clapEnabled: Bool) -> SoundTrigger? {
    let snapEligible = snapEnabled && snapConfidence >= snapConfidenceThreshold
    let clapEligible = clapEnabled && clapConfidence >= clapConfidenceThreshold
    guard snapEligible || clapEligible else { return nil }
    if snapEligible && (!clapEligible || snapConfidence >= clapConfidence) { return .snap }
    return .clap
}
