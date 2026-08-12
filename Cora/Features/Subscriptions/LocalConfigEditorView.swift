import SwiftUI

/// 本地配置编辑器：新建（editing 为 nil）或编辑一个本地 Clash/mihomo 配置。
/// 直接手写/粘贴 YAML，保存到订阅列表（url 为空即本地配置）。
struct LocalConfigEditorView: View {
    @EnvironmentObject private var store: SubscriptionStore
    @Environment(\.dismiss) private var dismiss

    /// 传入已有配置则为编辑模式；nil 为新建。
    let editing: Subscription?

    @State private var name: String
    @State private var yaml: String

    init(editing: Subscription?) {
        self.editing = editing
        _name = State(initialValue: editing?.name ?? "")
        _yaml = State(initialValue: editing?.yaml ?? Self.template)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("如：我的本地配置", text: $name)
                }
                .listRowBackground(AppListRowBackground())
                Section {
                    TextEditor(text: $yaml)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 320)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("配置内容（Clash/mihomo YAML）")
                } footer: {
                    Text("需包含 proxies / proxy-groups / rules。tun、dns 等 iOS 安全项会在连接时由内核统一覆盖，无需手写。")
                }
                .listRowBackground(AppListRowBackground())
            }
            .scrollContentBackground(.hidden)
            .background(AppAmbientBackground())
            .navigationTitle(editing == nil ? "新建本地配置" : "编辑配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        let n = name, y = yaml
                        if let editing {
                            store.updateLocal(editing.id, name: n, yaml: y)
                        } else {
                            store.addLocal(name: n, yaml: y)
                        }
                        dismiss()
                    }
                    .disabled(yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    /// 新建时的起始模板，给个最小可用骨架。
    private static let template = """
    proxies:
      # - { name: 示例, type: ss, server: 1.2.3.4, port: 443, cipher: aes-128-gcm, password: pwd }

    proxy-groups:
      - name: 节点选择
        type: select
        proxies:
          - DIRECT

    rules:
      - MATCH,节点选择
    """
}
