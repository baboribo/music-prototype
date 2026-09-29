import AVFAudio
import SwiftUI
import WebKit

@main
struct WebPlayerSpikeApp: App {
    init() {
        // Playback category so page audio continues in background / on lock, as a music app's would.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }

    var body: some Scene {
        WindowGroup { SpikeView() }
    }
}

/// Paired ATV/OMV tracks taken from authenticated /next responses.
enum Fixture: String, CaseIterable, Identifiable {
    case nightLetterSong = "NnRjwEhFU70"   // 밤편지 (ATV) ↔ BzYnNdJhZQw (OMV), video starts +24.013s
    case purpleNightSong = "wh7j1uEpNsQ"   // 보라빛 밤 (ATV) ↔ H8YW1tlsmE8 (OMV), video starts +11.521s
    var id: String { rawValue }
    var label: String { self == .nightLetterSong ? "밤편지" : "보라빛 밤" }
}

@MainActor
@Observable
final class ProbeLog {
    private(set) var lines: [String] = []
    private let file: URL = URL.documentsDirectory.appending(path: "probe.log")

    init() { try? Data().write(to: file) }

    func append(_ kind: String, _ body: [String: Any]) {
        var entry = body
        entry["kind"] = kind
        entry["t"] = Date().timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        lines.append(line)
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        }
    }
}

/// Native evidence the page cannot report: lifecycle, system volume, route, interruptions.
@MainActor
final class SystemObserver {
    private var volume: NSKeyValueObservation?
    private var tokens: [NSObjectProtocol] = []
    private var heartbeat: Task<Void, Never>?

    func start(log: ProbeLog, controller: WebController) {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(true)
        log.append("volume", ["value": session.outputVolume, "initial": true])
        volume = session.observe(\.outputVolume, options: [.new]) { _, change in
            let value = change.newValue ?? -1
            Task { @MainActor in log.append("volume", ["value": value]) }
        }
        let center = NotificationCenter.default
        let names: [(Notification.Name, String)] = [
            (UIApplication.didEnterBackgroundNotification, "background"),
            (UIApplication.willEnterForegroundNotification, "foreground"),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "locked"),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "unlocked"),
            (AVAudioSession.interruptionNotification, "interruption"),
            (AVAudioSession.routeChangeNotification, "route"),
        ]
        for (name, label) in names {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] ?? note.userInfo?[AVAudioSessionInterruptionTypeKey]) as? UInt
                let output = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType.rawValue ?? "?"
                MainActor.assumeIsolated {
                    log.append("app", ["event": label, "reason": reason.map { Int($0) } ?? -1, "output": output])
                }
            })
        }
        heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                controller.run("__probe.snapshot()")
            }
        }
    }
}

struct SpikeView: View {
    @State private var log = ProbeLog()
    @State private var controller = WebController()
    @State private var observer = SystemObserver()
    @State private var desktop = false
    @State private var auth: AuthProbe?

    var body: some View {
        VStack(spacing: 0) {
            WebPlayerView(controller: controller, log: log, desktop: desktop)
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Fixture.allCases) { f in
                            Button(f.label) { controller.load(videoID: f.rawValue) }
                                .accessibilityIdentifier("load.\(f.rawValue)")
                        }
                        Button("Play") { controller.run("__probe.play()") }.accessibilityIdentifier("play")
                        Button("Toggle") { controller.run("__probe.toggle()") }.accessibilityIdentifier("toggle")
                        Button("Snapshot") { controller.run("__probe.snapshot()") }.accessibilityIdentifier("snapshot")
                        Button(desktop ? "Mobile UA" : "Desktop UA") { desktop.toggle() }.accessibilityIdentifier("ua")
                        Button("Home") { controller.loadHome() }.accessibilityIdentifier("home")
                        Button("Control") { controller.loadControl() }.accessibilityIdentifier("control")
                    }
                    .buttonStyle(.bordered)
                }
                ScrollView(.horizontal) {
                    HStack {
                        Button("Cookies") { Task { await auth?.inventory() } }.accessibilityIdentifier("auth.inventory")
                        Button("Page") { Task { if let w = controller.webView { await auth?.pageState(w) } } }.accessibilityIdentifier("auth.page")
                        Button("Native") { Task { await auth?.nativeRequest(client: WebController.remix) } }.accessibilityIdentifier("auth.native")
                        Button("Logout(iso)") { Task { await auth?.logoutOnIsolatedStore() } }.accessibilityIdentifier("auth.logout")
                        Button("Artist") { controller.loadArtist() }.accessibilityIdentifier("auth.artist")
                    }
                    .buttonStyle(.bordered)
                }
                Text(log.lines.last ?? "no events")
                    .font(.caption2.monospaced())
                    .lineLimit(3)
            }
            .padding(8)
            .background(.bar)
        }
        .task {
            observer.start(log: log, controller: controller)
            let probe = AuthProbe(log: log)
            auth = probe
            if let webView = controller.webView { probe.attach(webView) }
            // SPIKE_AUTOPROBE=1: one auth pass after the first page load (Simulator runs).
            guard ProcessInfo.processInfo.environment["SPIKE_AUTOPROBE"] == "1" else { return }
            try? await Task.sleep(for: .seconds(8))
            await probe.inventory()
            if let webView = controller.webView { await probe.pageState(webView) }
            await probe.nativeRequest(client: WebController.remix)
            await probe.logoutOnIsolatedStore()
        }
    }
}

