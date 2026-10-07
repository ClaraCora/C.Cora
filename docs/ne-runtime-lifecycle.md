# NE 生命周期与控制面内存优化

实施日期：2026-10-07。继续使用 Mihomo v1.19.31、gVisor 和现有 Go 构建工具链。
本次针对会话残留与控制请求峰值，不承诺把正常稳态 31 MB 降到某个固定值。

## 会话退出和启动回滚

- Go 使用同一个幂等清理入口处理 Stop、重新启动、解析/初始化失败和启动 panic。
  控制任务先取消，隧道进入 suspend，再关闭连接、按对象去重关闭 Provider。
- Provider fetcher 和健康检查支持取消及等待退出；关闭全部 Provider 共享两秒
  等待期限。旧任务超时会留下日志，旧会话结果不能作为当前会话成功结果返回。
- `ApplyConfigWithError` 回传 Provider 初始化错误，包括初始化工作 goroutine
  中的 panic。旧 `ApplyConfig` 接口保持兼容。缺失或损坏 Provider 文件现在会
  让启动明确失败并清理，避免只写错误日志后留下半启动配置。
- 停止 NTP 并等待其循环退出；取消会关闭正在等待的 NTP UDP socket。
- 停止 DNS server，释放 resolver 传输与 DNS runtime/mapper 引用；先由
  executor 持久化 Fake-IP 状态，保留磁盘文件。
- 日志不再使用永久 `sync.Once` 订阅。停止时退订并等待写入 goroutine 关闭
  句柄，新会话重新绑定 home；清理脚本入口 IP 缓存与会话诊断快照状态。
  工作目录重绑定和日志读取使用相同锁，避免重连期间读取旧路径的竞态。
- Swift 使用会话代次保护旧启动回调，历史记录启动/停止串行完成。TrollStore
  服务先从生命周期状态中移除，再在生命周期队列外等待关闭，避免队列互等。
  新服务在代次校验和安装的同一边界内启动，首次扫描异步执行，文件请求绑定
  原会话代次，避免旧启动清掉新会话的文件或重放旧请求。
  停止后的诊断在 Go 清理完成后记录，可看到 NTP/日志订阅和 Provider 基线。

## 控制面调度与分块读租约

数据包转发不经过调度器。控制任务总并发最多 8，轻查询 4、中型快照 3、
重任务 2；脚本类可使用总并发预算，每次脚本最多 4 个请求，保留 App 原有
每脚本最多 12 请求限制。等待队列最多 24，超过立即返回 `code: busy`；
排队超时返回 `code: timeout`，会话切换取消排队工作并丢弃旧响应。

Provider 按名称单飞，同类全量刷新不能与单个刷新叠加。Go 只在读锁内取得
Provider 指针和代次，网络更新在锁外运行；完成后检查会话代次。
规则来源预览的路径在锁内读取，文件读取和 JSON 编码在锁外进行。
新增字节桥接接口复用 JSON 编码器，保留原字符串接口与 IPC 命令。

IPC 仍为 12 槽位、8 MiB 总载荷、512 KiB 内存预算、64 KiB 内存阈值、
12 KiB 分块和 30 秒有效期。文件读租约在锁内登记，磁盘 I/O 在锁外完成；
过期/淘汰/会话重置先使响应失效，最后一个 reader 退出后删除文件。
TrollStore 请求入口同时限制体积和数量；其 32 个请求名额覆盖 8 个执行任务
与 24 个等待任务，240 秒传输清理期限兼容现有最长 190 秒批量测速 IPC。

## 归因与不变项

开发者导出新增 runtime generation、可关闭 Provider 数、活动刷新数、NTP、
日志订阅、脚本 IP 缓存、控制任务执行/排队/拒绝/取消/耗时和 SQLite 写入指标。
`providerRefreshActive` 是控制刷新调用数，`providerRefreshTasks` 包含手动和
自动的实际 fetch/parse 工作；等待定时器不计为正在刷新。
缓存文本字节不包括 map/对象开销，历史采样字节是最近 JSON 载荷，不能当成
额外常驻占用。布尔状态在详细日志中保留布尔值，在数字摘要中用 0/1 表示。

排行榜、历史记录采样、gVisor、收发队列、DNS cache 512、Proxy Provider 健康
检查、测速内部并发、MRS、GOGC=50 和 35 MiB GOMEMLIMIT 均保持原值。
正常模式不新增诊断采样线程；手动释放和压力事件继续使用已有缓冲回收及 GC。

## 可选低内存配置

生成器只产生独立副本，禁止覆盖现有文件；不由 App/NE 自动调用或启用：

```sh
cd MobileCore
go run ./cmd/low-memory-profile \
  -input /path/config.yaml -output /path/config.low-memory.yaml \
  -keep-auto '需要自动更新的规则来源1,需要自动更新的规则来源2'
```

副本将 `find-process-mode` 改为 `off`，未列入 `keep-auto` 的规则来源设为
`interval: 0`。省略 `keep-auto` 表示所有 Rule Provider 手动刷新。
路由顺序、MRS、Proxy Provider 与健康检查保留；进程字段可能为空，规则不会
自动跟随远程变化。未知保留名称或不支持的 Provider alias 会报错而不写文件。

## 验证范围

Windows 本地可运行 Go 默认/低内存测试与 vet，检查版本绑定补丁严格应用、
100 次配置 Apply/Stop（含 DNS/Fake-IP 开关）、Fetcher/健康检查/NTP 循环、
更新与 Stop 并发、初始化回滚、取消中缓存写入及可选配置保真。
本次以上 Go 测试与两种 vet 均已通过；生命周期补丁严格应用并逐文件核对一致，
Objective-C 绑定生成成功，Swift 使用的 14 个 Data 接口均与头文件匹配。
本地验证使用已缓存的 Go 1.25.5，CI 仍固定 Go 1.25.4，未调整项目工具链配置。
Swift 调度器、文件读取中会话切换、TrollStore 请求限制与启动队列/迟到回复、
诊断旧字段兼容测试
已接入 macOS CI。标准/Legacy XCFramework、完整 Xcode、race 以及这些 Swift
测试需在 macOS 执行，不能以 Windows Go 测试代替。

没有改动 sing-tun/Mihomo 数据面 UDP worker。仍需在真机跨 50–100 次真实
TUN Start/Stop 测量其基线，证实残留后才考虑 reset hook。
真机还需回归弱网、5G→4G、锁屏、App 划掉、Provider 刷新、12 路 IPC、
解锁检测及排行榜，并按同配置连续运行 48–72 小时完成性能和稳定性验收。

判断手动释放效果时应看 `heapIdle - heapReleased` 和闲置 pool；没有可回收
对象时，物理内存基本不变是允许的，不能以固定 MB 数值判断优化成功。
