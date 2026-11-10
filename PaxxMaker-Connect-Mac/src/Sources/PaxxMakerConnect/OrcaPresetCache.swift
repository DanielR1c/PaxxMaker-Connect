import Foundation

// Reader for OrcaSlicer's preset cache files (<vendor>.opc), the form in
// which OrcaSlicer 2.5 ships its system profiles instead of JSON files.
// Format (OrcaSlicer src/libslic3r/PresetCacheFormat.cpp, CACHE_VERSION 2):
// a 20-byte header (magic "ZCRO", version, body size, CRC-32) and a cereal
// binary body — stamps, an option dictionary, the vendor map, then the
// process, filament and machine presets, each as its own diff plus
// inherits/includes. Values come out as the text a JSON profile carries.

enum OrcaPresetCache {
    struct Entry {
        var kind: String              // "process" / "filament" / "machine"
        var name: String
        var values: [String: Any]     // the preset's own diff, JSON-profile style
        var inherits: String
        var includes: [String]
        var instantiation: String
        var settingID: String
        var filamentID: String
    }

    enum ReadError: Error { case format(String) }

    /// Every preset in one cache file; nil when it is not a cache this reader knows.
    static func read(_ url: URL) -> [Entry]? {
        guard let data = try? Data(contentsOf: url), data.count > 20 else { return nil }
        var r = Reader(data)
        do {
            guard try r.u32() == 0x4F52435A else { return nil }       // "ZCRO" on disk
            _ = try r.u32()                                           // file format version
            let size = try r.u64()
            _ = try r.u32()                                           // CRC
            guard size == UInt64(data.count - 20) else { return nil }
            guard try r.u32() == 2 else { return nil }                // CACHE_VERSION
            _ = try r.string(); _ = try r.string()                    // vendor name, version
            // Dictionary: keys, the type each was written as, enum names.
            let keys = try r.strings()
            let tn = try r.u64()
            var types: [UInt16] = []
            for _ in 0..<tn { types.append(try r.u16()) }
            let enums = try r.strings()
            guard keys.count == types.count else { return nil }
            try skipVendors(&r)
            var out: [Entry] = []
            for kind in ["process", "filament", "machine"] {
                let n = try r.u32()
                for _ in 0..<n {
                    let name = try r.string()
                    _ = try r.string()                                // sub_path
                    var values: [String: Any] = [:]
                    let cnt = try r.u32()
                    for _ in 0..<cnt {
                        let idx = Int(try r.u16())
                        guard idx < keys.count else { throw ReadError.format("key index") }
                        if let v = try value(&r, type: types[idx], enums: enums) { values[keys[idx]] = v }
                    }
                    let inherits = try r.string()
                    let includes = try r.strings()
                    _ = try r.string()                                // description
                    let inst = try r.string()
                    let sid = try r.string()
                    let fid = try r.string()
                    _ = try r.strings()                               // renamed_from
                    out.append(Entry(kind: kind, name: name, values: values, inherits: inherits, includes: includes,
                                     instantiation: inst, settingID: sid, filamentID: fid))
                }
            }
            return out
        } catch {
            return nil
        }
    }

    // MARK: values

    private static let vector: UInt16 = 0x4000

