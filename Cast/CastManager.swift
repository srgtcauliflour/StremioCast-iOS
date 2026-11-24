import Foundation
import GoogleCast

@MainActor
final class CastManager: NSObject, ObservableObject, @preconcurrency GCKSessionManagerListener {
    static let shared = CastManager()

    @Published private(set) var connected = false
    private var pending: (URL, String)?
    private var initialized = false

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

    func queue(_ url: URL, title: String) {
        pending = (url, title)
        if let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession {
            send(session)
        }
    }

    private func send(_ session: GCKCastSession) {
        guard let item = pending else { return }
        guard let scheme = item.0.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            pending = nil
            return
        }

        let ext = item.0.pathExtension.lowercased()
        let contentType = [
            "m3u8": "application/x-mpegURL",
            "mpd": "application/dash+xml",
            "mp4": "video/mp4",
            "mkv": "video/x-matroska",
            "webm": "video/webm",
            "mov": "video/quicktime"
        ][ext] ?? "application/octet-stream"

        let metadata = GCKMediaMetadata(metadataType: .movie)
        metadata.setString(item.1, forKey: kGCKMetadataKeyTitle)
        let builder = GCKMediaInformationBuilder(contentURL: item.0)
        builder.contentType = contentType
        builder.streamType = .buffered
        builder.metadata = metadata
        session.remoteMediaClient?.loadMedia(builder.build())
        GCKCastContext.sharedInstance().presentDefaultExpandedMediaControls()
        pending = nil
    }

    func sessionManager(_ manager: GCKSessionManager, didStart session: GCKCastSession) {
        connected = true
        send(session)
    }

    func sessionManager(_ manager: GCKSessionManager, didResume session: GCKCastSession, withError error: Error?) {
        connected = error == nil
        if error == nil { send(session) }
    }

    func sessionManager(_ manager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
        connected = false
        pending = nil
    }

    func sessionManager(_ manager: GCKSessionManager, didFailToStart session: GCKCastSession, withError error: Error) {
        connected = false
    }

    func sessionManager(_ manager: GCKSessionManager, didSuspend session: GCKCastSession, with reason: GCKConnectionSuspendReason) {
        connected = false
    }
}
