import SwiftUI

/// 设置页：内核栈/日志/IPv6/geo + 外部控制。改后需重新连接生效。
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var core: CoreStateManager
    @State private var geoUpdating = false
    @State private var geoResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("日志级别", selection: $settings.logLevel) {
                        ForEach(SettingsStore.logLevelOptions, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("启用 IPv6", isOn: $settings.ipv6)
                } header: {
                    Text("内核")
                } footer: {
                    Text("TCP/IP 栈固定 gvisor（iOS 隧道扩展里 system 栈 TCP 走不通）。")
                }

                Section {
                    Toggle("启用 geo 规则", isOn: $settings.geoEnabled)
                    if settings.geoEnabled {
                        Picker("加载器", selection: $settings.geoLoader) {
                            ForEach(SettingsStore.geoLoaderOptions, id: \.self) { Text($0).tag($0) }
                        }
                        Toggle("自动更新", isOn: $settings.geoAutoUpdate)
                        if settings.geoAutoUpdate {
                            Stepper("更新间隔 \(settings.geoUpdateInterval) 小时",
                                    value: $settings.geoUpdateInterval, in: 1...168)
                        }
                        Button {
                            Task { await updateGeo() }
                        } label: {
                            HStack {
                                Label("立即更新 geo", systemImage: "arrow.down.circle")
                                Spacer()
                                if geoUpdating { ProgressView() }
                            }
                        }
                        .disabled(geoUpdating)
                        if let r = geoResult {
                            Text(r).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("geo 规则")
                } footer: {
                    Text("关闭=剔除订阅里的 GEOIP/GEOSITE 规则（省内存）。开启则保留并由内核加载 geo 数据库；"
                       + "扩展内存有限，建议用 memconservative 加载器。geo 库由内核按需下载/更新，不再随包编译。")
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
                    NavigationLink {
                        KernelStatusView()
                    } label: {
                        Label("内核状态", systemImage: "stethoscope")
                    }
                    HStack {
                        Text("内核版本")
                        Spacer()
                        Text(core.coreVersion).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("诊断")
                }

                Section {
                    Text("修改设置后需重新连接 VPN 生效。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .floatingTabBarInset()
            .navigationTitle("设置")
        }
    }

    private func updateGeo() async {
        geoUpdating = true
        geoResult = nil
        defer { geoUpdating = false }
        do {
            try await MihomoAPI.updateGeo()
            geoResult = "更新成功"
        } catch {
            geoResult = "更新失败：\(error.localizedDescription)（需先连接 VPN）"
        }
    }
}

/// 内核状态页：探测 external-controller 是否可达。
private struct KernelStatusView: View {
    @State private var text = "探测中…"

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding()
        }
        .navigationTitle("内核状态")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("刷新") { Task { await reload() } } }
        .task { await reload() }
    }

    private func reload() async {
        text = "探测 \(MihomoAPI.base.absoluteString) …"
        do {
            let version = try await MihomoAPI.version()
            let obj = try await MihomoAPI.proxiesJSON()
            let proxies = (obj["proxies"] as? [String: Any]) ?? [:]
            let groupCount = proxies.values.compactMap { ($0 as? [String: Any])?["all"] }.count
            text = """
            ✅ external-controller 可达
            版本：\(version)
            代理/组总数：\(proxies.count)
            策略组数：\(groupCount)
            """
        } catch {
            text = """
            ❌ 连不上内核 \(MihomoAPI.base.absoluteString)
            \(error.localizedDescription)

            请确认 VPN 已连接后再探测。
            """
        }
    }
}
