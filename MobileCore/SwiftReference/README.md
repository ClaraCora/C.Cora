# Mihomo / Legacy 回退参考

这些文件逐字取自迁移基线 `c46bef6`，不参与标准 target 或 CI。
原 CoraLegacy 与 CoraTunnelLegacy targets 使用共享的 Cora、CoraTunnel、Shared 源码，并没有独立源码目录。
旧 Go 工程、补丁和框架构建脚本仍在 MobileCore；旧 Vendor / VendorLegacy 目录不删除。
完整旧 Swift 源码可在 Git 提交 c46bef6 中恢复；此处保留被 Rust 桥接替代的核心文件及旧工程定义，方便比较。
不要把这里的 Swift 文件加入新 Xcode targets。
