import SwiftUI
import CoreImage.CIFilterBuiltins

/// Generates a QR code NSImage from a string using CoreImage. Used for the
/// optional pairing code; purely local, no network involved.
enum QRCode {
    static func image(from string: String, scale: CGFloat = 8) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
            let cgImage = context.createCGImage(output, from: output.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
