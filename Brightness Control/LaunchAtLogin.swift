import ServiceManagement
import Combine

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published var isEnabled: Bool = false

    private init() {
        // 是初始化状态
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    // 切换开机启动状态
    func toggle() {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
                isEnabled = false
            } else {
                try SMAppService.mainApp.register()
                isEnabled = true
            }
        } catch {
            isEnabled = SMAppService.mainApp.status == .enabled
        }
    }
}
