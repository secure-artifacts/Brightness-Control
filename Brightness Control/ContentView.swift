import SwiftUI
import ServiceManagement

struct MenuBarView: View {
    // 监听显示器数据变化
    @ObservedObject private var manager = BrightnessManager.shared

    // 监听媒体键拦截器状态
    @ObservedObject private var interceptor = BrightnessKeyHandler.shared

    // 监听开机启动状态
    @ObservedObject private var launcher = LaunchAtLoginManager.shared

    var body: some View {
        VStack(spacing: 12) {

            // 没有外接显示器，显示提示文字
            if manager.displays.isEmpty {
                Text("noDisplays")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                // 遍历所有检测到的显示器，为每台显示器渲染一个亮度调节行
                ForEach(manager.displays) { d in
                    HStack(spacing: 8) {

                        // 左侧图标代表低亮度端
                        Image(systemName: "sun.min")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)

                        // 亮度滑动条
                        // Binding 使滑条与 BrightnessManager 中的数据双向绑定
                        //   get: 读取该显示器当前亮度值（转为 Double 供 Slider 使用）
                        //   set: 用户拖动时，将新值写回 BrightnessManager（截断为 Int）
                        Slider(
                            value: Binding(
                                get: {
                                    Double(d.brightness)
                                },
                                set: {
                                    manager.setBrightness(Int($0), for: d.id)
                                }
                            ),
                            // 亮度范围：0% ~ 100%
                            in: 0...100
                        )

                        // 右侧图标代表高亮度端
                        Image(systemName: "sun.max.fill")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)

                        // 数字亮度百分比显示
                        Text("\(d.brightness)%")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            }

            Divider()

            HStack {
                // 根据辅助功能授权状态显示不同控件
                if !interceptor.isActive {
                    // 未授权状态
                    Button {
                        // 调用 macOS 辅助功能授权 API
                        AXIsProcessTrustedWithOptions(
                            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                        )
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 7, height: 7)
                            Text("accessibility")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)  // 去除系统默认按钮样式，保持视觉简洁

                } else {
                    // 授权后显示开机启动开关
                    Toggle(isOn: Binding(
                        get: {
                            launcher.isEnabled
                        },
                        set: {
                            _ in launcher.toggle()
                        }
                    )) {
                        Text("launchAtLogin")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                Spacer()

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Text("quit")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 260)
        .onAppear {
            launcher.isEnabled = SMAppService.mainApp.status == .enabled
        }
    }
}
