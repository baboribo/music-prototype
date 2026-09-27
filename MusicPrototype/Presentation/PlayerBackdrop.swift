import SwiftUI
import UIKit

/// Artwork-derived color field; content rendering, not a glass/material effect.
/// Fitted to Apple Music player screenshots with colour and greyscale artwork:
/// a heavily blurred artwork colour field whose brightness ramps ×0.60 → ×0.40
/// and saturation ×0.1 → ×1.0 from top to bottom (RMS 18.7/255 on both).
/// Neither reference exceeds ~0.52 saturation, hence the 0.55 ceiling.
struct PlayerBackdrop: View {
    let theme: ArtworkTheme

    var body: some View {
        LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    private var stops: [Gradient.Stop] {
        let colors = ArtworkView.colors(for: theme).map(Self.rgb)
        let first = colors[0], last = colors[colors.count - 1]
        return stride(from: 0.0, through: 1.0, by: 0.25).map { f in
            // The fixture art runs top-leading → bottom-trailing; a very wide blur
            // leaves a mostly averaged colour that leans toward each end.
            let t = 0.3 + 0.4 * f
            let base = UIColor(red: first.0 + (last.0 - first.0) * t,
                               green: first.1 + (last.1 - first.1) * t,
                               blue: first.2 + (last.2 - first.2) * t, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            base.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            return .init(color: Color(hue: h, saturation: min(0.55, s * (0.1 + 0.9 * f)),
                                      brightness: min(1, v * (0.6 - 0.2 * f))),
                         location: f)
        }
    }

    private static func rgb(_ color: Color) -> (CGFloat, CGFloat, CGFloat) {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b)
    }
}
