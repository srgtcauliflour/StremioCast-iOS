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

    private var pending: (url: URL, title: String, headers: [String: String])?
    private var relay: CastLANRelay?
    private var relayTask: Task<Void, Never>?
    private var preparedRelayURL: URL?
    private var activeLoadRequest: GCKRequest?
    private var activeURL: URL?
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

    }

    /// Keep the selected stream ready before GCKUICastButton opens its picker.
    /// This avoids relying on UIControl target ordering relative to the SDK's own Cast action.
    func prepare(_ url: URL, title: String, headers: [String: String] = [:]) {
        pending = (url: url, title: title, headers: headers)
    }

    func queue(_ url: URL, title: String, headers: [String: String] = [:]) {
        relayTask?.cancel()
        relay?.stop()
        relay = nil
        preparedRelayURL = nil
        pending = (url: url, title: title, headers: headers)
        lastError = nil
        didPauseLocalForCurrentCast = false
        statusMessage = "Waiting for Chromecast connection"
        startRelayIfNeeded()
        if let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession {
            send(session)
        }
    }

    private func startRelayIfNeeded() {
        guard relayTask == nil, relay == nil, let item = pending else { return }
        do {
            let bridge = try CastLANRelay(source: item.url, headers: item.headers)
            relay = bridge
            statusMessage = "Preparing a private Wi-Fi stream bridge…"
            relayTask = Task { [weak self, weak bridge] in
                guard let self, let bridge else { return }
                do {
                    let url = try await bridge.start()
                    guard self.pending?.url == item.url else { bridge.stop(); return }
                    self.preparedRelayURL = url
                    self.relayTask = nil
                    self.statusMessage = "Wi-Fi bridge ready — sending to Chromecast"
                    if let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession {
                        self.send(session)
                    }
                } catch {
                    guard self.pending?.url == item.url else { return }
                    self.relayTask = nil
                    self.relay = nil
                    self.fail((error as? CastLANRelay.RelayError)?.errorDescription ?? "Could not prepare a Wi-Fi stream bridge.")
                    self.pending = nil
                }
            }
        } catch {
            fail((error as? CastLANRelay.RelayError)?.errorDescription ?? "This local stream cannot be shared with Chromecast.")
            pending = nil
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

        let sourceURL = item.url
        guard let url = preparedRelayURL else {
            startRelayIfNeeded()
            statusMessage = "Preparing a private Wi-Fi stream bridge…"
            return
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else {
            fail("This stream does not have a valid HTTP or HTTPS address. Chromecast cannot play this source directly.")
            pending = nil
            return
        }

        guard let client = session.remoteMediaClient else {
            fail("The Chromecast session connected, but its media client is unavailable. Disconnect and try again.")
            return
        }

        let contentType = Self.contentType(for: sourceURL)
        let metadata = GCKMediaMetadata(metadataType: .movie)
        metadata.setString(item.title, forKey: kGCKMetadataKeyTitle)
        let builder = GCKMediaInformationBuilder(contentURL: url)
        builder.contentType = contentType
        builder.streamType = .buffered
        builder.metadata = metadata

        // loadMedia is asynchronous. Retain its request and delegate to observe receiver rejection.
        let request = client.loadMedia(builder.build())
        activeURL = url
        activeLoadRequest = request
        request.delegate = self
        observedMediaClient?.remove(self)
        observedMediaClient = client
        client.add(self)

        statusMessage = "Sending media to Chromecast…"
        pending = nil
        GCKCastContext.sharedInstance().presentDefaultExpandedMediaControls()
        // Never log a full stream URL: query strings can contain debrid/API capability tokens.
        print("[StremioCast] LOAD requested format=\(url.pathExtension.lowercased()) mime=\(contentType)")
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
            fail("The Chromecast session could not resume. Disconnect and try again.")
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
        activeURL = nil
        relayTask?.cancel(); relayTask = nil
        relay?.stop(); relay = nil
        preparedRelayURL = nil
    }

    func sessionManager(_ manager: GCKSessionManager, didFailToStart session: GCKCastSession, withError error: Error) {
        connected = false
        fail("Could not start the Chromecast session. Check that the device is available on the same Wi-Fi network.")
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
        activeURL = nil
        relayTask?.cancel(); relayTask = nil
        relay?.stop(); relay = nil
        preparedRelayURL = nil
        fail("Chromecast rejected the media load request. The receiver may not be able to reach this URL or support its format.")
    }

    // MARK: GCKRemoteMediaClientListener

    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        guard let mediaStatus else {
            statusMessage = "Waiting for Chromecast media status"
            return
        }
        // A resumed/previous Cast session may report unrelated media. Only transfer playback
        // ownership when the receiver confirms the exact URL this player just submitted.
        guard let expectedURL = activeURL,
              mediaStatus.mediaInformation?.contentURL == expectedURL else { return }

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
