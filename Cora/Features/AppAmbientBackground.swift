import SwiftUI

/// 所有一级页面共用的苹果色系动态底色。色场按时间驱动，避免导航切换后动画状态丢失。
struct AppAmbientBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 15.0)) { timeline in
            GeometryReader { proxy in
                let size = proxy.size
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate

                ZStack {
                    baseGradient

                    ambientField(color: palette[0], size: size,
                                 x: CGFloat(sin(time / 19)) * size.width * 0.24 - size.width * 0.18,
                                 y: CGFloat(cos(time / 23)) * size.height * 0.17 - size.height * 0.28,
                                 rotation: sin(time / 31) * 14)

                    ambientField(color: palette[1], size: size,
                                 x: CGFloat(cos(time / 21)) * size.width * 0.27 + size.width * 0.22,
                                 y: CGFloat(sin(time / 27)) * size.height * 0.20 - size.height * 0.02,
                                 rotation: cos(time / 29) * 18)

                    ambientField(color: palette[2], size: size,
                                 x: CGFloat(sin(time / 25 + 1.4)) * size.width * 0.30 - size.width * 0.08,
                                 y: CGFloat(cos(time / 20 + 0.8)) * size.height * 0.18 + size.height * 0.30,
                                 rotation: sin(time / 33 + 0.6) * 16)

                    ambientField(color: palette[3], size: size,
                                 x: CGFloat(cos(time / 28 + 2.1)) * size.width * 0.24 + size.width * 0.20,
                                 y: CGFloat(sin(time / 24 + 1.7)) * size.height * 0.16 + size.height * 0.42,
                                 rotation: cos(time / 35 + 0.4) * 12)
                }
                .compositingGroup()
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var baseGradient: LinearGradient {
        let colors: [Color]
        if colorScheme == .dark {
            colors = [
                Color(red: 0.025, green: 0.035, blue: 0.075),
                Color(red: 0.055, green: 0.045, blue: 0.105),
                Color(red: 0.025, green: 0.075, blue: 0.095),
            ]
        } else {
            colors = [
                Color(red: 0.93, green: 0.98, blue: 1.00),
                Color(red: 0.98, green: 0.94, blue: 1.00),
                Color(red: 0.91, green: 1.00, blue: 0.98),
            ]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var palette: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.08, green: 0.45, blue: 1.00).opacity(0.58),
                Color(red: 0.72, green: 0.18, blue: 0.92).opacity(0.43),
                Color(red: 0.00, green: 0.78, blue: 0.82).opacity(0.46),
                Color(red: 0.96, green: 0.18, blue: 0.52).opacity(0.30),
            ]
        }
        return [
            Color(red: 0.00, green: 0.64, blue: 1.00).opacity(0.48),
            Color(red: 0.72, green: 0.50, blue: 1.00).opacity(0.42),
            Color(red: 0.00, green: 0.88, blue: 0.79).opacity(0.39),
            Color(red: 1.00, green: 0.42, blue: 0.68).opacity(0.33),
        ]
    }

    private func ambientField(color: Color, size: CGSize,
                              x: CGFloat, y: CGFloat, rotation: Double) -> some View {
        let extent = max(size.width, size.height)
        return Ellipse()
            .fill(
                RadialGradient(colors: [color, color.opacity(0.42), .clear],
                               center: .center, startRadius: 8, endRadius: extent * 0.62)
            )
            .frame(width: extent * 1.45, height: extent * 0.82)
            .blur(radius: colorScheme == .dark ? 48 : 56)
            .rotationEffect(.degrees(rotation))
            .offset(x: x, y: y)
            .blendMode(colorScheme == .dark ? .screen : .normal)
    }
}

/// Form/List 行使用的统一半透明材质，避免透明滚动底色削弱内容层级。
struct AppListRowBackground: View {
    var body: some View {
        Rectangle().fill(.regularMaterial)
    }
}
