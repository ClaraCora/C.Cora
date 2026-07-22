import SwiftUI

/// 设置页：内核栈/日志/IPv6/geo + 外部控制。改后需重新连接生效。
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var geoDatabase: GeoDatabaseManager

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
                        Toggle("Geodata 模式（GeoIP.dat）", isOn: $settings.geodataMode)
                        Toggle("忽略 GEO 取反规则", isOn: $settings.ignoreGeoNegation)
                        if settings.geodataMode {
                            GeoURLField(title: "备用 GeoIP.dat 地址", text: $settings.geoIPDatURL)
                        } else {
                            GeoURLField(title: "备用 MMDB 地址", text: $settings.geoMMDBURL)
                        }
                        GeoURLField(title: "备用 GeoSite.dat 地址", text: $settings.geoSiteURL)
                        Toggle("自动更新", isOn: $settings.geoAutoUpdate)
                        if settings.geoAutoUpdate {
                            Stepper("更新间隔 \(settings.geoUpdateInterval) 小时",
                                    value: $settings.geoUpdateInterval, in: 1...168)
                        }
                        Button {
                            Task { await updateGeo() }
                        } label: {
                            HStack {
                                Label("下载 / 更新 GEO 与 ASN 数据", systemImage: "arrow.down.circle")
                                Spacer()
                                if geoDatabase.isUpdating { ProgressView() }
                            }
                        }
                        .disabled(geoDatabase.isUpdating)
                        if let date = geoDatabase.lastUpdatedAt(geodataMode: settings.geodataMode) {
                            HStack {
                                Text("本地数据")
                                Spacer()
                                if let size = geoDatabase.installedSize(geodataMode: settings.geodataMode) {
                                    Text("\(ByteFormat.size(size)) · ")
                                }
                                Text(date, style: .relative)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        if let result = geoDatabase.statusText {
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(geoDatabase.statusIsError ? Color.red : Color.secondary)
                        }
                    }
                } header: {
                    Text("GEO 与 ASN")
                } footer: {
                    Text("关闭 GEO=剔除订阅里的 GEOIP/GEOSITE 规则。Geodata 模式关闭时使用 MMDB，开启时使用 GeoIP.dat；"
                       + "“忽略 GEO 取反规则”可单独控制 geolocation-!cn / NOT(GEOIP) 等规则。"
                       + "主 App 优先读取当前配置的 geox-url 下载数据库，设置中的地址仅在配置缺少对应地址时使用。"
                       + "IP-ASN/SRC-IP-ASN 规则会保留；ASN 优先使用配置中的 geox-url.asn，缺少时使用内置备用地址。"
                       + "更新后需重新连接。")
                }

                Section {
                    HStack {
                        Text("User-Agent")
                        Spacer()
                        TextField("clash-meta", text: $settings.subscriptionUA)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                } header: {
                    Text("订阅")
                } footer: {
                    Text("拉取订阅时发送的 User-Agent。机场常按 UA 返回不同格式（clash / clash-meta / mihomo / stash 等），默认 clash-meta。改后重新拉取订阅生效。")
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
                    HStack {
                        Text("混合代理端口")
                        Spacer()
                        TextField("0=不开", value: $settings.mixedPort, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                } header: {
                    Text("代理端口")
                } footer: {
                    Text("开启后内核在本机回环监听 HTTP+SOCKS 混合代理端口（0=不开）。")
                }

                Section {
                    Toggle("接管所有网络", isOn: $settings.includeAllNetworks)
                    Toggle("强制路由", isOn: $settings.enforceRoutes)
                    Toggle("排除蜂窝服务", isOn: $settings.excludeCellularServices)
                    Toggle("排除 APNs 推送", isOn: $settings.excludeAPNs)
                    Toggle("排除设备间通信", isOn: $settings.excludeDeviceCommunication)
                } header: {
                    Text("隧道路由")
                } footer: {
                    Text("系统隧道(NETunnelProvider)开关。「接管所有网络」会连系统默认排除的流量也走隧道；"
                       + "排除项默认开启（蜂窝服务/推送/隔空投送等不走代理，避免异常）。改后需重连。")
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
            .navigationTitle("设置")
        }
    }

    private func updateGeo() async {
        do {
            try await geoDatabase.updateManually()
        } catch {
            // 具体错误由 GeoDatabaseManager 发布到设置页。
        }
    }
}

private struct GeoURLField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: $text, axis: .vertical)
                .font(.footnote.monospaced())
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(1...3)
        }
        .padding(.vertical, 2)
    }
}

/// 内核状态页：同时探测 external-controller API 与 sendProviderMessage IPC，并排对比可用性。
/// 用于在自有账号 + App Group 就绪后，验证 IPC 是否已恢复可靠（决定能否把控制从 HTTP 切到 IPC）。
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
        text = "探测中…"
        var out = "目标：\(MihomoAPI.base.absoluteString)\n（请在 VPN 已连接时探测）\n"

        // 1) external-controller API（loopback HTTP）
        out += "\n【external-controller API】\n"
        do {
            let version = try await MihomoAPI.version()
            let obj = try await MihomoAPI.proxiesJSON()
            let proxies = (obj["proxies"] as? [String: Any]) ?? [:]
            let groupCount = proxies.values.compactMap { ($0 as? [String: Any])?["all"] }.count
            out += "✅ 可达，版本 \(version)，代理/组 \(proxies.count)，策略组 \(groupCount)\n"
        } catch {
            out += "❌ \(error.localizedDescription)\n"
        }

        // 2) sendProviderMessage IPC（App↔NE 官方通道）
        out += "\n【sendProviderMessage IPC】\n"
        let ipc = await CoreStateManager.shared.sendMessage(["cmd": "queryProxies"])
        switch ipc {
        case .ok(let data):
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let proxies = (obj?["proxies"] as? [String: Any]) ?? [:]
            let groupCount = proxies.values.compactMap { ($0 as? [String: Any])?["all"] }.count
            out += "✅ 可用，queryProxies 回 \(data.count) 字节，策略组 \(groupCount)\n"
        case .failure(let reason):
            out += "❌ \(reason)\n"
        }

        text = out
    }
}