@MainActor
final class WebController {
    weak var webView: WKWebView?

    func load(videoID: String) {
        webView?.load(URLRequest(url: URL(string: "https://music.youtube.com/watch?v=\(videoID)")!))
    }

    func loadHome() {
        webView?.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))
    }

    /// WEB_REMIX identity used by the app's InnerTube client (yt-dlp master, 2026-09).
    static let remix = (name: "WEB_REMIX", id: "67", version: "1.20260707.12.00")

    /// An artist page, for the official web's own subscribe flow (the user taps it).
    func loadArtist() {
        webView?.load(URLRequest(url: URL(string: "https://music.youtube.com/channel/UCTUR0sVEkD8T5MlSHqgaI_Q")!))
    }

    func loadControl() {
        webView?.load(URLRequest(url: URL(string: "spike://local/control.html")!))
    }

    func run(_ js: String) {
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
}

/// Serves bundled control-test files at spike://local/<name>, honouring byte ranges.
final class LocalSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url,
              let file = Bundle.main.url(forResource: url.lastPathComponent, withExtension: nil),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let mime = switch file.pathExtension {
        case "html": "text/html"
        case "m4a": "audio/mp4"
        default: "video/mp4"
        }
        var body = data
        var status = 200
        var headers = ["Content-Type": mime, "Accept-Ranges": "bytes", "Content-Length": String(data.count)]
        if let range = task.request.value(forHTTPHeaderField: "Range"),
           let spec = range.split(separator: "=").last?.split(separator: "-", omittingEmptySubsequences: false),
           let start = Int(spec.first ?? "") {
            let end = min(Int(spec.count > 1 ? spec[1] : "") ?? (data.count - 1), data.count - 1)
            body = data.subdata(in: start..<(end + 1))
            status = 206
            headers["Content-Range"] = "bytes \(start)-\(end)/\(data.count)"
            headers["Content-Length"] = String(body.count)
        }
        task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

struct WebPlayerView: UIViewRepresentable {
    let controller: WebController
    let log: ProbeLog
    let desktop: Bool

    func makeCoordinator() -> Coordinator { Coordinator(log: log) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Persistent store: the user's own sign-in in this web view survives relaunches.
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.setURLSchemeHandler(LocalSchemeHandler(), forURLScheme: "spike")
        config.userContentController.add(context.coordinator, name: "probe")
        config.userContentController.addUserScript(
            WKUserScript(source: ProbeScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addUserScript(
            WKUserScript(source: NetworkObserverScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isInspectable = true
        controller.webView = webView
        webView.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let mode: WKWebpagePreferences.ContentMode = desktop ? .desktop : .mobile
        if context.coordinator.contentMode != mode {
            context.coordinator.contentMode = mode
            webView.configuration.defaultWebpagePreferences.preferredContentMode = mode
            log.append("ua", ["mode": desktop ? "desktop" : "mobile"])
            webView.reload()
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let log: ProbeLog
        var contentMode: WKWebpagePreferences.ContentMode = .recommended

        init(log: ProbeLog) { self.log = log }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard var body = message.body as? [String: Any] else { return }
            let kind = body.removeValue(forKey: "kind") as? String ?? "?"
            log.append(kind, body)
        }

        /// A user-initiated cross-site hop to youtube.com (e.g. the sign-in redirect) is
        /// handed to the installed YouTube app as a universal link. Re-issuing the same GET
        /// as a programmatic load keeps it in this web view.
        private var reissued: Set<URL> = []

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, let host = url.host(),
                  action.targetFrame?.isMainFrame ?? true,
                  action.request.httpMethod == "GET",
                  host.hasSuffix("youtube.com"),
                  webView.url?.host() != host,
                  !reissued.contains(url)
            else { decisionHandler(.allow); return }
            reissued.insert(url)
            decisionHandler(.cancel)
            log.append("reissue", ["host": host, "path": url.path()])
            webView.load(action.request)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Host and path only: no query values from sign-in pages.
            log.append("nav", ["host": webView.url?.host() ?? "?", "path": webView.url?.path() ?? "?"])
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            log.append("navError", ["error": (error as NSError).localizedDescription])
        }
    }
}
