import Foundation

/// Coordinates are normalized to the analyzed video canvas, origin at top-left.
/// Landmarks are absolute canvas coordinates, not relative to the face bounds.
public struct FacePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}
public struct FaceBounds: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public static func fromVision(x: Double, y: Double, width: Double, height: Double) -> Self {
        .init(x:x, y:1-y-height, width:width, height:height)
    }
    public func landmark(x: Double, y: Double) -> FacePoint {
        .init(x:self.x + x * width, y:self.y + (1-y) * height)
    }
}
public struct DetectedFace: Codable, Equatable, Sendable {
    public var bounds: FaceBounds
    public var confidence: Double
    public var landmarks: [String:[FacePoint]]
    public init(bounds: FaceBounds, confidence: Double, landmarks: [String:[FacePoint]]) {
        self.bounds = bounds; self.confidence = confidence; self.landmarks = landmarks
    }
}
public struct FaceFrame: Codable, Sendable {
    public var sequence: Int
    /// Monotonic host time in seconds when the analyzed frame was submitted.
    public var timestamp: Double
    public var width: Int
    public var height: Int
    public var inferenceMS: Double
    public var faces: [DetectedFace]
    public init(sequence: Int, timestamp: Double, width: Int, height: Int, inferenceMS: Double, faces: [DetectedFace]) {
        self.sequence = sequence; self.timestamp = timestamp; self.width = width; self.height = height
        self.inferenceMS = inferenceMS; self.faces = faces
    }
}
