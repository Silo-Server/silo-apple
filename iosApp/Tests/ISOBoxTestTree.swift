import Foundation

/// Synthetic box-tree builders shared by the ISO box surgery suites.
enum ISOBoxTestTree {

    static func box(_ type: String, _ payload: Data) -> Data {
        var out = Data()
        let size = UInt32(8 + payload.count)
        out.append(contentsOf: [
            UInt8((size >> 24) & 0xFF), UInt8((size >> 16) & 0xFF),
            UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF),
        ])
        out.append(type.data(using: .ascii)!)
        out.append(payload)
        return out
    }

    static func hdlr(_ handler: String) -> Data {
        var payload = Data(count: 8)  // FullBox version/flags + pre_defined
        payload.append(handler.data(using: .ascii)!)
        payload.append(0)  // empty name
        return box("hdlr", payload)
    }

    static func trak(handler: String, stblChildren: Data) -> Data {
        let stbl = box("stbl", stblChildren)
        let minf = box("minf", stbl)
        let mdia = box("mdia", hdlr(handler) + minf)
        return box("trak", mdia)
    }
}
