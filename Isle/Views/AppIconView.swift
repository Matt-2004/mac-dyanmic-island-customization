import SwiftUI

/// Notification app icon that updates itself when a web icon finishes downloading.
struct AppIconView: View {
    let bundleIdentifier: String?
    let appName: String
    let size: CGFloat
    @ObservedObject private var provider = AppIconProvider.shared

    init(notification: IslandNotification, size: CGFloat) {
        bundleIdentifier = notification.bundleIdentifier
        appName = notification.appName
        self.size = size
    }

    var body: some View {
        // Reading `revision` makes this view refresh when new icons arrive.
        let _ = provider.revision
        if let image = provider.icon(bundleIdentifier: bundleIdentifier, appName: appName) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            LetterBadge(name: appName, size: size)
        }
    }
}

/// Coloured rounded square with the app's first letter; the colour is stable per name.
struct LetterBadge: View {
    let name: String
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(LetterBadgeStyle.color(for: name).gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(LetterBadgeStyle.letter(for: name))
                    .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }
}

enum LetterBadgeStyle {
    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .red]

    static func letter(for name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "•"
    }

    static func color(for name: String) -> Color {
        // Stable across launches (String.hashValue is randomly seeded).
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return palette[sum % palette.count]
    }

    /// AppKit rendering for menus.
    @MainActor
    static func image(for name: String, size: CGFloat) -> NSImage {
        let renderer = ImageRenderer(content: LetterBadge(name: name, size: size))
        renderer.scale = 2
        return renderer.nsImage ?? NSImage(size: NSSize(width: size, height: size))
    }
}
