import WGCNE

final class PacketTunnelProvider: WGCPacketTunnelProvider {
    override func makeCoreEngine() throws -> CoreEngine {
        try WGCCoreEngine()
    }
}
