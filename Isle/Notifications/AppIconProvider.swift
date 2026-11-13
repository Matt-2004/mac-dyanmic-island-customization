import AppKit
import Combine
import OSLog

/// Resolves the icon shown next to a notification.
///
/// Order: installed app by bundle ID → installed app by name (including browser
/// web apps in `~/Applications/<Browser> Apps.localized`) → the website's own
/// icon for web services such as Messenger or Gmail (fetched once, cached on
/// disk) → a lettered badge. Only the service's public domain is contacted;
/// nothing about the notification is sent.
@MainActor
final class AppIconProvider: ObservableObject {
    static let shared = AppIconProvider()

    /// Bumped whenever a new icon becomes available so observing views refresh.
    @Published private(set) var revision = 0

    /// Turned off from Settings to avoid any network access.
    var webIconsEnabled = true

    private var memory: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    private var failedDomains: [String: Date] = [:]
    private let log = Logger(subsystem: "com.wai.Isle", category: "icons")
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        ]
        return URLSession(configuration: configuration)
    }()

    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("com.wai.Isle/icons", isDirectory: true)
    }

    /// Returns the best icon available right now and starts fetching a better one if needed.
    func icon(bundleIdentifier: String?, appName: String) -> NSImage? {
        let key = bundleIdentifier ?? appName
        if let cached = memory[key] {
            return cached
        }
        if let local = localIcon(bundleIdentifier: bundleIdentifier, appName: appName) {
            memory[key] = local
            return local
        }
        if let match = WebServiceDirectory.lookup(appName: appName) {
            if let disk = loadFromDisk(domain: match.domain) {
                memory[key] = disk
                return disk
            }
            fetchWebIcon(domain: match.domain, key: key, verifyName: match.isGuess ? appName : nil)
        }
        return nil
    }

    func icon(for notification: IslandNotification) -> NSImage? {
        icon(bundleIdentifier: notification.bundleIdentifier, appName: notification.appName)
    }

    // MARK: Local apps

    private func localIcon(bundleIdentifier: String?, appName: String) -> NSImage? {
        let workspace = NSWorkspace.shared
        if let bundleIdentifier, let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return workspace.icon(forFile: url.path)
        }
        // macOS system notifications that are posted under a feature name rather than an app name.
        let systemNames = [
            "Login Items": "com.apple.systempreferences",
            "Background Items": "com.apple.systempreferences",
            "Software Update": "com.apple.systempreferences",
            "System Settings": "com.apple.systempreferences"
        ]
        if let systemBundle = systemNames[appName], let url = workspace.urlForApplication(withBundleIdentifier: systemBundle) {
            return workspace.icon(forFile: url.path)
        }
        if let resolved = AppNameResolver.bundleIdentifier(forAppName: appName),
           let url = workspace.urlForApplication(withBundleIdentifier: resolved) {
            return workspace.icon(forFile: url.path)
        }
        return nil
    }

    // MARK: Web icons

    /// `verifyName`: for guessed domains, the page must mention this name in its title or
    /// site name, otherwise the icon is rejected (avoids showing an unrelated site's icon).
    private func fetchWebIcon(domain: String, key: String, verifyName: String?) {
        guard webIconsEnabled, !inFlight.contains(domain) else { return }
        if let failed = failedDomains[domain], Date().timeIntervalSince(failed) < 3600 { return }
        inFlight.insert(domain)
        let session = self.session
        Task { [weak self] in
            let result = await Self.downloadIcon(domain: domain, session: session, verifyName: verifyName)
            guard let self else { return }
            self.inFlight.remove(domain)
            guard let (image, data) = result else {
                self.failedDomains[domain] = Date()
                self.log.notice("No web icon for \(domain, privacy: .public)")
                FileLog.write("icons: no web icon for \(domain)")
                return
            }
            self.saveToDisk(data: data, domain: domain)
            self.memory[key] = image
            self.revision += 1
            FileLog.write("icons: fetched web icon for \(domain)")
        }
    }

    /// Reads the page's `<link rel="…icon…">` tags, tries the largest first, then common fallbacks.
    nonisolated private static func downloadIcon(domain: String, session: URLSession, verifyName: String?) async -> (NSImage, Data)? {
        guard let pageURL = URL(string: "https://\(domain)/") else { return nil }
        var candidates: [URL] = []
        if let (data, response) = try? await session.data(from: pageURL),
           let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
            let html = String(decoding: data.prefix(600_000), as: UTF8.self)
            if let verifyName, !IconLinkParser.page(html, mentions: verifyName) {
                return nil
            }
            let base = http.url ?? pageURL
            candidates = IconLinkParser.iconURLs(in: html, baseURL: base)
        } else if verifyName != nil {
            // A guessed domain we can't even load is not trustworthy.
            return nil
        }
        for path in ["/apple-touch-icon.png", "/favicon.ico"] {
            if let url = URL(string: "https://\(domain)\(path)") {
                candidates.append(url)
            }
        }
        for url in candidates {
            guard let (data, response) = try? await session.data(from: url),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  !(http.mimeType ?? "").contains("html"),
                  let image = NSImage(data: data),
                  image.size.width >= 16, image.size.height >= 16,
                  let png = pngData(from: image) else { continue }
            return (image, png)
        }
        return nil
    }

    nonisolated private static func pngData(from image: NSImage) -> Data? {
        // Pick the largest representation (ICO files contain several sizes).
        let best = image.representations.max { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }
        let side = max(64, min(256, best?.pixelsWide ?? 128))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        return bitmap.representation(using: .png, properties: [:])
    }

    private func fileURL(domain: String) -> URL {
        Self.cacheDirectory.appendingPathComponent("\(domain).png")
    }

    private func loadFromDisk(domain: String) -> NSImage? {
        let url = fileURL(domain: domain)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }

    private func saveToDisk(data: Data, domain: String) {
        let url = fileURL(domain: domain)
        do {
            try FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("Failed to cache icon: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deletes downloaded web icons.
    func clearWebIconCache() {
        try? FileManager.default.removeItem(at: Self.cacheDirectory)
        failedDomains.removeAll()
        memory.removeAll()
        revision += 1
    }
}

/// Extracts icon URLs from HTML `<link>` tags, best first.
enum IconLinkParser {
    static func iconURLs(in html: String, baseURL: URL) -> [URL] {
        let linkPattern = #"<link\b[^>]*>"#
        guard let linkRegex = try? NSRegularExpression(pattern: linkPattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var scored: [(score: Int, url: URL)] = []
        for match in linkRegex.matches(in: html, range: range) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            guard let rel = attribute("rel", in: tag)?.lowercased(), rel.contains("icon"), !rel.contains("mask-icon"),
                  let href = attribute("href", in: tag),
                  let url = URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: baseURL)?.absoluteURL else { continue }
            var score = 0
            if rel.contains("apple-touch-icon") { score += 1000 }
            if let sizes = attribute("sizes", in: tag), let first = sizes.split(separator: "x").first, let value = Int(first) {
                score += min(value, 512)
            }
            if url.pathExtension.lowercased() == "svg" { score -= 2000 }
            scored.append((score, url))
        }
        return scored.sorted { $0.score > $1.score }.map(\.url)
    }

    /// True when the page's <title> or og:site_name / application-name contains `name`
    /// (case- and diacritic-insensitive).
    static func page(_ html: String, mentions name: String) -> Bool {
        var labels: [String] = []
        if let titleRegex = try? NSRegularExpression(pattern: "<title[^>]*>([^<]*)</title>", options: [.caseInsensitive]),
           let match = titleRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            labels.append(String(html[range]))
        }
        if let metaRegex = try? NSRegularExpression(pattern: #"<meta\b[^>]*>"#, options: [.caseInsensitive]) {
            for match in metaRegex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let range = Range(match.range, in: html) else { continue }
                let tag = String(html[range])
                let key = (attribute("property", in: tag) ?? attribute("name", in: tag))?.lowercased()
                if key == "og:site_name" || key == "application-name" || key == "og:title",
                   let content = attribute("content", in: tag) {
                    labels.append(content)
                }
            }
        }
        let needle = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return labels.contains { label in
            label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(needle)
        }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let valueRange = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[valueRange])
    }
}

