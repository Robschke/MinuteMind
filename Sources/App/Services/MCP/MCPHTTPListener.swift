// Purpose: MCPHTTPListener, a minimal HTTP/1.1 listener on the loopback interface that hands
//          each request to the MCP transport and writes its response back.
// Dependencies: Network.framework (NWListener), MCP SDK (HTTPRequest / HTTPResponse types)
// Used by: Sources/App/Services/MCP/MinuteMindMCPServer.swift
// Notes: The MCP SDK's HTTP transports are framework agnostic and ship no socket server, so this
//        fills that gap without pulling in Vapor or Hummingbird. It is deliberately small: one
//        request per connection (Connection: close), Content-Length bodies only, no chunked
//        uploads and no SSE, which is all the stateless transport needs. Binding to 127.0.0.1
//        keeps it unreachable from other machines; auth and DNS-rebinding checks live in the
//        transport's validation pipeline, not here.

import Foundation
import MCP
import Network

final class MCPHTTPListener: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    enum State: Equatable, Sendable {
        case ready
        case failed(String)
        case stopped
    }

    /// Requests larger than this are rejected before the body is read.
    private static let maxBodyBytes = 8 * 1024 * 1024

    private let port: UInt16
    private let handler: Handler
    private let queue = DispatchQueue(label: "minutemind.mcp.http")
    private var listener: NWListener?

    init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    /// Starts listening. `onStateChange` is called on an internal queue.
    func start(onStateChange: @escaping @Sendable (State) -> Void) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "MCPHTTPListener", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"])
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)

        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: onStateChange(.ready)
            case .failed(let error): onStateChange(.failed(error.localizedDescription))
            case .cancelled: onStateChange(.stopped)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }

            switch Self.parse(buffer) {
            case .complete(let request):
                self.respond(to: request, on: connection)
            case .tooLarge:
                self.write(status: 413, headers: [:], body: nil, on: connection)
            case .malformed:
                self.write(status: 400, headers: [:], body: nil, on: connection)
            case .incomplete:
                if error != nil || isComplete {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        let handler = self.handler
        Task {
            let response = await handler(request)
            var body = response.bodyData
            if case .stream(let stream, _) = response {
                // The stateless transport never streams; drain defensively if it ever does.
                var collected = Data()
                do { for try await chunk in stream { collected.append(chunk) } } catch {}
                body = collected
            }
            self.write(status: response.statusCode, headers: response.headers, body: body, on: connection)
        }
    }

    private func write(status: Int, headers: [String: String], body: Data?, on connection: NWConnection) {
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        var allHeaders = headers
        allHeaders["Content-Length"] = String(body?.count ?? 0)
        allHeaders["Connection"] = "close"
        for (name, value) in allHeaders { head += "\(name): \(value)\r\n" }
        head += "\r\n"

        var payload = Data(head.utf8)
        if let body { payload.append(body) }
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Parsing

    private enum ParseResult {
        case incomplete
        case complete(HTTPRequest)
        case malformed
        case tooLarge
    }

    private static func parse(_ buffer: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else {
            return buffer.count > 64 * 1024 ? .tooLarge : .incomplete
        }
        guard let headerText = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
            return .malformed
        }
        var lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .malformed }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLength = headers.first { $0.key.lowercased() == "content-length" }
            .flatMap { Int($0.value) } ?? 0
        if contentLength > maxBodyBytes { return .tooLarge }

        let bodyStart = headerEnd.upperBound
        guard buffer.count - bodyStart >= contentLength else { return .incomplete }
        let body = contentLength > 0 ? Data(buffer[bodyStart..<(bodyStart + contentLength)]) : nil

        let path = String(requestLine[1]).components(separatedBy: "?").first
        return .complete(HTTPRequest(method: String(requestLine[0]), headers: headers, body: body, path: path))
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 406: return "Not Acceptable"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 421: return "Misdirected Request"
        default: return "Status"
        }
    }
}