    /// One option as JSON-profile text: a string, or an array of strings for a vector.
    private static func value(_ r: inout Reader, type: UInt16, enums: [String]) throws -> Any? {
        let isVec = type & vector != 0
        switch type & ~vector {
        case 1:  // float(s)
            return isVec ? try (0..<r.u64()).map { _ in num(try r.f64(), nilIfNaN: true) } : num(try r.f64())
        case 2:  // int(s)
            if isVec { let n = try r.u64(); return try (0..<n).map { _ in int(try r.i32()) } }
            return int(try r.i32())
        case 3:  // string(s)
            return isVec ? try r.strings() : try r.string()
        case 4:  // percent(s)
            if isVec { let n = try r.u64(); return try (0..<n).map { _ in pct(try r.f64()) } }
            return pct(try r.f64())
        case 5:  // float-or-percent(s)
            if isVec {
                let n = try r.u64()
                return try (0..<n).map { _ in let v = try r.f64(); let p = try r.bool(); return p ? pct(v) : num(v, nilIfNaN: true) }
            }
            let v = try r.f64(); let p = try r.bool()
            return p ? pct(v) : num(v)
        case 6:  // point(s)
            if isVec { let n = try r.u64(); return try (0..<n).map { _ in try point(&r) } }
            return try point(&r)
        case 7:  // point3
            let x = try r.f64(), y = try r.f64(), z = try r.f64()
            return "\(num(x))x\(num(y))x\(num(z))"
        case 8:  // bool(s)
            if isVec { let n = try r.u64(); return try (0..<n).map { _ in let b = try r.u8(); return b == 255 ? "nil" : (b != 0 ? "1" : "0") } }
            return try r.bool() ? "1" : "0"
        case 9:  // enum(s), by name
            let n = try r.u32()
            var names: [String] = []
            for _ in 0..<n {
                let idx = Int(try r.u16())
                guard idx < enums.count else { throw ReadError.format("enum index") }
                if idx == 0 { let raw = try r.i32(); names.append(raw == Int32.max ? "nil" : String(raw)) }
                else { names.append(enums[idx]) }
            }
            return isVec ? names : (names.first ?? "")
        case 10: // points groups: vector of vector of Vec2d
            let n = try r.u64()
            return try (0..<n).map { _ -> String in
                let m = try r.u64()
                return try (0..<m).map { _ in try point(&r) }.joined(separator: ",")
            }
        case 11: // ints groups: vector of vector of int
            let n = try r.u64()
            return try (0..<n).map { _ -> String in
                let m = try r.u64()
                return try (0..<m).map { _ in int(try r.i32()) }.joined(separator: ",")
            }
        default:
            throw ReadError.format("type \(type)")
        }
    }

    private static func point(_ r: inout Reader) throws -> String {
        let x = try r.f64(), y = try r.f64()
        return "\(num(x))x\(num(y))"
    }

    /// Like Orca writes numbers: no trailing ".0", up to 15 significant digits.
    static func num(_ v: Double, nilIfNaN: Bool = false) -> String {
        if v.isNaN { return nilIfNaN ? "nil" : "0" }
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return String(format: "%.15g", v)
    }
    private static func pct(_ v: Double) -> String { v.isNaN ? "nil" : num(v) + "%" }
    private static func int(_ v: Int32) -> String { v == Int32.max ? "nil" : String(v) }

    // MARK: vendor map (skipped — only its length matters)

    private static func skipVendors(_ r: inout Reader) throws {
        let n = try r.u64()
        for _ in 0..<n {
            _ = try r.string()                                        // map key
            for _ in 0..<5 { _ = try r.string() }                     // name, id, version, update url, changelog url
            let models = try r.u64()
            for _ in 0..<models {
                for _ in 0..<3 { _ = try r.string() }                 // id, name, model_id
                _ = try r.u8()                                        // technology
                _ = try r.string()                                    // family
                _ = try r.strings()                                   // variants (each just a name)
                _ = try r.strings(); _ = try r.strings()              // default_materials, not_support_bed_types
                for _ in 0..<9 { _ = try r.string() }                 // bed model … hotend model
            }
            _ = try r.strings(); _ = try r.strings()                  // default_filaments, default_sla_materials
        }
    }

    // MARK: cereal binary primitives (little endian, 64-bit sizes)

    struct Reader {
        let d: Data
        var p: Int
        init(_ d: Data) { self.d = d; self.p = d.startIndex }
        mutating func take(_ n: Int) throws -> Data {
            guard n >= 0, p + n <= d.endIndex else { throw ReadError.format("past end") }
            defer { p += n }
            return d[p..<(p + n)]
        }
        mutating func u8() throws -> UInt8 { try take(1).first! }
        mutating func bool() throws -> Bool { try u8() != 0 }
        mutating func u16() throws -> UInt16 { let b = try take(2); return UInt16(b[b.startIndex]) | UInt16(b[b.startIndex + 1]) << 8 }
        mutating func u32() throws -> UInt32 { try take(4).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
        mutating func u64() throws -> UInt64 { try take(8).enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * $1.offset) } }
        mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
        mutating func f64() throws -> Double { Double(bitPattern: try u64()) }
        mutating func string() throws -> String {
            let n = try u64()
            guard n < 50_000_000 else { throw ReadError.format("string length") }
            return String(decoding: try take(Int(n)), as: UTF8.self)
        }
        mutating func strings() throws -> [String] {
            let n = try u64()
            guard n < 1_000_000 else { throw ReadError.format("list length") }
            return try (0..<n).map { _ in try string() }
        }
    }
}
