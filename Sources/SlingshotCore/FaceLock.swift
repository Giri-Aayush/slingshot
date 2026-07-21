import Foundation

// MARK: - Face lock policy

/// The face lock's decision math, pure and tested. Distances come from Vision
/// feature prints (revision 2, roughly 0 identical to 2 unrelated).
///
/// Rather than trusting a fixed constant, each hold calibrates itself: the
/// grabber enrolls several prints of their own face seconds apart on one
/// camera, and the spread between those prints measures how much THIS face on
/// THIS camera varies when it is genuinely the same person. The acceptance
/// threshold scales from that measured spread, with margin for the camera
/// change at the catching Mac, and travels with the hold.

/// Fallback for holds that carry a single print (older peers, thin enrollment).
public let legacyFaceThreshold: Float = 0.55

/// Floor and ceiling keep a degenerate spread from producing an unusable
/// threshold in either direction.
public let faceThresholdFloor: Float = 0.30
public let faceThresholdCeiling: Float = 0.90

/// Spread multiplier: cross-camera, cross-lighting variance runs well above
/// same-session variance, so the margin is generous.
public let faceSpreadMargin: Float = 2.5

/// The carried threshold for a hold whose enrollment produced these pairwise
/// intra-person distances. Empty means calibration was impossible; fall back.
public func faceLockThreshold(intraDistances: [Float]) -> Float {
    guard let spread = intraDistances.max(), spread > 0 else { return legacyFaceThreshold }
    let scaled = spread * faceSpreadMargin + 0.10
    return min(max(scaled, faceThresholdFloor), faceThresholdCeiling)
}

/// Accept when any candidate sample clears the threshold: the catcher tries
/// several frames, and one good look is enough.
public func faceLockAccepts(candidateDistances: [Float], threshold: Float) -> Bool {
    guard let best = candidateDistances.min() else { return false }
    return best <= threshold
}
