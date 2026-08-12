import SwiftUI

/// 所有一级页面共用的苹果色系动态底色。内容区使用半透明系统材质，保留层次与可读性。
struct AppAmbientBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var drift = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                baseColor
                colorField(color(0), size: size,
                           x: drift ? -size.width * 0.16 : size.width * 0.20,
                           y: drift ? -size.height * 0.20 : size.height * 0.12,
                           rotation: drift ? -20 : 12)
                colorField(color(1), size: size,
                           x: drift ? size.width * 0.27 : -size.width * 0.22,
                           y: drift ? size.height * 0.12 : -size.height * 0.18,
                           rotation: drift ? 24 : -16)
                colorField(color(2), size: size,
                           x: drift ? size.width * 0.04 : -size.width * 0.10,
                           y: drift ? size.height * 0.36 : -size.height * 0.30,
                           rotation: drift ? 8 : -8)
            }
            .ignoresSafeArea()
            .onAppear { startAnimationIfNeeded() }
            .onChange(of: reduceMotion) { _, _ in startAnimationIfNeeded() }
        }
        .allowsHitTesting(false)
    }

    private var baseColor: Color {
        Color(uiColor: colorScheme == .dark ? .systemBackground : .systemGroupedBackground)
    }

    private func color(_ index: Int) -> Color {
        let light: [Color] = [
            .cyan.opacity(0.48), .pink.opacity(0.37), .mint.opacity(0.42),
        ]
        let dark: [Color] = [
            .blue.opacity(0.42), .purple.opacity(0.38), .teal.opacity(0.36),
        ]
        return (colorScheme == .dark ? dark : light)[index]
    }

    private func colorField(_ color: Color, size: CGSize,
                            x: CGFloat, y: CGFloat, rotation: Double) -> some View {
        Ellipse()
            .fill(color)
            .frame(width: max(size.width, size.height) * 1.22,
                   height: max(size.width, size.height) * 0.68)
            .blur(radius: 86)
            .rotationEffect(.degrees(rotation))
            .offset(x: x, y: y)
    }

    private func startAnimationIfNeeded() {
        guard !reduceMotion else {
            drift = false
            return
        }
        withAnimation(.easeInOut(duration: 22).repeatForever(autoreverses: true)) {
            drift = true
        }
    }
}

/// Form/List 行使用的统一半透明材质，避免透明滚动底色削弱内容层级。
struct AppListRowBackground: View {
    var body: some View {
        Rectangle().fill(.regularMaterial)
    }
}
