import SwiftUI
import GoogleCast

@MainActor
struct CastButton: UIViewRepresentable {
    let url: URL
    let title: String
    var headers: [String: String]? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, title: title, headers: headers ?? [:])
    }

    func makeUIView(context: Context) -> GCKUICastButton {
        let button = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 38, height: 38))
        button.tintColor = .white
        button.addTarget(context.coordinator, action: #selector(Coordinator.queueMedia), for: .touchUpInside)
        button.accessibilityLabel = "Cast to Chromecast"
        CastManager.shared.prepare(url, title: title, headers: headers ?? [:])
        return button
    }

    func updateUIView(_ view: GCKUICastButton, context: Context) {
        context.coordinator.url = url
        context.coordinator.title = title
        context.coordinator.headers = headers ?? [:]
        CastManager.shared.prepare(url, title: title, headers: headers ?? [:])
    }

    @MainActor
    final class Coordinator: NSObject {
        var url: URL
        var title: String
        var headers: [String: String]

        init(url: URL, title: String, headers: [String: String]) {
            self.url = url
            self.title = title
            self.headers = headers
        }

        @objc func queueMedia() {
            CastManager.shared.queue(url, title: title, headers: headers)
        }
    }
}
