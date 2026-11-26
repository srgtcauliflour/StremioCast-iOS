import Foundation
import Network
import Darwin

/// A short-lived, capability-protected HTTP bridge for a single iPhone-local stream.
/// It exposes no general proxy endpoint: every request is pinned to one source URL.
final class CastLANRelay: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.stremiocast.lan-relay", qos: .utility)
    private let lock = NSLock()
    private var valid = false
    private var revoked = false
    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]
    private var expiry: DispatchWorkItem?
    private let token: String
    private let source: URL
    private let headers: [String: String]
    private var startup: ((Result<URL, Error>) -> Void)?
    private var host = ""

    init(source: URL, headers: [String: String]) throws {
        guard Self.isLoopback(source), source.scheme?.lowercased() == "http" else {
            throw RelayError.unsupportedSource
        }
        self.source = source
        self.headers = Self.safeHeaders(headers)
        var generator = SystemRandomNumberGenerator()
        token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    enum RelayError: LocalizedError {
        case unsupportedSource, unavailable
        var errorDescription: String? {
            switch self {
            case .unsupportedSource: return "This local stream cannot be shared with Chromecast."
            case .unavailable: return "Could not open a temporary Wi-Fi stream bridge. Check local-network permission and try again."
            }
        }
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    private static func safeHeaders(_ input: [String: String]) -> [String: String] {
        var output: [String: String] = [:]
        for (name, value) in input {
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = key.lowercased()
            guard !key.isEmpty, key.utf8.allSatisfy({ (33...126).contains($0) && $0 != 58 }),
                  !value.contains("\r"), !value.contains("\n"),
                  !["host", "connection", "content-length", "transfer-encoding", "range", "accept-encoding"].contains(lower) else { continue }
            output[key] = value
        }
        return output
    }

    private var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    private func setValid(_ value: Bool) { lock.lock(); valid = value && !revoked; lock.unlock() }
    private func revoke() { lock.lock(); valid = false; revoked = true; lock.unlock() }

    func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !self.revoked, self.listener == nil, let address = Self.wifiIPv4() else {
                        continuation.resume(throwing: RelayError.unavailable); return
                    }
                    self.host = address
                    self.startup = { continuation.resume(with: $0) }
                    do {
                        let parameters = NWParameters.tcp
                        parameters.requiredInterfaceType = .wifi
                        parameters.includePeerToPeer = false
                        let listener = try NWListener(using: parameters, on: .any)
                        self.listener = listener
                        self.setValid(true)
                        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                        listener.stateUpdateHandler = { [weak self] state in
                            guard let self else { return }
                            switch state {
                            case .ready:
                                guard let port = listener.port,
                                      let url = URL(string: "http://\(self.host):\(port.rawValue)/cast/\(self.token)/media"),
                                      self.isValid else { self.close(); return }
                                self.finishStartup(.success(url))
                            case .failed:
                                self.finishStartup(.failure(RelayError.unavailable)); self.close()
                            case .cancelled:
                                self.finishStartup(.failure(RelayError.unavailable))
                            default: break
                            }
                        }
                        listener.start(queue: self.queue)
                        self.queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                            guard let self, self.startup != nil else { return }
                            self.finishStartup(.failure(RelayError.unavailable)); self.close()
                        }
                        let expiry = DispatchWorkItem { [weak self] in self?.close() }
                        self.expiry = expiry
                        self.queue.asyncAfter(deadline: .now() + 6 * 60 * 60, execute: expiry)
                    } catch {
                        self.finishStartup(.failure(RelayError.unavailable)); self.close()
                    }
                }
            }
        } onCancel: { self.stop() }
    }

    func stop() {
        revoke()
        queue.async { self.close() }
    }

    private func finishStartup(_ result: Result<URL, Error>) {
        let callback = startup
        startup = nil
        callback?(result)
    }

    private func close() {
        revoke()
        finishStartup(.failure(RelayError.unavailable))
        expiry?.cancel(); expiry = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        let active = Array(clients.values)
        clients.removeAll()
        active.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        guard isValid, clients.count < 4 else { connection.cancel(); return }
        let id = UUID()
        let client = Client(connection: connection, queue: queue, token: token, source: source,
                            headers: headers, valid: { [weak self] in self?.isValid == true },
                            finished: { [weak self] in self?.clients.removeValue(forKey: id) })
        clients[id] = client
        client.start()
    }

    private static func wifiIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var cursor = list
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let item = current.pointee
            guard String(cString: item.ifa_name) == "en0",
                  item.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = item.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer,
                              socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if host.hasPrefix("10.") || host.hasPrefix("192.168.") ||
                (host.hasPrefix("172.") && (Int(host.split(separator: ".").dropFirst().first ?? "") ?? 0) >= 16 &&
                 (Int(host.split(separator: ".").dropFirst().first ?? "") ?? 0) <= 31) {
                return host
            }
        }
        return nil
    }

    private final class Client: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let connection: NWConnection
        let queue: DispatchQueue
        let token: String
        let source: URL
        let headers: [String: String]
        let valid: () -> Bool
        let finished: () -> Void
        var requestBytes = Data()
        var session: URLSession?
        var task: URLSessionDataTask?
        var method = "GET"
        var headersSent = false
        var rejecting = false
        var closed = false
        var pendingSends = 0
        var upstreamFinished = false
        var headerDeadline: DispatchWorkItem?

        init(connection: NWConnection, queue: DispatchQueue, token: String, source: URL,
             headers: [String: String], valid: @escaping () -> Bool, finished: @escaping () -> Void) {
            self.connection = connection; self.queue = queue; self.token = token; self.source = source
            self.headers = headers; self.valid = valid; self.finished = finished
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.cancel() }
                if case .cancelled = state { self?.cancel() }
            }
            connection.start(queue: queue)
            let timeout = DispatchWorkItem { [weak self] in self?.cancel() }
            headerDeadline = timeout
            queue.asyncAfter(deadline: .now() + 10, execute: timeout)
            receive()
        }

        func receive() {
            guard !closed, valid(), requestBytes.count < 8192 else { reject(); return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: min(4096, 8192 - requestBytes.count)) { [weak self] data, _, done, error in
                guard let self, !self.closed else { return }
                if let data { self.requestBytes.append(data) }
                if let delimiter = self.requestBytes.range(of: Data("\r\n\r\n".utf8)) {
                    guard delimiter.upperBound == self.requestBytes.endIndex,
                          let text = String(data: self.requestBytes, encoding: .utf8),
                          let range = self.parse(text), self.valid() else { self.reject(); return }
                    self.headerDeadline?.cancel(); self.headerDeadline = nil
                    self.open(range)
                } else if done || error != nil { self.cancel() } else { self.receive() }
            }
        }

        private func parse(_ raw: String) -> String? {
            let lines = raw.components(separatedBy: "\r\n")
            guard let first = lines.first else { return nil }
            let parts = first.split(separator: " ")
            guard parts.count == 3, let path = parts.dropFirst().first,
                  String(path) == "/cast/\(token)/media",
                  parts[0] == "GET" || parts[0] == "HEAD",
                  parts[2].hasPrefix("HTTP/1.") else { return nil }
            method = String(parts[0])
            var range: String?
            for line in lines.dropFirst() where !line.isEmpty {
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if name == "range" {
                    guard range == nil, value.hasPrefix("bytes="),
                          value.dropFirst(6).allSatisfy({ $0.isNumber || $0 == "-" || $0 == "," }) else { return nil }
                    range = value
                }
            }
            return range
        }

        func open(_ range: String?) {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 6 * 60 * 60
            let operations = OperationQueue()
            operations.maxConcurrentOperationCount = 1
            operations.underlyingQueue = queue
            let session = URLSession(configuration: config, delegate: self, delegateQueue: operations)
            self.session = session
            var upstream = URLRequest(url: source)
            upstream.httpMethod = method
            upstream.cachePolicy = .reloadIgnoringLocalCacheData
            upstream.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            for (name, value) in headers { upstream.setValue(value, forHTTPHeaderField: name) }
            if let range { upstream.setValue(range, forHTTPHeaderField: "Range") }
            let task = session.dataTask(with: upstream)
            self.task = task
            task.resume()
        }

        func reject() {
            guard !closed, !rejecting else { return }
            rejecting = true
            headerDeadline?.cancel(); headerDeadline = nil
            task?.cancel(); task = nil
            session?.invalidateAndCancel(); session = nil
            connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                            completion: .contentProcessed { [weak self] _ in self?.cancel() })
        }

        func cancel() {
            guard !closed else { return }
            closed = true
            headerDeadline?.cancel(); headerDeadline = nil
            task?.cancel(); task = nil
            session?.invalidateAndCancel(); session = nil
            connection.stateUpdateHandler = nil
            connection.cancel()
            finished()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            // Do not let a local service turn this one-source bridge into an arbitrary network proxy.
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            guard valid(), !closed, !rejecting, let http = response as? HTTPURLResponse,
                  http.url == source,
                  (200...299).contains(http.statusCode) || [301, 302, 303, 307, 308, 400, 401, 403, 404, 416, 500, 502, 503].contains(http.statusCode),
                  http.value(forHTTPHeaderField: "Content-Length").map({ UInt64($0) != nil }) ?? true else {
                reject(); completionHandler(.cancel); return
            }
            // Redirects are denied above; surface the status instead of following to an unpinned host.
            let reason = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            var responseText = "HTTP/1.1 \(http.statusCode) \(reason)\r\nConnection: close\r\n"
            for name in ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "Last-Modified", "ETag"] {
                if let value = http.value(forHTTPHeaderField: name), !value.contains("\r"), !value.contains("\n") {
                    responseText += "\(name): \(value)\r\n"
                }
            }
            responseText += "\r\n"
            headersSent = true
            connection.send(content: Data(responseText.utf8), completion: .contentProcessed { [weak self] error in
                guard let self, !self.closed, self.valid(), error == nil else {
                    completionHandler(.cancel); self?.cancel(); return
                }
                completionHandler(self.method == "HEAD" || [204, 304, 301, 302, 303, 307, 308].contains(http.statusCode) ? .cancel : .allow)
                if self.method == "HEAD" || [204, 304, 301, 302, 303, 307, 308].contains(http.statusCode) { self.cancel() }
            })
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard !closed, !rejecting, headersSent else { return }
            guard valid() else { cancel(); return }
            dataTask.suspend()
            pendingSends += 1
            connection.send(content: data, completion: .contentProcessed { [weak self, weak dataTask] error in
                guard let self, !self.closed else { return }
                self.pendingSends -= 1
                if error != nil || !self.valid() { self.cancel(); return }
                dataTask?.resume()
                if self.upstreamFinished && self.pendingSends == 0 { self.cancel() }
            })
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard !closed, !rejecting else { return }
            upstreamFinished = true
            if !headersSent { reject() }
            else if error != nil || pendingSends == 0 { cancel() }
        }
    }
}
