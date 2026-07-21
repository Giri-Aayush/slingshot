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

/// Revision 2 feature-print distances run about 0 (identical) to 2 (unrelated).
/// Every check logs its distance so this cutoff can be tuned from real data.
let faceMatchThreshold: Float = 0.55

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
    static func faceprint(from pixelBuffer: CVPixelBuffer) -> VNFeaturePrintObservation? {
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        guard (try? handler.perform([faceRequest])) != nil,
              let faces = faceRequest.results, !faces.isEmpty else { return nil }
        let largest = faces.max { a, b in
            a.boundingBox.width * a.boundingBox.height < b.boundingBox.width * b.boundingBox.height
        }!

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
        guard (try? fpHandler.perform([fpRequest])) != nil else { return nil }
        return fpRequest.results?.first as? VNFeaturePrintObservation
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

