import SwiftUI
import UIKit

struct ProxyNodeFailureToast: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let failure: ProxyNodeTestFailure
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(failure.node) 测速失败")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(failure.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(failure.node) 测速失败，\(failure.message)")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭失败提示")
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 12)
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 14, x: 0, y: 6)
        .onAppear {
            if UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement,
                                     argument: "\(failure.node) 测速失败，\(failure.message)")
            }
        }
    }
}
