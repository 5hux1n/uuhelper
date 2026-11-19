import Foundation

// Swift owns the native Array<Int> until the protocol witness call returns.
typealias UUKeySinkCallback = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
    UInt8, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Void

@_cdecl("uu_send_key_array")
func uuSendKeyArray(_ codes: UnsafePointer<UInt8>?, _ count: Int,
                    _ function: UnsafeMutableRawPointer?, _ sink: UnsafeMutableRawPointer?,
                    _ type: UnsafeMutableRawPointer?, _ witness: UnsafeMutableRawPointer?,
                    _ callback: UUKeySinkCallback?) -> Bool {
    guard let codes = codes, count > 0, count <= 8,
          let function = function, let sink = sink, let type = type,
          let witness = witness, let callback = callback,
          MemoryLayout<[Int]>.size == MemoryLayout<UnsafeMutableRawPointer>.size else { return false }
    let keys = UnsafeBufferPointer(start: codes, count: count).map(Int.init)
    return withExtendedLifetime(keys) {
        callback(function, sink, unsafeBitCast(keys, to: UnsafeMutableRawPointer.self), 2, type, witness)
        return true
    }
}

typealias UUWheelPacketCallback = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int
) -> Bool

@_silgen_name("uuss_build_wheel_packet")
private func uuBuildWheelPacket(_ function: UnsafeMutableRawPointer, _ delta: Int64) -> String?

@_cdecl("uu_send_wheel_packet")
func uuSendWheelPacket(_ function: UnsafeMutableRawPointer?, _ delta: Int64,
                       _ context: UnsafeMutableRawPointer?, _ callback: UUWheelPacketCallback?) -> Bool {
    guard let function = function, let context = context, let callback = callback else { return false }
    guard let packet = uuBuildWheelPacket(function, delta), !packet.isEmpty else { return false }
    let object = packet as NSString
    return withExtendedLifetime(object) {
        callback(context, Unmanaged.passUnretained(object).toOpaque(), packet.count)
    }
}
