import AppKit
import Combine

// 拦截键盘上的亮度键
final class BrightnessKeyHandler: ObservableObject, @unchecked Sendable {
    static let shared = BrightnessKeyHandler()

    // 监听当前激活状态
    @Published private(set) var isActive = false

    // 系统事件监听对象
    private var eventTap: CFMachPort?

    // 把事件监听挂到主线程上
    private var runLoopSource: CFRunLoopSource?

    // 检查是否授权
    private var pollTimer: Timer?

    // 记录上次处理按键时间，用于防抖
    private var lastKeyTime: TimeInterval = 0

    // 最短按键响应间隔，防止 keyDown 连发时触发过于频繁
    private let repeatInterval: TimeInterval = 0.08

    private init() {}

    // MARK: - 公开接口

    // 启动监听
    func start() {
        // 有权限就开始，如果没权限就先请求权限
        AXIsProcessTrusted() ? register() : requestPermissionAndPoll()
    }

    // 停止监听
    func stop() {
        // 停止权限轮询计时器
        pollTimer?.invalidate()
        pollTimer = nil

        // 关闭监听
        eventTap.map {
            CGEvent.tapEnable(tap: $0, enable: false)
        }

        // 从系统移除
        runLoopSource.map {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), $0, .commonModes)
        }

        // 清空引用，释放底层资源
        eventTap = nil
        runLoopSource = nil

        DispatchQueue.main.async {
            self.isActive = false
        }
    }

    // 请求辅助功能权限，并不断检查用户是否同意
    private func requestPermissionAndPoll() {
        // 弹系统权限窗口
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)

        pollTimer?.invalidate()

        // 每秒检查一次
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] timer in
            MainActor.assumeIsolated {
                guard AXIsProcessTrusted() else {
                    return
                }
                
                // 已授权，停止查询
                timer.invalidate()
                self?.pollTimer = nil
                self?.register()
            }
        }
    }

    // 开始拦截键盘事件
    private func register() {
        // 防止重复注册
        guard eventTap == nil else {
            return
        }

        // 把 self 传进底层回调
        let ptr = Unmanaged.passUnretained(self).toOpaque()

        // 监听：普通按键 + 系统按键
        let mask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue) |
        (1 << 14)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,        // 在会话级别拦截
            place: .headInsertEventTap,     // 插在事件队列头部，优先于其他处理器
            options: .defaultTap,           // 可拦截（返回 nil 即可消费事件）
            eventsOfInterest: mask,
            callback: BrightnessKeyHandler.eventCallback,
            userInfo: ptr
        ) else {
            // tapCreate 失败通常是辅助功能权限被撤销
            DispatchQueue.main.async {
                self.isActive = false
            }
            return
        }

        // 挂到主线程
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = src
        DispatchQueue.main.async {
            self.isActive = true
        }
    }

    // 键盘事件回调
    private static let eventCallback: CGEventTapCallBack = {
        _, type, event, userInfo in
        // 如果系统把监听关掉了，就重新启动
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            userInfo.map {
                let me = Unmanaged<BrightnessKeyHandler>.fromOpaque($0).takeUnretainedValue()
                DispatchQueue.main.async {
                    me.eventTap.map {
                        CGEvent.tapEnable(tap: $0, enable: true)
                    }
                }
            }
            // 放行当前事件
            return Unmanaged.passRetained(event)
        }

        guard let ptr = userInfo else {
            return Unmanaged.passRetained(event)
        }

        let me = Unmanaged<BrightnessKeyHandler>.fromOpaque(ptr).takeUnretainedValue()

        // 处理外接键盘
        if type == .keyDown {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            // keycode 144 = 亮度调高
            // keycode 145 = 亮度调低
            if code == 144 || code == 145 {
                DispatchQueue.main.async {
                    me.handleBrightness(up: code == 144)
                }
                // 不让系统处理，否则会调内置屏亮度
                return nil
            }
            return Unmanaged.passRetained(event)
        }

        return Unmanaged.passRetained(event)
    }

    // 执行亮度调节
    private func handleBrightness(up: Bool) {
        let now = Date().timeIntervalSinceReferenceDate
        // 太快就忽略
        guard now - lastKeyTime >= repeatInterval else {
            return
        }

        lastKeyTime = now

        BrightnessManager.shared.adjustBrightness(up: up)
    }
}
