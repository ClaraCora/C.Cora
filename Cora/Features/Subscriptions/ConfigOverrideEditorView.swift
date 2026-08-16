import SwiftUI

struct ConfigOverrideSettingsView: View {
    @EnvironmentObject private var overrides: ConfigOverrideStore
    @State private var showRestoreConfirmation = false

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    DNSOverrideSettingsView()
                } label: {
                    OverrideCategoryLabel(title: "DNS", systemImage: "network",
                                          enabled: overrides.overwriteDNS)
                }
                NavigationLink {
                    SnifferOverrideSettingsView()
                } label: {
                    OverrideCategoryLabel(title: "嗅探", systemImage: "waveform.path.ecg",
                                          enabled: overrides.overwriteSniffer)
                }
                NavigationLink {
                    TunOverrideSettingsView()
                } label: {
                    OverrideCategoryLabel(title: "TUN", systemImage: "arrow.triangle.branch",
                                          enabled: overrides.overwriteTun)
                }
            }
            .listRowBackground(AppListRowBackground())

            Section {
                Button("恢复默认配置", role: .destructive) {
                    showRestoreConfirmation = true
                }
            }
            .listRowBackground(AppListRowBackground())
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .navigationTitle("配置覆写")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("恢复所有默认配置？", isPresented: $showRestoreConfirmation) {
            Button("恢复默认配置", role: .destructive) {
                overrides.restoreDefaults()
            }
        }
    }
}

