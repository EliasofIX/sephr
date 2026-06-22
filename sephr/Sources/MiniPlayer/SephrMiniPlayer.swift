import SwiftUI
import AppKit
import Combine
import CAL

enum SephrMiniPlayer {
    private static var panel: NSPanel?

    static func show() {
        if let p = panel {
            p.makeKeyAndOrderFront(nil)
            return
        }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: MiniPlayerView())
        if let screen = NSScreen.main {
            p.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.maxX - 340,
                y: screen.visibleFrame.minY + 20))
        }
        p.orderFront(nil)
        panel = p
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

@MainActor
final class MiniPlayerViewModel: ObservableObject {
    @Published var session: CALMediaSession?

    var isPlaying: Bool {
        session?.playbackState == .playing
    }

    init() {
        CALMedia.sharedInstance().onMediaChange = { [weak self] s in
            DispatchQueue.main.async { self?.session = s }
        }
    }
}

struct MiniPlayerView: View {
    @StateObject private var model = MiniPlayerViewModel()

    var body: some View {
        HStack(spacing: 12) {
            if let art = model.session?.artwork {
                Image(nsImage: art).resizable()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: DC.Radius.standard))
            } else {
                RoundedRectangle(cornerRadius: DC.Radius.standard)
                    .fill(.white.opacity(0.1))
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "music.note")
                        .foregroundStyle(.secondary))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.session?.title ?? "Nothing Playing")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(model.session?.artist ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 8) {
                Button { CALMedia.sharedInstance().previousTrack() } label: {
                    Image(systemName: "backward.fill")
                }
                Button {
                    if model.isPlaying { CALMedia.sharedInstance().pause() }
                    else { CALMedia.sharedInstance().play() }
                } label: {
                    Image(systemName: model.isPlaying ?
                          "pause.fill" : "play.fill")
                        .font(.system(size: 16))
                }
                Button { CALMedia.sharedInstance().nextTrack() } label: {
                    Image(systemName: "forward.fill")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .frame(height: 68)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DC.Radius.standard,
                                    style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DC.Radius.standard,
                                  style: .continuous)
            .stroke(.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 4)
    }
}
