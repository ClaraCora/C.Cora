import SwiftUI

/// 所有主页面共用的低对比度苹果色系动态背景；内容面板仍保持系统材质可读性。
struct AppAmbientBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var drift = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                baseColor
                blur(color(0), x: drift ? size.width * 0.16 : -size.width * 0.18,
                     y: drift ? -size.height * 0.12 : size.height * 0.18, size: size)
                blur(color(1), x: drift ? -size.width * 0.24 : size.width * 0.20,
                     y: drift ? size.height * 0.18 : -size.height * 0.14, size: size)
                blur(color(2), x: drift ? size.width * 0.08 : -size.width * 0.08,
                     y: drift ? size.height * 0.35 : -size.height * 0.30, size: size)
            }
            .ignoresSafeArea()
            .onAppear {
                withAnimation(.easeInOut(duration: 18).repeatForever(autoreverses: true)) {
                    drift = true
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var baseColor: Color {
        Color(uiColor: colorScheme == .dark ? .systemBackground : .systemGroupedBackground)
    }

    private func color(_ index: Int) -> Color {
        let light: [Color] = [.cyan.opacity(0.25), .pink.opacity(0.19), .mint.opacity(0.23)]
        let dark: [Color] = [.blue.opacity(0.19), .purple.opacity(0.18), .teal.opacity(0.16)]
        return (colorScheme == .dark ? dark : light)[index]
    }

    private func blur(_ color: Color, x: CGFloat, y: CGFloat, size: CGSize) -> some View {
        Circle()
            .fill(color)
            .frame(width: max(size.width, size.height) * 0.88)
            .blur(radius: 72)
            .offset(x: x, y: y)
    }
}
