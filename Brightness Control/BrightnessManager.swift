import AppKit
import Combine
import IOKit

struct ExternalDisplay: Identifiable {
    // 分配的显示器唯一 ID
    let id: CGDirectDisplayID
    // 当前亮度值，范围 0~100，默认 50%
    var brightness: Int = 50
}

// 用于动态查找系统私有函数
private nonisolated(unsafe) let kRTLD_DEFAULT = UnsafeMutableRawPointer(bitPattern: -2)

// 负责向显示器发送亮度控制命令
private final class DDCService: @unchecked Sendable {
    static let shared = DDCService()

    // 创建显示器控制对象
    private let avCreate: (@convention(c) (CFAllocator?, io_service_t) -> Unmanaged<AnyObject>?)?

    // 向显示器发送数据
    private let avWriteI2C: (@convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn)?

    private init() {
        // 动态加载系统私有 API
        avCreate = unsafeBitCast(
            dlsym(kRTLD_DEFAULT, "IOAVServiceCreateWithService"),
            to: (@convention(c) (CFAllocator?, io_service_t) -> Unmanaged<AnyObject>?)?.self
        )
        avWriteI2C = unsafeBitCast(
            dlsym(kRTLD_DEFAULT, "IOAVServiceWriteI2C"),
            to: (@convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn)?.self
        )
    }

    // 设置某个显示器的亮度
    func writeBrightness(_ value: UInt16, to id: CGDirectDisplayID) {
        // 优先使用 Apple Silicon 的方法
        if let fn = avWriteI2C, let svc = avService(for: id) {
            // 构造设置亮度的命令数据
            var data: [UInt8] = [
                0x84, // 数据长度标记
                0x03, // 命令类型
                0x10, // 亮度
                UInt8(value >> 8),
                UInt8(value & 0xFF)
            ]

            // 添加校验和
            data.append(data.reduce(UInt8(0x6E ^ 0x51), ^))

            // 发送给显示器
            _ = data.withUnsafeMutableBufferPointer {
                fn(svc as CFTypeRef, 0x37, 0x51, $0.baseAddress!, UInt32($0.count))
            }
            return
        }
        // Apple Silicon 失败时，使用 Intel Mac 路径
        writeIntel(value, to: id)
    }

    // 找到对应显示器的底层控制对象
    private func avService(for id: CGDirectDisplayID) -> AnyObject? {
        var iter: io_iterator_t = 0
        // 查找所有 DCPAVServiceProxy 服务节点
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("DCPAVServiceProxy"),
            &iter
        ) == KERN_SUCCESS else {
            return nil
        }
        defer {
            // 确保迭代器最终被释放，防止 IOKit 资源泄漏
            IOObjectRelease(iter)
        }

        var fallback: AnyObject?
        while case let svc = IOIteratorNext(iter), svc != IO_OBJECT_NULL {
            defer {
                // 每个服务对象用完后立即释放
                IOObjectRelease(svc)
            }
            guard let obj = avCreate?(kCFAllocatorDefault, svc)?.takeRetainedValue() else {
                continue
            }

            // 判断是不是外接显示器
            if let loc = IORegistryEntryCreateCFProperty(
                svc, "Location" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String,
               loc.contains("External") || loc.contains("DP") || loc.contains("HDMI") {
                // 找到明确匹配的外接端口，直接返回
                return obj
            }
            // 保存第一个找到的节点作为兜底
            if fallback == nil {
                fallback = obj
            }
        }
        // 没有精确匹配时返回兜底节点
        return fallback
    }

    // Intel Mac 使用的旧方法
    private func writeIntel(_ value: UInt16, to id: CGDirectDisplayID) {
        var iter: io_iterator_t = 0
        
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iter
        ) == KERN_SUCCESS else {
            return
        }
        
        defer {
            IOObjectRelease(iter)
        }

