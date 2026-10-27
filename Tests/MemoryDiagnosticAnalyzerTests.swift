import Foundation

@main
struct MemoryDiagnosticAnalyzerTests {
    static func main() {
        let old = MemoryDiagnosticAnalyzer.analyze(#"{"v":1,"go":{"heapAlloc":123}}"#)
        precondition(old.contains("旧 Go"))
        let start = #"{"v":2,"kind":"rust","session":"one","t":1000,"physFootprint":10485760,"residentBytes":15728640,"activeTCP":2,"running":true}"#
        let end = #"{"v":2,"kind":"rust","session":"one","t":61000,"physFootprint":12582912,"activeTCP":3,"uploadTotal":1048576,"running":true}"#
        let result = MemoryDiagnosticAnalyzer.analyze("{broken\n" + start + "\n" + end)
        precondition(result.contains("覆盖 60 秒"))
        precondition(result.contains("+2.00 MiB"))
        precondition(result.contains("RSS）：不可用"), "missing RSS was treated as zero or stale")
        precondition(result.contains("UDP 连接明细不可用"))
        let next = #"{"v":2,"kind":"rust","session":"two","t":62000,"residentBytes":8388608,"running":false}"#
        let restarted = MemoryDiagnosticAnalyzer.analyze(start + "\n" + end + "\n" + next)
        precondition(restarted.contains("有效采样 1 条"))
        precondition(restarted.contains("NE 物理内存：不可用"))
        precondition(restarted.contains("已停止"))
        precondition(!restarted.contains("+2.00"))
        print("Rust memory diagnostic analyzer tests passed")
    }
}
