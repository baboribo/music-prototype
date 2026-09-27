import SwiftUI

// Local fixture artwork, not a downloaded album cover or a glass surface.
struct ArtworkView: View {
    let theme: ArtworkTheme
    var cornerRadius: CGFloat = 8

    private var colors: [Color] { Self.colors(for: theme) }

    static func colors(for theme: ArtworkTheme) -> [Color] {
        switch theme {
        case .midnight: [.indigo, Color(red: 0.10, green: 0.08, blue: 0.28)]
        case .coral: [.orange, .pink]
        case .amber: [.yellow, .orange]
        case .forest: [.mint, Color(red: 0.08, green: 0.30, blue: 0.23)]
        case .ocean: [.cyan, .blue]
        case .violet: [.purple, .indigo]
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle()
                    .stroke(.white.opacity(0.22), lineWidth: geometry.size.width * 0.09)
                    .padding(geometry.size.width * 0.17)
                Image(systemName: "waveform")
                    .font(.system(size: geometry.size.width * 0.22, weight: .light))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }
}
