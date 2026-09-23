import Foundation
import Compression

// Writes a plain 3MF (core spec) from STL meshes with one transform per
// object — the way the phone's placement reaches Orca exactly, since the CLI
// has no flag for a free position. The head per object goes into
// Metadata/model_settings.config and painted faces into Orca's paint_color
// triangle attribute, which is how Orca's own projects carry colour
// painting. Includes just enough ZIP to do it (deflate via the Compression
// framework, CRC-32 by hand).

enum ThreeMF {
    struct Object {
        var name: String
        var stl: Data
        var transform: [Double]
        var extruder: Int?
        /// Orca's paint_color string per triangle index (same order as the
        /// STL): the phone serialises its subdivision tree exactly like
        /// TriangleSelector::serialize, so Orca reads it as its own painting.
        var paint: [Int: String] = [:]
        /// The object's own process settings (Orca keys and value spellings),
        /// written as metadata like Orca's per-object overrides.
        var settings: [String: String] = [:]
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// STL → deduplicated vertices + index triples.
    static func readSTL(_ data: Data) -> ([SIMD3<Float>], [(Int, Int, Int)]) {
        var verts: [SIMD3<Float>] = []
        var tris: [(Int, Int, Int)] = []
        var index: [SIMD3<Float>: Int] = [:]
        func vid(_ p: SIMD3<Float>) -> Int {
            let k = SIMD3<Float>((p.x * 1e5).rounded() / 1e5, (p.y * 1e5).rounded() / 1e5, (p.z * 1e5).rounded() / 1e5)
            if let i = index[k] { return i }
            let i = verts.count; index[k] = i; verts.append(k); return i
        }
        if data.count >= 84 {
            let n = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) }
            if data.count == 84 + Int(n) * 50 {
                data.withUnsafeBytes { raw in
                    var off = 84
                    for _ in 0..<Int(n) {
                        off += 12
                        var ids = [0, 0, 0]
                        for k in 0..<3 {
                            let x = raw.loadUnaligned(fromByteOffset: off, as: Float.self)
                            let y = raw.loadUnaligned(fromByteOffset: off + 4, as: Float.self)
                            let z = raw.loadUnaligned(fromByteOffset: off + 8, as: Float.self)
                            ids[k] = vid(SIMD3(x, y, z)); off += 12
                        }
                        off += 2
                        tris.append((ids[0], ids[1], ids[2]))
                    }
                }
                return (verts, tris)
            }
        }
        let text = String(decoding: data, as: UTF8.self)
        var cur: [Int] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("vertex") else { continue }
            let p = t.split(separator: " ", omittingEmptySubsequences: true)
            guard p.count >= 4, let x = Float(p[1]), let y = Float(p[2]), let z = Float(p[3]) else { continue }
            cur.append(vid(SIMD3(x, y, z)))
            if cur.count == 3 { tris.append((cur[0], cur[1], cur[2])); cur = [] }
        }
        return (verts, tris)
    }

    /// 3MF transform attribute from a column-major 4×4 (16 doubles).
    static func matrixAttr(_ m: [Double]) -> String {
        guard m.count == 16 else { return "1 0 0 0 1 0 0 0 1 0 0 0" }
        let v = [m[0], m[1], m[2], m[4], m[5], m[6], m[8], m[9], m[10], m[12], m[13], m[14]]
        return v.map { String(format: "%.6f", $0) }.joined(separator: " ")
    }

    static func build(_ objects: [Object]) -> Data {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<model unit=\"millimeter\" xml:lang=\"en-US\" xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\"><resources>"
        var items = ""
        var settings = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<config>\n"
        for (i, o) in objects.enumerated() {
            let id = i + 1
            let (verts, tris) = readSTL(o.stl)
            let name = o.name.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "&", with: "+").replacingOccurrences(of: "<", with: "")
            xml += "<object id=\"\(id)\" name=\"\(name)\" type=\"model\"><mesh><vertices>"
            xml.reserveCapacity(xml.count + verts.count * 40 + tris.count * 30)
            for v in verts { xml += String(format: "<vertex x=\"%.5f\" y=\"%.5f\" z=\"%.5f\"/>", v.x, v.y, v.z) }
            xml += "</vertices><triangles>"
            for (ti, t) in tris.enumerated() {
                if let code = o.paint[ti], !code.isEmpty, code.allSatisfy({ $0.isHexDigit }) {
                    xml += "<triangle v1=\"\(t.0)\" v2=\"\(t.1)\" v3=\"\(t.2)\" paint_color=\"\(code)\"/>"
                } else {
                    xml += "<triangle v1=\"\(t.0)\" v2=\"\(t.1)\" v3=\"\(t.2)\"/>"
                }
            }
            xml += "</triangles></mesh></object>"
            items += "<item objectid=\"\(id)\" transform=\"\(matrixAttr(o.transform))\"/>"
            settings += "  <object id=\"\(id)\">\n    <metadata key=\"name\" value=\"\(name)\"/>\n    <metadata key=\"extruder\" value=\"\(max(1, o.extruder ?? 1))\"/>\n"
            for (k, v) in o.settings.sorted(by: { $0.key < $1.key }) where k.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                settings += "    <metadata key=\"\(k)\" value=\"\(xmlEscape(v))\"/>\n"
            }
            settings += "  </object>\n"
        }
        settings += "</config>\n"
        xml += "</resources><build>\(items)</build></model>"
        let types = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"model\" ContentType=\"application/vnd.ms-package.3dmanufacturing-3dmodel+xml\"/></Types>"
        let rels = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Target=\"/3D/3dmodel.model\" Id=\"rel0\" Type=\"http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel\"/></Relationships>"
        return ZipWriter.archive([("[Content_Types].xml", Data(types.utf8)), ("_rels/.rels", Data(rels.utf8)),
                                  ("3D/3dmodel.model", Data(xml.utf8)), ("Metadata/model_settings.config", Data(settings.utf8))])
    }
}

