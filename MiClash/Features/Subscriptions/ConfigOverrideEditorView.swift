import SwiftUI

/// 每个配置独立保存的 YAML 覆写层；远程订阅刷新不会改动这里的内容。
struct ConfigOverrideEditorView: View {
    @EnvironmentObject private var store: SubscriptionStore
    @Environment(\.dismiss) private var dismiss

    let subscription: Subscription
    @State private var yaml: String
    @State private var validationError: String?
    @State private var showClearConfirmation = false

    init(subscription: Subscription) {
        self.subscription = subscription
        _yaml = State(initialValue: subscription.overrideYAML)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $yaml)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 360)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("覆写内容（YAML）")
                } footer: {
                    Text("字段会递归合并，列表默认替换。prepend-字段名 / append-字段名可在列表前后追加，null 可删除字段。iOS 强制配置仍以应用设置为准。")
                }

                if subscription.hasOverride {
                    Section {
                        Button("清除覆写", role: .destructive) {
                            showClearConfirmation = true
                        }
                    }
                }
            }
            .navigationTitle("配置覆写")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .disabled(!isDirty)
                }
            }
            .confirmationDialog("清除当前覆写？", isPresented: $showClearConfirmation) {
                Button("清除覆写", role: .destructive) {
                    yaml = ""
                }
            }
            .alert("无法保存", isPresented: Binding(
                get: { validationError != nil },
                set: { if !$0 { validationError = nil } }
            )) {
                Button("好") { validationError = nil }
            } message: {
                Text(validationError ?? "")
            }
        }
    }

    private var isDirty: Bool {
        yaml != subscription.overrideYAML
    }

    private func save() {
        if let error = store.updateOverride(subscription.id, yaml: yaml) {
            validationError = error
            return
        }
        dismiss()
    }
}
