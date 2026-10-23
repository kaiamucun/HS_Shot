import CoreGraphics

enum QuickAccessGeometry {
    static func panelSize(for imageSize: CGSize) -> CGSize {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: 210, height: 118.125)
        }
        let scale = min(210 / imageSize.width, 150 / imageSize.height)
        // Extreme aspect ratios use a small canvas around the fitted image so hover actions remain usable.
        return CGSize(width: max(128, imageSize.width * scale), height: max(64, imageSize.height * scale))
    }
}