enum ZipWriter {
    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    /// Raw DEFLATE (what ZIP method 8 wants) via Apple's Compression framework.
    static func deflate(_ data: Data) -> Data? {
        let cap = data.count + 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { dst.deallocate() }
        let n = data.withUnsafeBytes { src -> Int in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(dst, cap, base, data.count, nil, COMPRESSION_ZLIB)
        }
        return n > 0 ? Data(bytes: dst, count: n) : nil
    }

    static func archive(_ entries: [(String, Data)]) -> Data {
        var out = Data()
        var central = Data()
        func le16(_ v: Int) -> Data { var x = UInt16(v); return Data(bytes: &x, count: 2) }
        func le32(_ v: UInt32) -> Data { var x = v; return Data(bytes: &x, count: 4) }
        for (name, raw) in entries {
            let deflated = deflate(raw)
            let method = deflated != nil && deflated!.count < raw.count ? 8 : 0
            let payload = method == 8 ? deflated! : raw
            let crc = crc32(raw)
            let nameData = Data(name.utf8)
            let offset = UInt32(out.count)
            out.append(le32(0x04034b50)); out.append(le16(20)); out.append(le16(0)); out.append(le16(method))
            out.append(le16(0)); out.append(le16(0))                       // time/date
            out.append(le32(crc)); out.append(le32(UInt32(payload.count))); out.append(le32(UInt32(raw.count)))
            out.append(le16(nameData.count)); out.append(le16(0))
            out.append(nameData); out.append(payload)
            central.append(le32(0x02014b50)); central.append(le16(20)); central.append(le16(20)); central.append(le16(0)); central.append(le16(method))
            central.append(le16(0)); central.append(le16(0))
            central.append(le32(crc)); central.append(le32(UInt32(payload.count))); central.append(le32(UInt32(raw.count)))
            central.append(le16(nameData.count)); central.append(le16(0)); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0)); central.append(le32(0)); central.append(le32(offset))
            central.append(nameData)
        }
        let cdStart = UInt32(out.count)
        out.append(central)
        out.append(le32(0x06054b50)); out.append(le16(0)); out.append(le16(0))
        out.append(le16(entries.count)); out.append(le16(entries.count))
        out.append(le32(UInt32(central.count))); out.append(le32(cdStart)); out.append(le16(0))
        return out
    }
}
