import Foundation
import Network

// A deliberately small HTTP/1.1 server on the Network framework — enough for
// PaxxMaker-Connect's handful of routes (JSON in/out, one raw upload, one file
// download) without pulling in a web framework. Announces itself via Bonjour
// through the listener's own service registration.

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data
}

struct HTTPResponse {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()

    static func json(_ obj: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
    }
    static func text(_ s: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(s.utf8))
    }
}

final class HTTPServer {
    typealias Handler = (HTTPRequest) -> HTTPResponse
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "paxx.http", attributes: .concurrent)
    let port: UInt16
    let handler: Handler
    private(set) var running = false

    init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    func start(serviceName: String, txt: [String: String]) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        // Bonjour: the same _paxxconnect._tcp the phone browses for.
        l.service = NWListener.Service(name: serviceName, type: "_paxxconnect._tcp", domain: nil, txtRecord: NWTXTRecord(txt))
        l.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
        l.stateUpdateHandler = { [weak self] st in
            if case .ready = st { self?.running = true }
            if case .failed = st { self?.running = false }
            if case .cancelled = st { self?.running = false }
        }
        l.start(queue: queue)
        listener = l
    }

    func stop() { listener?.cancel(); listener = nil; running = false }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        var buffer = Data()
        func readMore() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data { buffer.append(data) }
                if let req = self.parse(buffer) {
                    let resp = self.handler(req)
                    self.send(resp, on: conn, keepAlive: false)
                    return
                }
                if isComplete || error != nil { conn.cancel(); return }
                readMore()
            }
        }
        readMore()
    }

    /// Returns a request once head + full body (per Content-Length) are in.
    private func parse(_ buf: Data) -> HTTPRequest? {
        guard let headEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[buf.startIndex..<headEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        lines.removeFirst()
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            if let i = l.firstIndex(of: ":") {
                headers[String(l[..<i]).lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headEnd.upperBound
        guard buf.count - bodyStart >= length else { return nil }
        let body = buf[bodyStart..<(bodyStart + length)]
        let target = String(parts[1])
        var path = target, query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            for pair in target[target.index(after: q)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if kv.count == 2 { query[kv[0]] = kv[1] } else if kv.count == 1 { query[kv[0]] = "" }
            }
        }
        return HTTPRequest(method: String(parts[0]), path: path, query: query, headers: headers, body: Data(body))
    }

    private func send(_ r: HTTPResponse, on conn: NWConnection, keepAlive: Bool) {
        let reason: [Int: String] = [200: "OK", 201: "Created", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized",
                                     404: "Not Found", 409: "Conflict", 500: "Internal Server Error"]
        var head = "HTTP/1.1 \(r.status) \(reason[r.status] ?? "OK")\r\n"
        var hs = r.headers
        hs["Content-Length"] = "\(r.body.count)"
        hs["Connection"] = "close"
        hs["Server"] = "PaxxMakerConnect"
        for (k, v) in hs { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8); out.append(r.body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}
