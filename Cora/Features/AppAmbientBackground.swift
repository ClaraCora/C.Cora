import SwiftUI

/// 一级页面共用的静态苹果色系底色。
/// 采用静态径向色场，避免滚动时持续触发高成本模糊动画。
struct AppAmbientBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let extent = max(proxy.size.width, proxy.size.height)
            ZStack {
                baseGradient

                RadialGradient(colors: [primaryField, .clear],
                               center: .center,
                               startRadius: 8,
                               endRadius: extent * 0.72)
                    .frame(width: extent * 1.42, height: extent * 1.18)
                    .offset(x: -proxy.size.width * 0.28,
                            y: -proxy.size.height * 0.28)

                RadialGradient(colors: [secondaryField, .clear],
                               center: .center,
                               startRadius: 8,
                               endRadius: extent * 0.68)
                    .frame(width: extent * 1.34, height: extent * 1.08)
                    .offset(x: proxy.size.width * 0.30,
                            y: proxy.size.height * 0.04)

                RadialGradient(colors: [tertiaryField, .clear],
                               center: .center,
                               startRadius: 4,
                               endRadius: extent * 0.64)
                    .frame(width: extent * 1.25, height: extent * 0.92)
                    .offset(x: -proxy.size.width * 0.06,
                            y: proxy.size.height * 0.38)
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
        return LinearGradient(colors: colors,
                              startPoint: .topLeading,
                              endPoint: .bottomTrailing)
    }

    private var primaryField: Color {
        colorScheme == .dark
            ? Color(red: 0.08, green: 0.45, blue: 1.00).opacity(0.28)
            : Color(red: 0.00, green: 0.64, blue: 1.00).opacity(0.22)
    }

    private var secondaryField: Color {
        colorScheme == .dark
            ? Color(red: 0.72, green: 0.18, blue: 0.92).opacity(0.22)
            : Color(red: 0.72, green: 0.50, blue: 1.00).opacity(0.20)
    }

    private var tertiaryField: Color {
        colorScheme == .dark
            ? Color(red: 0.00, green: 0.78, blue: 0.82).opacity(0.22)
            : Color(red: 0.00, green: 0.88, blue: 0.79).opacity(0.18)
    }
}

/// Form/List 行使用的统一半透明材质，避免透明滚动底色削弱内容层级。
struct AppListRowBackground: View {
    var body: some View {
        Rectangle().fill(.regularMaterial)
    }
}
