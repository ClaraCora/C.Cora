import Foundation
import NetworkExtension
import MeowCore
import Darwin

/// One readPackets request at a time, including across a controlled restart.
/// A pending Apple callback cannot inject into a stopped native generation.
final class PacketFlowPump {
    private let queue = DispatchQueue(label: "com.cora.tunnel.packets", qos: .userInteractive)
    private let flow: NEPacketTunnelFlow
    private var enabled = false
    private var outstanding = false
    init(flow: NEPacketTunnelFlow) { self.flow = flow }
    func start() { queue.sync { enabled = true; readNext() } }
    func stop() { queue.sync { enabled = false } }
    private func readNext() {
        guard enabled, !outstanding else { return }
        outstanding = true
        flow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            self.queue.async {
                self.outstanding = false
                if self.enabled {
                    for packet in packets {
                        packet.withUnsafeBytes { bytes in
                            _ = meow_tun_ingest(bytes.bindMemory(to: UInt8.self).baseAddress, UInt(packet.count))
                        }
                    }
                    self.readNext()
                }
            }
        }
    }
}

/// Retained by the lifecycle owner until blocking native stop has joined every
/// callback. Rust never owns or releases the Swift context.
final class PacketFlowWriter {
    private let flow: NEPacketTunnelFlow
    init(flow: NEPacketTunnelFlow) { self.flow = flow }
    /// Rust 按批交付出口包：整批合并成一次 writePackets，避免按包调用在高吞吐下堆积出口队列。
    func writeBatch(packets: UnsafePointer<UnsafePointer<UInt8>?>, lens: UnsafePointer<UInt>, count: Int) {
        guard count > 0, count <= 256 else { return }
        var datas: [Data] = []
        var protocols: [NSNumber] = []
        datas.reserveCapacity(count)
        protocols.reserveCapacity(count)
        for index in 0..<count {
            let length = Int(lens[index])
            guard let base = packets[index], length > 0, length <= 65535 else { continue }
            let version = base.pointee >> 4
            guard version == 4 || version == 6 else { continue }
            datas.append(Data(bytes: base, count: length))
            protocols.append(NSNumber(value: version == 6 ? AF_INET6 : AF_INET))
        }
        guard !datas.isEmpty else { return }
        _ = flow.writePackets(datas, withProtocols: protocols)
    }
}

let coraWritePacket: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UnsafePointer<UInt8>?>?, UnsafePointer<UInt>?, UInt) -> Void = { context, packets, lens, count in
    guard let context, let packets, let lens, count > 0 else { return }
    Unmanaged<PacketFlowWriter>.fromOpaque(context).takeUnretainedValue()
        .writeBatch(packets: packets, lens: lens, count: Int(count))
}
