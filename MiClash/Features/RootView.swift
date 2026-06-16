import SwiftUI

/// 根视图：三个主页面——连接 / 订阅 / 节点。
/// 全局状态机与订阅 Store 经 environmentObject 下发，各页只读状态、调方法（单向数据流）。
struct RootView: View {
    var body: some View {
        TabView {
            ConnectView()
                .tabItem { Label("连接", systemImage: "power") }

            SubscriptionsView()
                .tabItem { Label("订阅", systemImage: "doc.text") }

            ProxiesView()
                .tabItem { Label("节点", systemImage: "point.3.connected.trianglepath.dotted") }
        }
    }
}
