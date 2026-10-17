import SwiftUI

enum OverlayStyle {
    static let backgroundNSColor = NSColor(
        calibratedRed: 28.0 / 255.0,
        green: 31.0 / 255.0,
        blue: 36.0 / 255.0,
        alpha: 1
    )
    static let background = Color(nsColor: backgroundNSColor)
    static let contentWidth: CGFloat = 620
    static let compactButtonHeight: CGFloat = 34
    static var buttonShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }
}