private struct OverrideCategoryLabel: View {
    let title: String
    let systemImage: String
    let enabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            SettingsSymbol(systemImage: systemImage)
            HStack {
                Text(title)
                Spacer()
                Text(enabled ? "覆写" : "不覆写")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct DNSOverrideSettingsView: View {
    @EnvironmentObject private var overrides: ConfigOverrideStore

    var body: some View {
        Form {
            Section {
                Toggle("使用 DNS 设置", isOn: $overrides.overwriteDNS)
            }
            .listRowBackground(AppListRowBackground())

            Section("基础") {
                HStack {
                    Text("监听地址")
                    Spacer()
                    TextField("0.0.0.0:1053", text: $overrides.dnsListen)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Toggle("DoH H3 优先", isOn: $overrides.dnsPreferH3)
                Toggle("使用系统 Hosts", isOn: $overrides.dnsUseSystemHosts)
                Toggle("使用内置 Hosts", isOn: $overrides.dnsUseHosts)
                NavigationLink("编辑 Hosts") {
                    HostOverridesView()
                }
            }
            .disabled(!overrides.overwriteDNS)
            .listRowBackground(AppListRowBackground())

            Section("解析模式") {
                Picker("DNS 模式", selection: $overrides.dnsEnhancedMode) {
                    ForEach(ConfigOverrideStore.dnsModeOptions, id: \.self) { Text($0).tag($0) }
                }
                Picker("Fake IP 过滤模式", selection: $overrides.fakeIPFilterMode) {
                    ForEach(ConfigOverrideStore.fakeIPFilterModeOptions, id: \.self) {
                        Text($0).tag($0)
                    }
                }
                NavigationLink {
                    StringListEditorView(title: "Fake IP 过滤内容",
                                         values: $overrides.fakeIPFilter,
                                         placeholder: "域名、通配符或规则")
                } label: {
                    ListSettingLabel(title: "Fake IP 过滤内容",
                                     count: overrides.fakeIPFilter.count)
                }
                Button("载入常见过滤内容") {
                    overrides.fakeIPFilter = ConfigOverrideStore.commonFakeIPFilter
                }
                Toggle("遵循分流规则", isOn: $overrides.dnsRespectRules)
            }
            .disabled(!overrides.overwriteDNS)
            .listRowBackground(AppListRowBackground())

            Section("域名解析服务器") {
                nameserverLink("默认域名解析服务器", values: $overrides.defaultNameservers)
                nameserverLink("域名解析服务器", values: $overrides.nameservers)
                nameserverLink("代理域名解析服务器", values: $overrides.proxyNameservers)
                nameserverLink("直连域名解析服务器", values: $overrides.directNameservers)
                nameserverLink("Fallback 域名解析服务器", values: $overrides.fallbackNameservers)
                Toggle("备用 GeoIP", isOn: $overrides.fallbackGeoIP)
            }
            .disabled(!overrides.overwriteDNS)
            .listRowBackground(AppListRowBackground())
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .navigationTitle("DNS 设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func nameserverLink(_ title: String, values: Binding<[String]>) -> some View {
        NavigationLink {
            StringListEditorView(title: title, values: values, placeholder: "DNS 服务器地址")
        } label: {
            ListSettingLabel(title: title, count: values.wrappedValue.count)
        }
    }
}

private struct SnifferOverrideSettingsView: View {
    @EnvironmentObject private var overrides: ConfigOverrideStore

    var body: some View {
        Form {
            Section {
                Toggle("使用嗅探设置", isOn: $overrides.overwriteSniffer)
                Toggle("启用嗅探", isOn: $overrides.snifferEnabled)
                    .disabled(!overrides.overwriteSniffer)
            }
            .listRowBackground(AppListRowBackground())

            Section("行为") {
                Toggle("强制 DNS 映射", isOn: $overrides.snifferForceDNSMapping)
                Toggle("解析纯 IP 流量", isOn: $overrides.snifferParsePureIP)
                Toggle("覆写目标地址", isOn: $overrides.snifferOverrideDestination)
            }
            .disabled(!overrides.overwriteSniffer || !overrides.snifferEnabled)
            .listRowBackground(AppListRowBackground())

            Section("协议") {
                Toggle("HTTP", isOn: $overrides.sniffHTTP)
                Toggle("TLS", isOn: $overrides.sniffTLS)
                Toggle("QUIC", isOn: $overrides.sniffQUIC)
            }
            .disabled(!overrides.overwriteSniffer || !overrides.snifferEnabled)
            .listRowBackground(AppListRowBackground())

            Section("域名") {
                NavigationLink {
                    StringListEditorView(title: "强制嗅探域名",
                                         values: $overrides.forceSniffDomains,
                                         placeholder: "域名或通配符")
                } label: {
                    ListSettingLabel(title: "强制嗅探域名",
                                     count: overrides.forceSniffDomains.count)
                }
                NavigationLink {
                    StringListEditorView(title: "跳过嗅探域名",
                                         values: $overrides.skipSniffDomains,
                                         placeholder: "域名或通配符")
                } label: {
                    ListSettingLabel(title: "跳过嗅探域名",
                                     count: overrides.skipSniffDomains.count)
                }
            }
            .disabled(!overrides.overwriteSniffer || !overrides.snifferEnabled)
            .listRowBackground(AppListRowBackground())
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .navigationTitle("流量嗅探")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TunOverrideSettingsView: View {
    @EnvironmentObject private var overrides: ConfigOverrideStore

    var body: some View {
        Form {
            Section {
                Toggle("使用隧道设置", isOn: $overrides.overwriteTun)
            }
            .listRowBackground(AppListRowBackground())
            Section {
                NavigationLink {
                    StringListEditorView(title: "DNS 接管规则",
                                         values: $overrides.tunDNSHijack,
                                         placeholder: "如 any:53")
                } label: {
                    ListSettingLabel(title: "DNS 接管规则", count: overrides.tunDNSHijack.count)
                }
                Toggle("严格路由", isOn: $overrides.tunStrictRoute)
                Toggle("ICMP 转发", isOn: $overrides.tunICMPForwarding)
            }
            .disabled(!overrides.overwriteTun)
            .listRowBackground(AppListRowBackground())
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .navigationTitle("隧道设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ListSettingLabel: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count) 项")
                .foregroundStyle(.secondary)
        }
    }
}

private struct StringListEditorView: View {
    let title: String
    @Binding var values: [String]
    let placeholder: String

    var body: some View {
        List {
            ForEach(values.indices, id: \.self) { index in
                TextField(placeholder, text: Binding(
                    get: { values[index] },
                    set: { values[index] = $0 }
                ))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .listRowBackground(AppListRowBackground())
            }
            .onDelete { values.remove(atOffsets: $0) }
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    values.append("")
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加")
            }
        }
    }
}

private struct HostOverridesView: View {
    @EnvironmentObject private var overrides: ConfigOverrideStore

    var body: some View {
        List {
            ForEach($overrides.hosts) { $host in
                VStack(alignment: .leading, spacing: 8) {
                    TextField("域名或通配符", text: $host.domain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("IP 地址", text: $host.address)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(AppListRowBackground())
            }
            .onDelete { overrides.hosts.remove(atOffsets: $0) }
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .navigationTitle("Hosts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    overrides.hosts.append(HostOverride())
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加 Host")
            }
        }
    }
}