        while case let s = IOIteratorNext(iter), s != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(s)
            }

            // 获取显示器信息
            let info = IODisplayCreateInfoDictionary(
                s, IOOptionBits(kIODisplayOnlyPreferredName)
            ).takeRetainedValue() as NSDictionary

            // 找到目标显示器
            guard info[kDisplayVendorID] as? UInt32 == CGDisplayVendorNumber(id),
                  info[kDisplayProductID] as? UInt32 == CGDisplayModelNumber(id) else {
                continue
            }

            /// 从 IODisplayConnect 向上层遍历，获取其父节点 framebuffer 服务
            var fb: io_service_t = 0
            guard IORegistryEntryGetParentEntry(s, kIOServicePlane, &fb) == KERN_SUCCESS else {
                continue
            }
            defer {
                IOObjectRelease(fb)
            }

            // 构造 IOI2CRequest 结构体
            var req = IOI2CRequest()
            req.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
            // DDC 标准：显示器端 I²C 地址为 0x6E
            req.sendAddress = 0x6E

            // 构造亮度命令
            var data: [UInt8] = [0x51, 0x84, 0x03, 0x10, UInt8(value >> 8), UInt8(value & 0xFF)]
            data.append(data.reduce(UInt8(0x6E), ^))  // 追加校验和

            req.sendBytes = UInt32(data.count)

            data.withUnsafeMutableBufferPointer {
                buf in
                // IOI2CRequest 需要传入缓冲区的内存地址
                req.sendBuffer = vm_address_t(bitPattern: buf.baseAddress)

                // 获取 framebuffer 上编号为 0 的 I²C 接口
                var iface: io_service_t = 0
                guard IOFBCopyI2CInterfaceForBus(fb, 0, &iface) == KERN_SUCCESS else {
                    return
                }
                defer {
                    IOObjectRelease(iface)
                }

                // 打开 I²C 接口连接，获取连接句柄
                var conn: IOI2CConnectRef?
                guard IOI2CInterfaceOpen(iface, 0, &conn) == KERN_SUCCESS, let c = conn else {
                    return
                }

                // 发送 DDC 请求，最后关闭连接释放资源
                _ = IOI2CSendRequest(c, 0, &req)
                IOI2CInterfaceClose(c, 0)
            }
        }
    }
}

// 管理所有显示器 + 控制亮度
final class BrightnessManager: ObservableObject, @unchecked Sendable {
    static let shared = BrightnessManager()

    // 当前所有外接显示器
    @Published private(set) var displays: [ExternalDisplay] = []

    // 后台队列，避免阻塞 UI
    private let ddcQueue = DispatchQueue(label: "com.Raz1ner.Brightness-Control", qos: .userInteractive)

    // 目标亮度值
    private var targetBrightness: Double = -1
    // 当前动画值
    private var currentBrightness: Double = -1

    // 驱动亮度动画的计时器，每帧触发一次插值计算
    private var brightnessTimer: Timer?

    // 按 3 帧间隔节流 DDC 写入，降低 I²C 总线压力
    private var frameCount = 0

    // 每次按键调节的步进量（5%）
    private let step: Double = 5.0
    // 动画帧率：60 FPS
    private let animInterval: TimeInterval = 1.0 / 60.0
    // 指数平滑系数
    private let smooth: Double = 0.18

    private init() {}

    // 扫描外接显示器
    func refresh() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        // 将所有活跃显示器 ID 写入 ids 数组
        CGGetActiveDisplayList(8, &ids, &count)
        // 过滤掉内置屏幕，例如 MacBook 屏幕
        displays = ids.prefix(Int(count))
            .filter {
                CGDisplayIsBuiltin($0) == 0
            }
            .map {
                ExternalDisplay(id: $0)
            }
    }

    // UI 直接设置亮度
    func setBrightness(_ value: Int, for id: CGDirectDisplayID) {
        applyToAll(value)
    }

    // 按键调亮度
    func adjustBrightness(up: Bool) {
        if currentBrightness < 0 {
            currentBrightness = Double(displays.first?.brightness ?? 50)
        }
        if targetBrightness < 0 {
            targetBrightness = currentBrightness
        }

        // 更新目标值
        targetBrightness = (targetBrightness + (up ? step : -step)).clamped(to: 0...100)

        // 如果动画已经在跑，就不用重新开
        guard brightnessTimer == nil else {
            return
        }
        
        frameCount = 0

        // 以 60 FPS 启动动画计时器
        brightnessTimer = Timer.scheduledTimer(withTimeInterval: animInterval, repeats: true) {
            [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }

                let diff = self.targetBrightness - self.currentBrightness

                if abs(diff) < 0.5 {
                    // 到达目标
                    self.currentBrightness = self.targetBrightness
                    self.applyToAll(Int(self.currentBrightness.rounded()))
                    timer.invalidate()
                    self.brightnessTimer = nil
                    self.frameCount = 0
                } else {
                    // 平滑过渡
                    self.currentBrightness += diff * self.smooth
                    self.frameCount += 1

                    // 每3帧才真正写一次
                    if self.frameCount % 3 == 0 {
                        self.applyToAll(Int(self.currentBrightness.rounded()))
                    }
                }
            }
        }
    }

    // 把亮度应用到所有显示器
    private func applyToAll(_ value: Int) {
        let v = value.clamped(to: 0...100)

        // 写硬件
        ddcQueue.async {
            [weak self] in
            self?.displays.forEach {
                DDCService.shared.writeBrightness(UInt16(v), to: $0.id)
            }
        }

        // 更新 UI
        DispatchQueue.main.async {
            [weak self] in
            self?.displays = self?.displays.map {
                var d = $0
                d.brightness = v
                return d
            } ?? []
        }
    }
}

// 限制数值范围
private extension Comparable {
    // 将值限制在给定闭区间内
    func clamped(to r: ClosedRange<Self>) -> Self {
        min(max(self, r.lowerBound), r.upperBound)
    }
}
