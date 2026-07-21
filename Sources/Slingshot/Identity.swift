import SlingshotCore
import AppKit
import CoreImage
import Vision

// MARK: - Transfer modes and face identity

/// Normal: the hold carries the grabber's face print, and the receiving Mac only
/// completes the drop for a matching face. Best effort, not a security boundary:
/// the print is a Vision image-similarity embedding, not a face-recognition model.
/// Pro: anyone at any connected Mac can catch.
enum TransferMode: String { case normal, pro }

let modeLock = NSLock()
private var currentModeStorage: TransferMode = .normal
/// Set from the menu bar, read on the camera and grab queues.
var currentMode: TransferMode {
    get { modeLock.withLock { currentModeStorage } }
    set { modeLock.withLock { currentModeStorage = newValue } }
}

// The acceptance threshold is no longer a constant here. Each hold calibrates
// its own: see enroll() below and FaceLock.swift in SlingshotCore. The old
// 0.55 constant survives only as legacyFaceThreshold for holds from peers
// that sent a single print.

/// Latest camera frame, shared safely across the camera, grab, and catch threads.
final class FrameStore {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var handAt = Date.distantPast
    func set(_ pb: CVPixelBuffer) { lock.withLock { buffer = pb } }
    func latest() -> CVPixelBuffer? { lock.withLock { buffer } }
    func clear() { lock.withLock { buffer = nil } }
    func markHand() { lock.withLock { handAt = Date() } }
    func lastHand() -> Date { lock.withLock { handAt } }
}
let frameStore = FrameStore()

/// Face feature-prints for "is this the same person who grabbed?".
/// Fresh Vision requests per call, so concurrent grab and catch paths share no state.
enum FaceID {
    /// One face print plus Apple's capture-quality score for the frame it came
    /// from (0 worst to 1 best, comparable only on the same Mac).
    struct Sample {
        let print: VNFeaturePrintObservation
        let quality: Float
    }

    /// Frames whose best face scores below this are junk (motion blur, half a
    /// face at the frame edge) and are not worth printing.
    private static let minQuality: Float = 0.1

    static func sample(from pixelBuffer: CVPixelBuffer) -> Sample? {
        // Capture quality detection also returns the bounding boxes, so one
        // request gives us both the crop and a way to rank frames.
        let faceRequest = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        guard (try? handler.perform([faceRequest])) != nil,
              let faces = faceRequest.results, !faces.isEmpty else { return nil }
        let largest = faces.max { a, b in
            a.boundingBox.width * a.boundingBox.height < b.boundingBox.width * b.boundingBox.height
        }!
        let quality = largest.faceCaptureQuality ?? 0
        guard quality >= minQuality else { return nil }

        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let w = ci.extent.width
        let h = ci.extent.height
        let bb = largest.boundingBox
        let raw = CGRect(x: bb.minX * w, y: bb.minY * h, width: bb.width * w, height: bb.height * h)
        let padded = raw.insetBy(dx: -raw.width * 0.15, dy: -raw.height * 0.15)
        let crop = padded.intersection(ci.extent)
        guard !crop.isNull, crop.width > 20, crop.height > 20,
              let cg = CIContext(options: nil).createCGImage(ci, from: crop) else { return nil }

        let fpRequest = VNGenerateImageFeaturePrintRequest()
        if #available(macOS 14.0, *) {
            // Pin the revision: the distance scale changes completely between revisions.
            fpRequest.revision = VNGenerateImageFeaturePrintRequestRevision2
        }
        let fpHandler = VNImageRequestHandler(cgImage: cg, orientation: .up)
        guard (try? fpHandler.perform([fpRequest])) != nil,
              let print = fpRequest.results?.first as? VNFeaturePrintObservation else { return nil }
        return Sample(print: print, quality: quality)
    }

    struct Enrollment {
        let prints: [VNFeaturePrintObservation]
        let threshold: Float
    }

    /// Grab-time enrollment: sample the grabber's face across several frames,
    /// keep the best few by capture quality, and measure how much the SAME face
    /// on the SAME camera varies between them. That measured spread, not a
    /// constant, sets the acceptance threshold that travels with the hold.
    /// Blocking; call off the camera queue so frames keep flowing underneath.
    static func enroll(frames: () -> CVPixelBuffer?,
                       samples: Int = 4, interval: TimeInterval = 0.25) -> Enrollment? {
        var collected: [Sample] = []
        for i in 0..<samples {
            if let frame = frames(), let s = sample(from: frame) {
                collected.append(s)
            }
            if i < samples - 1 { Thread.sleep(forTimeInterval: interval) }
        }
        guard !collected.isEmpty else { return nil }
        let best = Array(collected.sorted { $0.quality > $1.quality }.prefix(3))

        var intra: [Float] = []
        for i in 0..<best.count {
            for j in (i + 1)..<best.count {
                if let d = distance(best[i].print, best[j].print) { intra.append(d) }
            }
        }
        let threshold = faceLockThreshold(intraDistances: intra)
        let spread = intra.max() ?? 0
        log(String(format: "🙂 Face enrolled: %d prints, quality %.2f best, spread %.3f, threshold %.2f",
                   best.count, best.first?.quality ?? 0, spread, threshold))
        return Enrollment(prints: best.map { $0.print }, threshold: threshold)
    }

    enum Verdict {
        case matched(Float)
        case blocked(Float)
        case noFace
        case incomparable
    }

    /// Catch-time check: give the catcher several looks over about a second and
    /// a half instead of judging one frame. A sample matches when its distance
    /// to ANY enrolled print clears the hold's own threshold; one good look is
    /// enough. Blocking; call off the camera queue.
    static func verify(enrolled: [VNFeaturePrintObservation], threshold: Float,
                       frames: () -> CVPixelBuffer?,
                       attempts: Int = 5, interval: TimeInterval = 0.3) -> Verdict {
        var sawFace = false
        var comparableSeen = false
        var best = Float.greatestFiniteMagnitude
        for i in 0..<attempts {
            if let frame = frames(), let s = sample(from: frame) {
                sawFace = true
                let ds = enrolled.compactMap { distance($0, s.print) }
                if let d = ds.min() {
                    comparableSeen = true
                    best = min(best, d)
                    if faceLockAccepts(candidateDistances: [d], threshold: threshold) {
                        return .matched(d)
                    }
                }
            }
            if i < attempts - 1 { Thread.sleep(forTimeInterval: interval) }
        }
        guard sawFace else { return .noFace }
        guard comparableSeen else { return .incomparable }
        return .blocked(best)
    }

    static func encode(_ obs: VNFeaturePrintObservation) -> String? {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: obs, requiringSecureCoding: true)
        else { return nil }
        return data.base64EncodedString()
    }

    static func decode(_ s: String) -> VNFeaturePrintObservation? {
        guard let data = Data(base64Encoded: s) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }

    /// Smaller is more similar. nil when the prints are incomparable (mixed Vision revisions).
    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float? {
        var d: Float = 0
        guard (try? a.computeDistance(&d, to: b)) != nil else { return nil }
        return d
    }
}

