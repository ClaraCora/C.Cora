import Foundation

/// Rust v2 samples. Missing metrics stay unavailable; RSS is not phys_footprint.
struct MemoryDiagnosticSample: Decodable {
    let v: Int?
    let kind: String?
    let t: Int64?
    let session: String?
    let event: String?
    let sampleCount: UInt64?
    let physFootprint: UInt64?
    let residentBytes: UInt64?
    let activeTCP: Int?
    let uploadTotal: UInt64?
    let downloadTotal: UInt64?
    let running: Bool?
}

enum MemoryDiagnosticAnalyzer {
    static func analyze(_ text: String) -> String {
        let decoder = JSONDecoder()
        var samples: [MemoryDiagnosticSample] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.first == "{", let item = try? decoder.decode(MemoryDiagnosticSample.self, from: Data(line.utf8)),
                  item.v == 2, item.kind == "rust", item.t != nil, item.session != nil else { continue }
            samples.append(item)
            if samples.count > 512 { samples.removeFirst(samples.count - 512) }
        }
        guard let session = samples.last?.session else {
            return "没有可分析的 Rust v2 采样。请开启开发者模式后重新采集；旧 Go 诊断不适用于当前内核。"
        }
        let current = samples.filter { $0.session == session }.sorted { ($0.t ?? 0) < ($1.t ?? 0) }
        guard let first = current.first, let last = current.last else { return "采样不可用" }
        let span = max(0, (last.t ?? 0) - (first.t ?? 0)) / 1000
        var result = ["Rust 内存诊断 · 最近会话", "有效采样 \(current.count) 条，覆盖 \(span) 秒",
                      "NE 物理内存：\(bytes(last.physFootprint))；采样峰值 \(bytes(current.compactMap(\.physFootprint).max()))",
                      "Rust resident memory（RSS）：\(bytes(last.residentBytes))",
                      "活动 TCP 流：\(last.activeTCP.map(String.init) ?? "不可用")；UDP 连接明细不可用",
                      "累计上传 \(bytes(last.uploadTotal))，累计下载 \(bytes(last.downloadTotal))",
                      "引擎状态：\(last.running.map { $0 ? "运行中" : "已停止" } ?? "不可用")"]
        if let a = first.physFootprint, let b = last.physFootprint {
            let delta = Int64(clamping: b) - Int64(clamping: a)
            result.append(String(format: "物理内存变化：%+.2f MiB", Double(delta) / 1048576))
        }
        result.append("RSS 与 phys_footprint 是不同指标；单段采样不能证明内存泄漏，需结合负载、CPU 和断流记录比较。")
        return result.joined(separator: "\n")
    }

    private static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "不可用" }
        return String(format: "%.2f MiB", Double(value) / 1048576)
    }
}
