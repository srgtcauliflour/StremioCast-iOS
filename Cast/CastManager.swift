import Foundation
import GoogleCast

@MainActor
final class CastManager: NSObject, ObservableObject,
                         @preconcurrency GCKSessionManagerListener,
                         @preconcurrency GCKRequestDelegate,
                         @preconcurrency GCKRemoteMediaClientListener {
    static let shared = CastManager()

    @Published private(set) var connected = false
    @Published private(set) var lastError: String?
    @Published private(set) var statusMessage = "Not connected"

    private var pending: (URL, String)?
    private var activeLoadRequest: GCKRequest?
    private weak var observedMediaClient: GCKRemoteMediaClient?
    private var initialized = false
    private var didPauseLocalForCurrentCast = false

    func setup() {
        guard !initialized else { return }
        initialized = true
        let options = GCKCastOptions(
            discoveryCriteria: GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        )
        GCKCastContext.setSharedInstanceWith(options)
        let context = GCKCastContext.sharedInstance()
        context.sessionManager.add(self)
        context.useDefaultExpandedMediaControls = true

        GCKLogger.sharedInstance().delegate = self
        let filter = GCKLoggerFilter()
        filter.minimumLevel = .info
        GCKLogger.sharedInstance().filter = filter
    }

    /// Keep the selected stream ready before GCKUICastButton opens its picker.
    /// This avoids relying on UIControl target ordering relative to the SDK's own Cast action.
    func prepare(_ url: URL, title: String) {
        pending = (url, title)
    }

    func queue(_ url: URL, title: String) {
        pending = (url, title)
        lastError = nil
        didPauseLocalForCurrentCast = false
        statusMessage = "Waiting for Chromecast connection"
        if let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession {
            send(session)
        }
    }

    func clearError() {
        lastError = nil
    }

    private func send(_ session: GCKCastSession) {
        guard let item = pending else {
            statusMessage = "Connected — no media queued"
            return
        }

        let url = item.0
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else {
            fail("This stream does not have a valid HTTP or HTTPS address. Chromecast cannot play this source directly.")
            pending = nil
            return
        }

        // A receiver cannot access the sender's loopback interface. Private LAN addresses remain
        // allowed because the Chromecast may be able to reach them on the same network.
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "0.0.0.0" {
            fail("This stream is hosted on the iPhone itself. Chromecast cannot reach an iPhone localhost URL. A LAN-accessible relay is required for this source.")
            pending = nil
            return
        }

        guard let client = session.remoteMediaClient else {
            fail("The Chromecast session connected, but its media client is unavailable. Disconnect and try again.")
            return
        }

        let contentType = Self.contentType(for: url)
        let metadata = GCKMediaMetadata(metadataType: .movie)
        metadata.setString(item.1, forKey: kGCKMetadataKeyTitle)
        let builder = GCKMediaInformationBuilder(contentURL: url)
        builder.contentType = contentType
        builder.streamType = .buffered
        builder.metadata = metadata

        // loadMedia is asynchronous. Retain its request and delegate to observe receiver rejection.
        let request = client.loadMedia(builder.build())
        activeLoadRequest = request
        request.delegate = self
        observedMediaClient?.remove(self)
        observedMediaClient = client
        client.add(self)

        statusMessage = "Sending media to Chromecast…"
        pending = nil
        GCKCastContext.sharedInstance().presentDefaultExpandedMediaControls()
        print("[StremioCast] LOAD url=\(url.absoluteString) mime=\(contentType) title=\(item.1)")
    }

    private func fail(_ message: String) {
        lastError = message
        statusMessage = "Cast failed"
        print("[StremioCast] ERROR: \(message)")
    }

    private static func contentType(for url: URL) -> String {
        let types: [String: String] = [
            "m3u8": "application/x-mpegURL", "mpd": "application/dash+xml",
            "mp4": "video/mp4", "m4v": "video/mp4", "mkv": "video/x-matroska",
            "webm": "video/webm", "mov": "video/quicktime", "avi": "video/x-msvideo",
            "ts": "video/mp2t", "mp3": "audio/mpeg", "m4a": "audio/mp4",
            "aac": "audio/aac", "wav": "audio/wav", "flac": "audio/flac", "ogg": "audio/ogg"
        ]
        let ext = url.pathExtension.lowercased()
        if let type = types[ext] { return type }

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            for item in components.queryItems ?? [] where
                ["filename", "file", "name"].contains(item.name.lowercased()) {
                if let value = item.value {
                    let queryExtension = URL(fileURLWithPath: value).pathExtension.lowercased()
                    if let type = types[queryExtension] { return type }
                }
            }
        }

        // Best-effort fallback for extensionless progressive-video CDN URLs.
        return "video/mp4"
    }

    // MARK: GCKSessionManagerListener

    func sessionManager(_ manager: GCKSessionManager, didStart session: GCKCastSession) {
        connected = true
        statusMessage = "Connected to \(session.device.friendlyName ?? "Chromecast")"
        send(session)
    }

    func sessionManager(_ manager: GCKSessionManager, didResume session: GCKCastSession, withError error: Error?) {
        connected = error == nil
        if let error {
            fail("The Chromecast session could not resume: \(error.localizedDescription)")
        } else {
            statusMessage = "Reconnected to \(session.device.friendlyName ?? "Chromecast")"
            send(session)
        }
    }

    func sessionManager(_ manager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
        connected = false
        pending = nil
        activeLoadRequest = nil
        observedMediaClient?.remove(self)
        observedMediaClient = nil
        statusMessage = "Disconnected"
        if let error { print("[StremioCast] Session ended: \(error.localizedDescription)") }
    }

    func sessionManager(_ manager: GCKSessionManager, didFailToStart session: GCKCastSession, withError error: Error) {
        connected = false
        fail("Could not start the Chromecast session: \(error.localizedDescription)")
    }

    func sessionManager(_ manager: GCKSessionManager, didSuspend session: GCKCastSession, with reason: GCKConnectionSuspendReason) {
        connected = false
        statusMessage = "Chromecast connection suspended"
    }

    // MARK: GCKRequestDelegate

    func requestDidComplete(_ request: GCKRequest) {
        guard request.requestID == activeLoadRequest?.requestID else { return }
        activeLoadRequest = nil
        statusMessage = "Chromecast accepted the media load request"
        print("[StremioCast] LOAD request completed")
    }

    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        guard request.requestID == activeLoadRequest?.requestID else { return }
        activeLoadRequest = nil
        fail("Chromecast rejected the media load request: \(error.localizedDescription)")
    }

    // MARK: GCKRemoteMediaClientListener

    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        guard let mediaStatus else {
            statusMessage = "Waiting for Chromecast media status"
            return
        }

        switch mediaStatus.playerState {
        case .playing:
            statusMessage = "Playing on Chromecast"
            if !didPauseLocalForCurrentCast {
                didPauseLocalForCurrentCast = true
                NotificationCenter.default.post(name: Notification.Name("StremioCastPlaybackStarted"), object: nil)
            }
        case .paused:
            statusMessage = "Paused on Chromecast"
        case .buffering:
            statusMessage = "Buffering on Chromecast"
        case .idle:
            statusMessage = "Chromecast is idle"
        @unknown default:
            statusMessage = "Chromecast status updated"
        }
    }
}
