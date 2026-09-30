import Foundation

// Both HAL APIs return byte counts. Validate them before interpreting data as
// object IDs or flags; device lists can change between the size and data reads.
protocol HardwarePropertyClient {
    func dataSize(object: UInt32, selector: UInt32, scope: UInt32) -> UInt32?
    func read(object: UInt32, selector: UInt32, scope: UInt32,
              into buffer: UnsafeMutableRawBufferPointer) -> UInt32?
}

extension HardwarePropertyClient {
    func objectIDs(object: UInt32, selector: UInt32, scope: UInt32) -> [UInt32] {
        let stride = MemoryLayout<UInt32>.stride
        guard let capacity = dataSize(object: object, selector: selector, scope: scope),
              capacity > 0, Int(capacity) % stride == 0 else { return [] }
        var values = [UInt32](repeating: 0, count: Int(capacity) / stride)
        let used = values.withUnsafeMutableBytes {
            read(object: object, selector: selector, scope: scope, into: $0)
        }
        guard let used, used <= capacity, Int(used) % stride == 0 else { return [] }
        return Array(values.prefix(Int(used) / stride)).filter { $0 != 0 }
    }

    func uint32(object: UInt32, selector: UInt32, scope: UInt32) -> UInt32? {
        var value: UInt32 = 0
        let used = withUnsafeMutableBytes(of: &value) {
            read(object: object, selector: selector, scope: scope, into: $0)
        }
        guard used == UInt32(MemoryLayout<UInt32>.size) else { return nil }
        return value
    }
}
