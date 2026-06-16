import SwiftUI

/// 设置页：内核栈/日志/IPv6/geo + 外部控制。改后需重新连接生效。
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("TUN 栈", selection: $settings.stack) {
                        ForEach(SettingsStore.stackOptions, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("日志级别", selection: $settings.logLevel) {
                        ForEach(SettingsStore.logLevelOptions, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("启用 IPv6", isOn: $settings.ipv6)
                } header: {
                    Text("内核")
                } footer: {
                    Text("iOS 隧道扩展里 system 栈 TCP 常走不通，建议保持 gvisor。")
                }

                Section {
                    Toggle("剔除 geo 规则", isOn: $settings.stripGeo)
                } header: {
                    Text("规则")
                } footer: {
                    Text("订阅里的 GEOIP/GEOSITE 规则需加载 geo 数据库，扩展内存有限易崩。默认剔除。")
                }

                Section {
                    HStack {
                        Text("端口")
                        Spacer()
                        TextField("9090", value: $settings.controllerPort, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    HStack {
                        Text("密钥")
                        Spacer()
                        TextField("可空", text: $settings.controllerSecret)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    Toggle("允许局域网访问", isOn: $settings.allowLan)
                } header: {
                    Text("外部控制")
                } footer: {
                    Text("供主 App 访问内核 API。一般保持默认 9090、无密钥、仅本机。")
                }

                Section {
                    Text("修改设置后需重新连接 VPN 生效。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
        }
    }
}
