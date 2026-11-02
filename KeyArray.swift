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
