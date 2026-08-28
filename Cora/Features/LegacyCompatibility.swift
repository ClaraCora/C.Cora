import SwiftUI

/// Keeps the iOS 17 presentation where available while providing the same
/// information and actions to the iOS 16.4 Legacy target.
struct CoraUnavailableState: View {
    let title: String
    let systemImage: String
    let description: String?
    let actionTitle: String?
    let action: (() -> Void)?

    init(_ title: String,
         systemImage: String,
         description: String? = nil,
         actionTitle: String? = nil,
         action: (() -> Void)? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        Group {
            if #available(iOS 17.0, *) {
                nativeState
            } else {
                legacyState
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    @available(iOS 17.0, *)
    @ViewBuilder private var nativeState: some View {
        if let actionTitle, let action {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                if let description { Text(description) }
            } actions: {
                Button(actionTitle, action: action)
            }
        } else {
            ContentUnavailableView(title,
                                   systemImage: systemImage,
                                   description: description.map { Text($0) })
        }
    }

    private var legacyState: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            if let description {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .padding(.top, 2)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}

struct CoraSearchUnavailableState: View {
    let query: String

    var body: some View {
        CoraUnavailableState(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 ? "暂无内容"
                                 : "没有搜索结果",
                             systemImage: "magnifyingglass",
                             description: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 ? nil
                                 : "“\(query)”")
    }
}

extension View {
    /// `ContentTransition.numericText()` is an iOS 17 API. The Legacy build
    /// keeps the value update without the transition animation.
    @ViewBuilder
    func coraNumericTextTransition() -> some View {
        if #available(iOS 17.0, *) {
            contentTransition(.numericText())
        } else {
            self
        }
    }
}