/// Maps notification app names of web services (browser notifications / web apps) to their domain.
enum WebServiceDirectory {
    private static let known: [String: String] = [
        "messenger": "www.messenger.com",
        "facebook": "www.facebook.com",
        "instagram": "www.instagram.com",
        "whatsapp": "web.whatsapp.com",
        "gmail": "mail.google.com",
        "google chat": "chat.google.com",
        "google calendar": "calendar.google.com",
        "google meet": "meet.google.com",
        "google drive": "drive.google.com",
        "youtube": "www.youtube.com",
        "youtube music": "music.youtube.com",
        "discord": "discord.com",
        "slack": "slack.com",
        "telegram": "web.telegram.org",
        "x": "x.com",
        "twitter": "x.com",
        "linkedin": "www.linkedin.com",
        "outlook": "outlook.live.com",
        "microsoft teams": "teams.microsoft.com",
        "teams": "teams.microsoft.com",
        "zalo": "chat.zalo.me",
        "line": "line.me",
        "viber": "www.viber.com",
        "signal": "signal.org",
        "notion": "www.notion.so",
        "trello": "trello.com",
        "github": "github.com",
        "reddit": "www.reddit.com",
        "tiktok": "www.tiktok.com",
        "抖音": "www.douyin.com",
        "spotify": "open.spotify.com",
        "netflix": "www.netflix.com",
        "figma": "www.figma.com",
        "asana": "app.asana.com",
        "jira": "www.atlassian.com",
        "zoom": "zoom.us",
        "skype": "web.skype.com",
        "wechat": "web.wechat.com",
        "threads": "www.threads.net",
        "pinterest": "www.pinterest.com",
        "shopee": "shopee.com",
        "lazada": "www.lazada.com",
        "grab": "www.grab.com"
    ]

    /// Known services first; otherwise a single-word name is tried as `<name>.com`
    /// (`isGuess` — the download then verifies the page really is that service).
    static func lookup(appName name: String) -> (domain: String, isGuess: Bool)? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, normalized != "notification" else { return nil }
        if let domain = known[normalized] {
            return (domain, false)
        }
        let isSimpleWord = normalized.count >= 3 && normalized.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return isSimpleWord ? ("\(normalized).com", true) : nil
    }
}
