import SwiftUI

/// 设置页：按功能类型组织设置，详细说明通过名称后的信息按钮按需查看。
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var core: CoreStateManager
    var body: some View {
        NavigationStack {
            ZStack {
                AppAmbientBackground()
                Form {
                    Section {
                        NavigationLink {
                            SubscriptionsView()
                        } label: {
                            Label("配置", systemImage: "doc.text")
                        }
                        if !core.configNotices.isEmpty {
                            SettingsInfoRow(
                                title: "配置提示",
                                systemImage: "exclamationmark.triangle.fill",
                                tint: .orange,
                                message: core.configNotices.joined(separator: "\n\n"))
                        }
                    }
                    .listRowBackground(AppListRowBackground())

                    Section {
                        SettingsNavigationRow(
                            title: "内核设置",
                            systemImage: "gearshape.2",
                            message: "管理内核日志、IPv6、配置覆盖和诊断信息。",
                            destination: KernelSettingsView())
                        SettingsNavigationRow(
                            title: "GEO 与 ASN",
                            systemImage: "globe.americas",
                            message: "管理 GEO/ASN 规则数据和更新方式。",
                            destination: GeoSettingsView())
                        SettingsNavigationRow(
                            title: "隧道路由",
                            systemImage: "arrow.triangle.branch",
                            message: "管理 VPN 接管范围和系统服务排除项。",
                            destination: TunnelRouteSettingsView())
                        SettingsNavigationRow(
                            title: "延迟测试",
                            systemImage: "speedometer",
                            message: "管理策略组与单节点测速的统一地址和超时。",
                            destination: DelayTestSettingsView())
                    }
                    .listRowBackground(AppListRowBackground())

                    Section {
                        HStack {
                            Label {
                                InfoLabel(title: "订阅 UA", message: "拉取订阅时发送的 User-Agent。不同机场可能根据 UA 返回不同配置格式，修改后重新拉取订阅生效。")
                            } icon: {
                                Image(systemName: "network.badge.shield.half.filled")
                            }
                            Spacer()
                            TextField("clash-meta", text: $settings.subscriptionUA)
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .frame(maxWidth: 180)
                        }
                    }
                    .listRowBackground(AppListRowBackground())

                    Section {
                        HStack {
                            Label {
                                InfoLabel(title: "混合代理端口", message: "在本机回环监听 HTTP+SOCKS 混合代理端口，设为 0 表示关闭。")
                            } icon: {
                                Image(systemName: "point.3.connected.trianglepath.dotted")
                            }
                            Spacer()
                            TextField("0=不开", value: $settings.mixedPort,
                                      format: IntegerFormatStyle<Int>.number.grouping(.never))
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                        }
                    }
                    .listRowBackground(AppListRowBackground())

                    Section {
                        HStack {
                            Label("App 版本", systemImage: "info.circle")
                            Spacer()
                            Text(appVersion)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .listRowBackground(AppListRowBackground())
                }
                .scrollContentBackground(.hidden)
                .background(Color.clear)
            }
            .navigationTitle("设置")
            .task { await core.refreshStatus() }
        }
    }

    private var appVersion: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}

private struct DelayTestSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                InfoToggleRow(
                    title: "统一测试地址",
                    message: "让 mihomo 的策略组使用统一的测速地址。关闭时保留配置内各策略组自带的测速地址；主 App 手动测速仍使用下方地址。",
                    isOn: $settings.unifiedDelay)

                HStack {
                    InfoLabel(title: "测速超时", message: "单个节点最长等待时间。范围为 1 到 60 秒，默认 5 秒。")
                    Spacer()
                    TextField("5", value: $settings.delayTestTimeout,
                              format: IntegerFormatStyle<Int>.number.grouping(.never))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Text("秒")
                        .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(AppListRowBackground())

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    InfoLabel(title: "测速地址", message: "策略组与单节点测速都会请求此 HTTP 或 HTTPS 地址。留空时使用 Google generate_204；修改后立即用于下一次测速。")
                    TextField(SettingsStore.defaultDelayTestURL,
                              text: $settings.delayTestURL,
                              axis: .vertical)
                        .font(.footnote.monospaced())
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...3)
                }
                .padding(.vertical, 2)
            }
            .listRowBackground(AppListRowBackground())
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .navigationTitle("延迟测试")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct KernelSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var core: CoreStateManager
    @State private var isKernelAvailable = false
    @State private var isCheckingKernel = true

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.logLevel) {
                    ForEach(SettingsStore.logLevelOptions, id: \.self) { Text($0).tag($0) }
                } label: {
                    InfoLabel(title: "日志级别", message: "控制内核输出的日志详细程度。修改后重新连接 VPN 生效。")
                }
                InfoToggleRow(title: "启用 IPv6", message: "允许隧道处理 IPv6 流量。部分网络或配置不支持 IPv6 时可以关闭。", isOn: $settings.ipv6)
                NavigationLink {
                    ConfigOverrideSettingsView()
                } label: {
                    InfoLabel(title: "覆盖设置", message: "为配置文件选择是否应用 Cora 的固定 DNS、嗅探和 TUN 设置。")
                }
            }
            .listRowBackground(AppListRowBackground())

            Section {
                NavigationLink {
                    KernelStatusView()
                } label: {
                    HStack {
                        Text("内核状态")
                        Spacer()
                        if isCheckingKernel {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(isKernelAvailable ? "✅" : "❌")
                                .accessibilityLabel(isKernelAvailable ? "内核可用" : "内核不可用")
                        }
                    }
                }
                HStack {
                    InfoLabel(title: "内核版本", message: "当前由隧道扩展运行的 mihomo 内核版本。")
                    Spacer()
                    Text(core.coreVersion)
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
            }
            .listRowBackground(AppListRowBackground())
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .navigationTitle("内核设置")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: core.status.rawValue) { await refreshKernelAvailability() }
    }

    private func refreshKernelAvailability() async {
        guard core.status == .connected || core.status == .reasserting else {
            isKernelAvailable = false
            isCheckingKernel = false
            return
        }
        isCheckingKernel = true
        let result = await CoreStateManager.shared.sendMessage(["cmd": "hello"])
        guard !Task.isCancelled else { return }
        if case .ok = result {
            isKernelAvailable = true
        } else {
            isKernelAvailable = false
        }
        isCheckingKernel = false
    }
}

