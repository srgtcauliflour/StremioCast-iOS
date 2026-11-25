import SwiftUI
import GoogleCast

@MainActor
struct CastButton: UIViewRepresentable {
    let url: URL
    let title: String

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, title: title)
    }

    func makeUIView(context: Context) -> GCKUICastButton {
        let button = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 38, height: 38))
        button.tintColor = .white
        button.addTarget(context.coordinator, action: #selector(Coordinator.queueMedia), for: .touchUpInside)
        button.accessibilityLabel = "Cast to Chromecast"
        CastManager.shared.prepare(url, title: title)
        return button
    }

    func updateUIView(_ view: GCKUICastButton, context: Context) {
        context.coordinator.url = url
        context.coordinator.title = title
        CastManager.shared.prepare(url, title: title)
    }

    @MainActor
    final class Coordinator: NSObject {
        var url: URL
        var title: String

        init(url: URL, title: String) {
            self.url = url
            self.title = title
        }

        @objc func queueMedia() {
            CastManager.shared.queue(url, title: title)
        }
    }
}
