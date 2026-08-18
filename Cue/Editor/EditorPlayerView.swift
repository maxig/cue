import SwiftUI
import AVKit

/// AppKit `AVPlayerView` wrapper taking a player directly, so the editor can
/// swap the item's video composition underneath it.
///
/// Deliberately not SwiftUI's `VideoPlayer`, which crashes during generic
/// metadata instantiation on this toolchain — same reason the Library wraps it.
struct EditorPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}
