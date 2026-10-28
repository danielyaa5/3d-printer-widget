import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// One small, dated image per printer. Stored in the existing shared Keychain;
/// the widget never opens a camera or handles full-resolution video frames.
struct WidgetCameraSnapshot: Codable, Equatable, Sendable {
    let printerID: UUID
    let capturedAt: Date
    let jpeg: Data
    var generation: UUID?

    var image: CGImage? {
        guard jpeg.count <= 128 * 1024,
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                       kCGImageSourceThumbnailMaxPixelSize: 640,
                                       kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func capture(_ image: CGImage, printerID: UUID, capturedAt: Date,
                        generation: UUID? = nil, rotation: Int = 0, flipHorizontal: Bool = false, flipVertical: Bool = false) throws -> Self {
        let quarterTurn = rotation == 90 || rotation == 270
        let originalWidth = quarterTurn ? image.height : image.width
        let originalHeight = quarterTurn ? image.width : image.height
        guard originalWidth > 0, originalHeight > 0 else { throw PrinterError.invalidResponse }
        let scale = min(1, 640 / Double(max(originalWidth, originalHeight)))
        let width = max(1, Int(Double(originalWidth) * scale)), height = max(1, Int(Double(originalHeight) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw PrinterError.invalidResponse
        }
        context.interpolationQuality = .medium
        context.translateBy(x: Double(width) / 2, y: Double(height) / 2)
        context.scaleBy(x: flipHorizontal ? -scale : scale, y: flipVertical ? -scale : scale)
        context.rotate(by: -Double(rotation) * .pi / 180)
        context.draw(image, in: CGRect(x: -Double(image.width) / 2, y: -Double(image.height) / 2,
                                      width: Double(image.width), height: Double(image.height)))
        guard let thumbnail = context.makeImage() else { throw PrinterError.invalidResponse }
        for quality in [0.65, 0.4, 0.2] {
            let bytes = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw PrinterError.invalidResponse
            }
            CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), bytes.length <= 128 * 1024 {
                return Self(printerID: printerID, capturedAt: capturedAt, jpeg: bytes as Data, generation: generation)
            }
        }
        throw PrinterError.invalidResponse
    }
}

extension SharedVault {
    static func cameraSnapshot(for id: UUID) throws -> WidgetCameraSnapshot? {
        try read(WidgetCameraSnapshot.self, account: "camera-snapshot.\(id.uuidString)")
    }
    static func saveCameraSnapshot(_ snapshot: WidgetCameraSnapshot) throws {
        try write(snapshot, account: "camera-snapshot.\(snapshot.printerID.uuidString)")
    }
    static func deleteCameraSnapshot(for id: UUID) throws {
        try delete(account: "camera-snapshot.\(id.uuidString)")
    }
    static func cameraStatus(for id: UUID) throws -> WidgetCameraStatus? {
        try read(WidgetCameraStatus.self, account: "camera-status.\(id.uuidString)")
    }
    static func saveCameraStatus(_ status: WidgetCameraStatus) throws {
        try write(status, account: "camera-status.\(status.printerID.uuidString)")
    }
    static func deleteCameraStatus(for id: UUID) throws {
        try delete(account: "camera-status.\(id.uuidString)")
    }
}

/// Status of recent camera snapshot capture attempts for widgets.
struct WidgetCameraStatus: Codable, Equatable, Sendable {
    var printerID: UUID
    var isUnavailable: Bool
    var message: String?
    var updatedAt: Date

    init(printerID: UUID, isUnavailable: Bool, message: String? = nil, updatedAt: Date = Date()) {
        self.printerID = printerID
        self.isUnavailable = isUnavailable
        self.message = message
        self.updatedAt = updatedAt
    }
}
