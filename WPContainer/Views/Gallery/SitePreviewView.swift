import SwiftUI
import WPContainerKit

/// A site's homepage snapshot (see `SitePreviews`), drawn in grayscale while
/// the site is asleep. Before the first snapshot exists it shows the site's
/// avatar gradient with its initials, so new sites still look like themselves.
struct SitePreviewView: View {
    @Environment(AppViewModel.self) private var vm
    let id: UUID
    let name: String
    let slug: String
    let url: URL
    let status: SiteStatus
    /// A second snapshot to fall back on (an env falls back to its parent site's).
    var fallbackID: UUID? = nil

    var body: some View {
        let image = vm.previews.images[id] ?? fallbackID.flatMap { vm.previews.images[$0] }
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                Theme.avatarGradient(for: slug)
                    .overlay {
                        Text(Theme.initials(for: name))
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                    }
            }
        }
        .clipped()
        .saturation(status.isRunning ? 1 : 0)
        .brightness(status.isRunning ? 0 : -0.02)
        .animation(.easeOut(duration: 0.6), value: status.isRunning)
        .overlay {
            if status.isTransitional { ShimmerOverlay() }
        }
        .task(id: status) {
            vm.previews.refresh(id: id, url: url, isRunning: status.isRunning)
        }
    }
}

/// A light sweep across a preview while its site boots or shuts down.
private struct ShimmerOverlay: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { proxy in
            LinearGradient(colors: [.clear, .white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: proxy.size.width * 0.45)
                .offset(x: phase * proxy.size.width * 1.5)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1 }
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
