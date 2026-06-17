import Foundation

/// 控制中心磁贴的 kind 标识。磁贴用它注册；主 App / NE 用它请求系统刷新磁贴
/// （ControlCenter.reloadControls），让 App 内启停能即时同步到控制中心。
enum ControlWidgetKind {
    static let vpn = "com.miclash.app.control.vpn"
}
