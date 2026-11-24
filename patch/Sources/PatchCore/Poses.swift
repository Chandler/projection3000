import Foundation

/// COCO keypoints in this exact order. Normalized to the full video canvas,
/// with a top-left origin, including any upstream fit/rotation/mirroring.
public struct PosePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var confidence: Double
    public init(x: Double, y: Double, confidence: Double) {
        self.x = x; self.y = y; self.confidence = confidence
    }
    public static let names = ["nose", "leftEye", "rightEye", "leftEar", "rightEar", "leftShoulder", "rightShoulder", "leftElbow", "rightElbow", "leftWrist", "rightWrist", "leftHip", "rightHip", "leftKnee", "rightKnee", "leftAnkle", "rightAnkle"]
}
public struct DetectedPose: Codable, Sendable {
    public var bounds: FaceBounds
    public var confidence: Double
    public var keypoints: [PosePoint]
    public init(bounds: FaceBounds, confidence: Double, keypoints: [PosePoint]) {
        self.bounds = bounds; self.confidence = confidence; self.keypoints = keypoints
    }
}
public struct PoseFrame: Codable, Sendable {
    public var sequence: Int
    /// Monotonic host time at submission, not movie playhead time.
    public var timestamp: Double
    public var width: Int
    public var height: Int
    public var inferenceMS: Double
    public var poses: [DetectedPose]
    public init(sequence: Int, timestamp: Double, width: Int, height: Int, inferenceMS: Double, poses: [DetectedPose]) {
        self.sequence = sequence; self.timestamp = timestamp; self.width = width; self.height = height
        self.inferenceMS = inferenceMS; self.poses = poses
    }
}
