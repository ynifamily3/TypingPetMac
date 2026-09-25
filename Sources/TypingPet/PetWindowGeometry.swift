import Foundation

struct PetResizeGeometry {
    static func scale(
        initialScale: CGFloat,
        initialSize: CGSize,
        dragDelta: CGPoint,
        minimumScale: CGFloat = 0.35,
        maximumScale: CGFloat = 1.25
    ) -> CGFloat {
        guard initialSize.width > 0, initialSize.height > 0 else {
            return min(max(initialScale, minimumScale), maximumScale)
        }

        let horizontalFactor = (initialSize.width + dragDelta.x) / initialSize.width
        let verticalFactor = (initialSize.height + dragDelta.y) / initialSize.height
        let normalizedHorizontalDrag = abs(dragDelta.x / initialSize.width)
        let normalizedVerticalDrag = abs(dragDelta.y / initialSize.height)
        let factor = normalizedHorizontalDrag >= normalizedVerticalDrag
            ? horizontalFactor
            : verticalFactor

        return min(max(initialScale * factor, minimumScale), maximumScale)
    }
}
