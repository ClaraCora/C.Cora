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
    func write(_ bytes: UnsafePointer<UInt8>, count: Int) {
        guard count > 0, count <= 65535 else { return }
        let version = bytes.pointee >> 4
        guard version == 4 || version == 6 else { return }
        let packet = Data(bytes: bytes, count: count)
        _ = flow.writePackets([packet], withProtocols: [NSNumber(value: version == 6 ? AF_INET6 : AF_INET)])
    }
}

let coraWritePacket: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, UInt) -> Void = { context, bytes, length in
    guard let context, let bytes else { return }
    Unmanaged<PacketFlowWriter>.fromOpaque(context).takeUnretainedValue().write(bytes, count: Int(length))
}
