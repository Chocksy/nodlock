import SwiftUI

// Drives the 2-second poll of /status and /shot.png. Published state feeds the view.
@MainActor
final class UnlockViewModel: ObservableObject {
    @Published var status: SentinelStatus?
    @Published var shot: UIImage?
    @Published var online = false
    @Published var logins: [LoginRequest] = []

    private(set) var client: (any PanelClient)?
    private var pollTask: Task<Void, Never>?

    func attach(_ client: any PanelClient) {
        self.client = client
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in await self?.loop() }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func loop() async {
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    func refresh() async {
        await tick()
    }

    private func tick() async {
        guard let client else { return }
        do {
            let s = try await client.status()
            status = s
            online = s.ok
            logins = s.logins ?? []
            if s.hasDialog {
                if let data = try await client.screenshot(), let img = UIImage(data: data) {
                    shot = img
                }
            } else {
                shot = nil
            }
        } catch {
            online = false
        }
    }
}
