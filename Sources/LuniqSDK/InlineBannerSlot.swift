import SwiftUI
import UIKit

/// SwiftUI view that displays in-app banners from Pulse inline within the
/// host app's layout. Pulls from /v1/sdk/banners (independent of guides).
///
///     VStack {
///         VehicleStatusCard()
///         LuniqBannerSlot(placement: "home")
///     }
public struct LuniqBannerSlot: View {
    public let placement: String

    @StateObject private var model = BannerSlotModel.shared

    public init(placement: String = "home") {
        self.placement = placement
    }

    public var body: some View {
        Group {
            if let active = model.activeBanner(forPlacement: placement) {
                BannerCardView(banner: active, onDismiss: { reason in
                    model.dismiss(active.id, reason: reason)
                })
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.banners.map { $0.id }.joined())
        .onAppear { model.refresh() }
    }
}

/// Banner DTO returned by the server.
public struct PulseBanner: Identifiable, Decodable, Equatable {
    public let id: String
    public let name: String
    public let imageUrl: String
    public let title: String
    public let body: String
    public let ctaLabel: String
    public let linkUrl: String
    public let placement: String
    public let priority: Int
}

final class BannerSlotModel: ObservableObject {
    static let shared = BannerSlotModel()

    @Published var banners: [PulseBanner] = []
    private var dismissedIDs: Set<String> = []
    private var refreshTimer: Timer?
    private let track: (String, [String: Any]) -> Void = { name, props in
        Luniq.shared.track(name, properties: props)
    }

    private init() {
        // Auto-refresh every 5 minutes
        DispatchQueue.main.async {
            self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
                self?.refresh()
            }
        }
        // Refresh on foreground
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        guard let cfg = Luniq.shared.currentConfig() else { return }
        guard let url = URL(string: cfg.endpoint + "/v1/sdk/banners") else { return }
        var req = URLRequest(url: url)
        req.setValue(cfg.apiKey, forHTTPHeaderField: "X-Luniq-Key")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data else { return }
            let decoded = (try? JSONDecoder().decode([PulseBanner].self, from: data)) ?? []
            DispatchQueue.main.async {
                let prev = Set(self.banners.map { $0.id })
                self.banners = decoded
                let now = Set(decoded.map { $0.id })
                // For any newly-shown banner, fire $banner_shown once
                for b in decoded where !prev.contains(b.id) && !self.dismissedIDs.contains(b.id) {
                    if b.placement == self.placementFilter(b) || true {
                        self.track("$banner_shown", ["banner_id": b.id, "banner_name": b.name, "placement": b.placement])
                    }
                }
            }
        }.resume()
    }

    func activeBanner(forPlacement placement: String) -> PulseBanner? {
        banners.first { $0.placement == placement && !dismissedIDs.contains($0.id) }
    }

    func dismiss(_ id: String, reason: String) {
        dismissedIDs.insert(id)
        DispatchQueue.main.async { self.objectWillChange.send() }
        if let b = banners.first(where: { $0.id == id }) {
            track("$banner_\(reason)", ["banner_id": id, "banner_name": b.name, "placement": b.placement])
        }
    }

    private func placementFilter(_ b: PulseBanner) -> String { b.placement }
}

// ---- Inline banner card UI (Genesis-style 1:1 image with overlay) ----
struct BannerCardView: View {
    let banner: PulseBanner
    let onDismiss: (String) -> Void

    var body: some View {
        let imageURL = Luniq.shared.resolveBannerURL(banner.imageUrl)

        ZStack(alignment: .topLeading) {
            // Image background (1:1 square)
            if let url = URL(string: imageURL) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color(.darkGray)
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fill)
                .clipped()
            }

            // Gradient overlay
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.clear, Color.black.opacity(0.7)],
                startPoint: .top, endPoint: .bottom
            )

            // Title + body top-left
            VStack(alignment: .leading, spacing: 4) {
                Text(banner.title).font(.system(size: 20, weight: .semibold)).foregroundColor(.white)
                Text(banner.body).font(.system(size: 14)).foregroundColor(.white.opacity(0.92))
            }
            .padding(16)

            // Close button top-right
            VStack {
                HStack {
                    Spacer()
                    Button(action: { onDismiss("dismissed") }) {
                        Text("✕")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.black.opacity(0.7))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1.5))
                    }
                    .padding(12)
                }
                Spacer()
                // CTA bottom-right — opens link, banner stays until user taps X
                HStack {
                    Spacer()
                    Button(action: {
                        Luniq.shared.track("$banner_clicked", properties: [
                            "banner_id": banner.id,
                            "banner_name": banner.name,
                            "placement": banner.placement,
                            "link_url": banner.linkUrl,
                        ])
                        if !banner.linkUrl.isEmpty, let u = URL(string: banner.linkUrl) {
                            UIApplication.shared.open(u)
                        }
                    }) {
                        Text(banner.ctaLabel)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.55))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(14)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .aspectRatio(1, contentMode: .fit)
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 6)
    }
}
