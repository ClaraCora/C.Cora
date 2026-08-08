import SwiftUI

/// 设置页：内核栈/日志/IPv6/geo + 外部控制。改后需重新连接生效。
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var geoDatabase: GeoDatabaseManager
    @State private var installedGeoInfo: GeoInstalledInfo?

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
                    NavigationLink {
                        ConfigOverrideSettingsView()
                    } label: {
                        Text("覆写设置")
                    }
                } header: {
                    Text("覆写")
                } footer: {
                    Text("配置文件可单独选择是否应用这套固定设置。")
                }

                GeoSettingsSection(installedInfo: installedGeoInfo)

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
                    Toggle("启用外部控制", isOn: $settings.externalControllerEnabled)
                    HStack {
                        Text("端口")
                        Spacer()
                        TextField("9090", value: $settings.controllerPort,
                                  format: IntegerFormatStyle<Int>.number.grouping(.never))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    .disabled(!settings.externalControllerEnabled)
                    HStack {
                        Text("密钥")
                        Spacer()
                        TextField("可空", text: $settings.controllerSecret)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    .disabled(!settings.externalControllerEnabled)
                    Toggle("允许局域网访问", isOn: $settings.allowLan)
                        .disabled(!settings.externalControllerEnabled || settings.controllerSecret
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("外部控制")
                } footer: {
                    Text("供第三方 Dashboard 使用；主 App 自身走系统 IPC。局域网访问必须设置密钥，修改后重连生效。")
                }

                Section {
                    HStack {
                        Text("混合代理端口")
                        Spacer()
                        TextField("0=不开", value: $settings.mixedPort,
                                  format: IntegerFormatStyle<Int>.number.grouping(.never))
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
                    if #available(iOS 17.4, *) {
                        Toggle("排除设备间通信", isOn: $settings.excludeDeviceCommunication)
                    }
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
            .task(id: geoInfoRefreshID) {
                guard settings.geoEnabled else {
                    installedGeoInfo = nil
                    return
                }
                installedGeoInfo = nil
                let info = await geoDatabase.installedInfo(geodataMode: settings.geodataMode)
                guard !Task.isCancelled else { return }
                installedGeoInfo = info
            }
        }
    }

    private var geoInfoRefreshID: String {
        "\(settings.geoEnabled)-\(settings.geodataMode)-\(geoDatabase.revision)"
    }
}

private struct GeoSettingsSection: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var geoDatabase: GeoDatabaseManager
    let installedInfo: GeoInstalledInfo?

    var body: some View {
        Section {
            Toggle("启用 geo 规则", isOn: $settings.geoEnabled)
            if settings.geoEnabled {
                if AppGroup.containerURL == nil {
                    Label("当前签名没有可用的 App Group，连接时会自动忽略 GEO/ASN 规则。",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
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
                .disabled(geoDatabase.isUpdating || AppGroup.containerURL == nil)
                if let installedInfo {
                    HStack {
                        Text("本地数据")
                        Spacer()
                        Text("\(ByteFormat.size(installedInfo.size)) · "
                           + installedInfo.updatedAt.formatted(date: .abbreviated,
                                                               time: .shortened))
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
            Text("关闭 GEO=剔除订阅里的 GEOIP/GEOSITE/IP-ASN 规则。Geodata 模式关闭时使用 MMDB，开启时使用 GeoIP.dat；"
               + "“忽略 GEO 取反规则”可单独控制 geolocation-!cn / NOT(GEOIP) 等规则。"
               + "主 App 优先读取当前配置的 geox-url 下载数据库，设置中的地址仅在配置缺少对应地址时使用。"
               + "ASN 优先使用配置中的 geox-url.asn，缺少时使用内置备用地址。"
               + "更新后需重新连接。")
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

/// 内核状态页：验证主控制 IPC，并在用户显式启用时附带探测 external-controller。
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

        // 1) optional external-controller API（loopback HTTP）
        out += "\n【external-controller API】\n"
        if SettingsStore.shared.externalControllerEnabled {
            do {
                let version = try await MihomoAPI.version()
                let obj = try await MihomoAPI.proxiesJSON()
                let proxies = (obj["proxies"] as? [String: Any]) ?? [:]
                let groupCount = proxies.values.compactMap { ($0 as? [String: Any])?["all"] }.count
                out += "✅ 可达，版本 \(version)，代理/组 \(proxies.count)，策略组 \(groupCount)\n"
            } catch {
                out += "❌ \(error.localizedDescription)\n"
            }
        } else {
            out += "未启用（主 App 不依赖此接口）\n"
        }

        // 2) sendProviderMessage IPC（App↔NE 官方通道）
        out += "\n【sendProviderMessage IPC】\n"
        let hello = await CoreStateManager.shared.sendMessage(["cmd": "hello"])
        if case .ok(let data) = hello,
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            out += "协议 v\((object["protocolVersion"] as? NSNumber)?.intValue ?? 0)，"
                + "内核 \(object["coreVersion"] as? String ?? "?")\n"
        }
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