private struct GeoSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var geoDatabase: GeoDatabaseManager
    @State private var installedInfo: GeoInstalledInfo?

    var body: some View {
        Form {
            GeoSettingsContent(installedInfo: installedInfo)
                .listRowBackground(AppListRowBackground())
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .navigationTitle("GEO 与 ASN")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: refreshID) { await refreshInstalledInfo() }
    }

    private var refreshID: String {
        "\(settings.geoEnabled)-\(settings.geodataMode)-\(geoDatabase.revision)"
    }

    private func refreshInstalledInfo() async {
        guard settings.geoEnabled else {
            installedInfo = nil
            return
        }
        installedInfo = nil
        let info = await geoDatabase.installedInfo(geodataMode: settings.geodataMode)
        guard !Task.isCancelled else { return }
        installedInfo = info
    }
}

private struct TunnelRouteSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                InfoToggleRow(title: "接管所有网络", message: "将系统默认排除的流量也纳入隧道。只有需要完整 VPN 覆盖时才建议开启。", isOn: $settings.includeAllNetworks)
                InfoToggleRow(title: "强制路由", message: "即使未接管所有网络，也强制按规则路由隧道流量。", isOn: $settings.enforceRoutes)
                InfoToggleRow(title: "阻止常见 WebRTC STUN 直连", message: "仅阻止常见公网 STUN 探测端点以降低 WebRTC 泄露风险，不封锁普通 DIRECT 的语音、视频和 P2P 流量。", isOn: $settings.blockDirectSTUN)
                InfoToggleRow(title: "排除蜂窝服务", message: "将蜂窝网络服务排除在隧道之外，避免影响系统电话和运营商服务。", isOn: $settings.excludeCellularServices)
                InfoToggleRow(title: "排除 APNs 推送", message: "将 Apple 推送服务排除在隧道之外，保持系统通知稳定。", isOn: $settings.excludeAPNs)
                if #available(iOS 17.4, *) {
                    InfoToggleRow(title: "排除设备间通信", message: "将本地设备间通信排除在隧道之外，保留 AirDrop 和附近设备连接。", isOn: $settings.excludeDeviceCommunication)
                }
            }
            .listRowBackground(AppListRowBackground())
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .navigationTitle("隧道路由")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SettingsNavigationRow<Destination: View>: View {
    let title: String
    let systemImage: String
    let message: String
    let destination: Destination

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                InfoButton(message: message, accessibilityLabel: "查看\(title)说明")
            }
        }
    }
}

private struct GeoSettingsContent: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var geoDatabase: GeoDatabaseManager
    let installedInfo: GeoInstalledInfo?

    var body: some View {
        Group {
            Toggle("启用 geo 规则", isOn: $settings.geoEnabled)
            if settings.geoEnabled {
                if AppGroup.containerURL == nil {
                    Label("签名未授予 \(AppGroup.identifier)，连接时会自动忽略 GEO/ASN 规则。",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if AppGroup.usesTrollStoreFallback {
                    Label("正在使用 TrollStore 共享目录",
                          systemImage: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.green)
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
                .disabled(geoDatabase.isUpdating)
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

private struct InfoLabel: View {
    let title: String
    let message: String
    @State private var showingInfo = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            InfoButton(message: message, accessibilityLabel: "查看\(title)说明")
        }
    }
}

private struct InfoButton: View {
    let message: String
    var accessibilityLabel = "查看说明"
    @State private var showingInfo = false

    var body: some View {
        Button {
            showingInfo = true
        } label: {
            Image(systemName: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .popover(isPresented: $showingInfo, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .frame(minWidth: 220, maxWidth: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .presentationCompactAdaptation(.popover)
        }
    }
}

private struct SettingsInfoRow: View {
    let title: String
    let systemImage: String
    let tint: Color
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(tint)
            Spacer(minLength: 8)
            InfoButton(message: message, accessibilityLabel: "查看\(title)说明")
        }
    }
}

private struct InfoToggleRow: View {
    let title: String
    let message: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            InfoLabel(title: title, message: message)
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
    }
}

/// 内核状态页：验证 App 与 Tunnel 之间的主控制通道。
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
        .background(AppAmbientBackground())
        .navigationTitle("内核状态")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("刷新") { Task { await reload() } } }
        .task { await reload() }
    }

    private func reload() async {
        text = "探测中…"
        let transport = TrollStoreIPC.isEnabled
            ? "TrollStore 文件 IPC"
            : "sendProviderMessage IPC"
        var out = "（请在 VPN 已连接时探测）\n\n【\(transport)】\n"
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
