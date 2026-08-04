//
//  LocalSendService.swift
//  Knotch
//

import Foundation
import Network
import Defaults
import UniformTypeIdentifiers
import Darwin

struct LocalSendDeviceInfo: Identifiable, Hashable, Sendable {
    let id: String
    let alias: String
    let ip: String
    let port: Int
    let https: Bool
    let model: String?

    var baseURL: String { "\(https ? "https" : "http")://\(ip):\(port)" }
}

enum LocalSendServiceError: LocalizedError {
    case noDeviceSelected, noTransferableItems, invalidResponse
    case server(status: Int)
    case transferRejected

    var errorDescription: String? {
        switch self {
        case .noDeviceSelected: return "No LocalSend device selected"
        case .noTransferableItems: return "Nothing to send"
        case .invalidResponse: return "Invalid response from LocalSend peer"
        case .server(let status): return "LocalSend peer error (\(status))"
        case .transferRejected: return "Transfer was rejected by the recipient"
        }
    }
}

@MainActor
final class LocalSendService: NSObject, ObservableObject {
    static let shared = LocalSendService()

    @Published private(set) var devices: [LocalSendDeviceInfo] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSending = false
    @Published private(set) var sendProgress: Double = 0
    @Published var selectedDeviceID: String {
        didSet { Defaults[.localSendSelectedDeviceID] = selectedDeviceID }
    }

    private let multicastHost = "224.0.0.167"
    private let port: UInt16 = 53317
    private let fingerprint = "knotch.localsend.bridge"

    private var connectionGroup: NWConnectionGroup?
    private var registerListener: NWListener?
    private var announceTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var activeRefreshTask: Task<Void, Never>?
    private var refreshSessionID = UUID()
    private var discoveredByID: [String: (device: LocalSendDeviceInfo, lastSeen: Date)] = [:]
    private var recentProbeIPs: [String] = []
    private var knownPeerIPs: [String] = []
    private var isStarted = false

    private override init() {
        selectedDeviceID = Defaults[.localSendSelectedDeviceID]
        super.init()
    }

    // MARK: - Discovery

    func startDiscovery() {
        guard !isStarted else { return }
        isStarted = true
        startRegisterListener()

        do {
            let group = try NWMulticastGroup(for: [
                .hostPort(host: .init(multicastHost), port: .init(integerLiteral: port))
            ])
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            params.includePeerToPeer = true

            let connectionGroup = NWConnectionGroup(with: group, using: params)
            connectionGroup.setReceiveHandler(maximumMessageSize: 65_536) { [weak self] message, content, _ in
                guard let content, let self else { return }
                Task { @MainActor in self.handleIncoming(content: content, endpoint: message.remoteEndpoint) }
            }
            connectionGroup.stateUpdateHandler = { _ in }
            connectionGroup.start(queue: .global(qos: .utility))
            self.connectionGroup = connectionGroup

            sendAnnouncement()

            announceTask = Task { [weak self] in
                while let self, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    self.sendAnnouncement()
                }
            }
            cleanupTask = Task { [weak self] in
                while let self, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    self.cleanupStale()
                }
            }
        } catch {
            NSLog("LocalSend discovery start failed: \(error.localizedDescription)")
        }
    }

    /// Active discovery on top of passive multicast: multicast relies on peers
    /// receiving/joining the same group, which is often unreliable on macOS
    /// (VPNs, AP isolation, sandboxing). This probes candidate IPs directly via
    /// HTTP, falling back to a full subnet sweep if nothing turns up.
    func refreshDeviceScan() {
        activeRefreshTask?.cancel()
        startDiscovery()

        let sessionID = UUID()
        refreshSessionID = sessionID
        isRefreshing = true

        activeRefreshTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }

            let startedAt = Date()
            defer {
                if self.refreshSessionID == sessionID {
                    self.isRefreshing = false
                    self.activeRefreshTask = nil
                }
            }

            let burstDelays: [UInt64] = [100_000_000, 500_000_000, 2_000_000_000]
            for delay in burstDelays {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                self.sendAnnouncement()
            }

            guard !Task.isCancelled else { return }
            await self.probeNearbyDevicesDirectly(limit: 20, timeout: 0.14)

            guard !Task.isCancelled else { return }
            if !self.hasFreshDiscovery(since: startedAt),
               let localIP = self.ownIPv4Address() {
                await self.probeLocalSubnetLegacy(localIP: localIP, timeout: 0.12)
            }

            guard !Task.isCancelled else { return }
            self.pruneUnavailableDevices(since: startedAt)
        }
    }

    private func pruneUnavailableDevices(since date: Date) {
        let previousCount = discoveredByID.count
        discoveredByID = discoveredByID.filter { $0.value.lastSeen >= date }
        if discoveredByID.count != previousCount {
            refreshDevices()
        }
    }

    private func probeNearbyDevicesDirectly(limit: Int = 12, timeout: TimeInterval = 0.14) async {
        let port = Int(port)
        let candidates = candidateIPsForActiveProbe(limit: max(1, limit))
        guard !candidates.isEmpty else { return }
        let deadline = Date().addingTimeInterval(1.0)

        await withTaskGroup(of: LocalSendDeviceInfo?.self) { group in
            let maxConcurrent = 4
            var iterator = candidates.makeIterator()

            for _ in 0 ..< min(maxConcurrent, candidates.count) {
                guard let ip = iterator.next() else { break }
                group.addTask {
                    await Self.probeDeviceInfo(at: ip, port: port, timeout: 0.14)
                }
            }

            while let result = await group.next() {
                if Date() > deadline {
                    group.cancelAll()
                    return
                }

                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }

                if let device = result {
                    discoveredByID[device.id] = (device, Date())
                    rememberKnownPeerIP(device.ip)
                    rememberRecentProbeIP(device.ip)
                }

                if let ip = iterator.next() {
                    group.addTask {
                        await Self.probeDeviceInfo(at: ip, port: port, timeout: timeout)
                    }
                }
            }
        }

        refreshDevices()
    }

    private func candidateIPsForActiveProbe(limit: Int) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        if let selected = devices.first(where: { $0.id == selectedDeviceID })?.ip,
           seen.insert(selected).inserted {
            ordered.append(selected)
        }

        for ip in recentProbeIPs where seen.insert(ip).inserted {
            ordered.append(ip)
        }

        for ip in discoveredByID.values.map(\.device.ip) where seen.insert(ip).inserted {
            ordered.append(ip)
        }

        for ip in knownPeerIPs where seen.insert(ip).inserted {
            ordered.append(ip)
        }

        if ordered.count > limit {
            return Array(ordered.prefix(limit))
        }
        return ordered
    }

    private func probeLocalSubnetLegacy(localIP: String, timeout: TimeInterval) async {
        guard isValidIPv4(localIP) else { return }
        let parts = localIP.split(separator: ".")
        guard parts.count == 4 else { return }

        let prefix = parts.prefix(3).joined(separator: ".")
        let host = Int(parts[3]) ?? 0
        let candidates = (1 ... 254)
            .filter { $0 != host }
            .map { "\(prefix).\($0)" }

        await probeExactIPs(candidates, timeout: timeout, concurrency: 50)
    }

    private func probeExactIPs(_ ips: [String], timeout: TimeInterval, concurrency: Int) async {
        let port = Int(port)
        let unique = Array(NSOrderedSet(array: ips).compactMap { $0 as? String })
        guard !unique.isEmpty else { return }

        await withTaskGroup(of: LocalSendDeviceInfo?.self) { group in
            var iterator = unique.makeIterator()

            for _ in 0 ..< min(max(1, concurrency), unique.count) {
                guard let ip = iterator.next() else { break }
                group.addTask {
                    await Self.probeDeviceInfo(at: ip, port: port, timeout: timeout)
                }
            }

            while let result = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }

                if let device = result {
                    discoveredByID[device.id] = (device, Date())
                    rememberKnownPeerIP(device.ip)
                    rememberRecentProbeIP(device.ip)
                }

                if let ip = iterator.next() {
                    group.addTask {
                        await Self.probeDeviceInfo(at: ip, port: port, timeout: timeout)
                    }
                }
            }
        }

        refreshDevices()
    }

    private func hasFreshDiscovery(since date: Date) -> Bool {
        discoveredByID.values.contains { $0.lastSeen >= date }
    }

    private nonisolated static func probeDeviceInfo(at ip: String, port: Int, timeout: TimeInterval) async -> LocalSendDeviceInfo? {
        for scheme in ["http", "https"] {
            guard var components = URLComponents(string: "\(scheme)://\(ip):\(port)/api/localsend/v2/info") else { continue }
            components.queryItems = [URLQueryItem(name: "fingerprint", value: "knotch.localsend.bridge")]
            guard let url = components.url else { continue }

            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

            do {
                let (data, response) = try await probeSession.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200 ... 299).contains(http.statusCode),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let fingerprint = json["fingerprint"] as? String,
                      let alias = json["alias"] as? String,
                      fingerprint != "knotch.localsend.bridge"
                else {
                    continue
                }

                let usesHTTPS = (json["protocol"] as? String) == "https" || scheme == "https"
                return LocalSendDeviceInfo(
                    id: fingerprint,
                    alias: alias,
                    ip: ip,
                    port: (json["port"] as? Int) ?? port,
                    https: usesHTTPS,
                    model: json["deviceModel"] as? String
                )
            } catch {
                continue
            }
        }
        return nil
    }

    private nonisolated static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.2
        config.timeoutIntervalForResource = 0.2
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: LocalSendTLSDelegate(), delegateQueue: nil)
    }()

    private func rememberRecentProbeIP(_ ip: String) {
        guard isValidIPv4(ip) else { return }
        recentProbeIPs.removeAll { $0 == ip }
        recentProbeIPs.insert(ip, at: 0)
        if recentProbeIPs.count > 12 {
            recentProbeIPs = Array(recentProbeIPs.prefix(12))
        }
    }

    private func rememberKnownPeerIP(_ ip: String) {
        guard isValidIPv4(ip) else { return }
        knownPeerIPs.removeAll { $0 == ip }
        knownPeerIPs.insert(ip, at: 0)
        if knownPeerIPs.count > 48 {
            knownPeerIPs = Array(knownPeerIPs.prefix(48))
        }
    }

    private func ownIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }

            let family = current.pointee.ifa_addr.pointee.sa_family
            let flags = Int32(current.pointee.ifa_flags)
            guard family == UInt8(AF_INET),
                  (flags & IFF_UP) == IFF_UP,
                  (flags & IFF_LOOPBACK) == 0
            else { continue }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var addr = current.pointee.ifa_addr.pointee
            let result = getnameinfo(
                &addr,
                socklen_t(current.pointee.ifa_addr.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let ip = String(cString: hostBuffer)
            if isValidIPv4(ip) {
                return ip
            }
        }

        return nil
    }

    private func isValidIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }
        for p in parts {
            guard let v = Int(p), (0 ... 255).contains(v) else { return false }
        }
        return true
    }

    private func sendAnnouncement() {
        let payload: [String: Any] = [
            "alias": Host.current().localizedName ?? "Knotch",
            "version": "2.1",
            "deviceModel": "Mac",
            "deviceType": "desktop",
            "fingerprint": fingerprint,
            "port": Int(port),
            "protocol": "http",
            "download": false,
            "announce": true
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        connectionGroup?.send(content: data, completion: { _ in })
    }

    private func handleIncoming(content: Data, endpoint: NWEndpoint?) {
        guard let json = try? JSONSerialization.jsonObject(with: content) as? [String: Any],
              let peerFingerprint = json["fingerprint"] as? String,
              let alias = json["alias"] as? String,
              peerFingerprint != fingerprint
        else { return }

        let ip: String
        if let announced = json["ip"] as? String {
            ip = announced
        } else if case let .hostPort(host, _) = endpoint {
            ip = host.debugDescription.replacingOccurrences(of: "\"", with: "")
        } else { return }

        let device = LocalSendDeviceInfo(
            id: peerFingerprint,
            alias: alias,
            ip: ip,
            port: (json["port"] as? Int) ?? Int(port),
            https: (json["protocol"] as? String) == "https",
            model: json["deviceModel"] as? String
        )
        discoveredByID[peerFingerprint] = (device, Date())
        rememberKnownPeerIP(ip)
        rememberRecentProbeIP(ip)
        refreshDevices()
    }

    private func cleanupStale() {
        let cutoff = Date().addingTimeInterval(-30)
        discoveredByID = discoveredByID.filter { $0.value.lastSeen > cutoff }
        refreshDevices()
    }

    private func refreshDevices() {
        devices = discoveredByID.values.map(\.device)
            .sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
        if !devices.contains(where: { $0.id == selectedDeviceID }), let first = devices.first {
            selectedDeviceID = first.id
        }
    }

    // MARK: - Register listener (so peers can push their info to us)

    private func startRegisterListener() {
        guard registerListener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.handleRegisterConnection(connection) }
            }
            listener.start(queue: .global(qos: .utility))
            registerListener = listener
        } catch {
            NSLog("LocalSend register listener failed: \(error.localizedDescription)")
        }
    }

    private func handleRegisterConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 131_072) { [weak self] content, _, _, _ in
            guard let self, let data = content else { connection.cancel(); return }
            Task { @MainActor in
                let response = self.processRegisterRequest(data: data)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private func processRegisterRequest(data: Data) -> Data {
        let responseJSON: [String: Any] = [
            "alias": Host.current().localizedName ?? "Knotch",
            "version": "2.1",
            "deviceModel": "Mac",
            "deviceType": "desktop",
            "fingerprint": fingerprint,
            "port": Int(port),
            "protocol": "http",
            "download": false
        ]
        let body = (try? JSONSerialization.data(withJSONObject: responseJSON)) ?? Data("{}".utf8)
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(headers.utf8)
        response.append(body)
        return response
    }

    // MARK: - Sending

    private struct TransferFile { let id: String; let name: String; let mimeType: String; let data: Data }

    func send(items: [Any]) async throws {
        isSending = true
        sendProgress = 0
        defer { isSending = false; sendProgress = 0 }

        guard let target = devices.first(where: { $0.id == selectedDeviceID }) ?? devices.first else {
            throw LocalSendServiceError.noDeviceSelected
        }

        let files = try await buildTransferFiles(from: items)
        guard !files.isEmpty else { throw LocalSendServiceError.noTransferableItems }

        let (sessionID, fileTokens) = try await prepareUpload(files: files, to: target)
        guard !fileTokens.isEmpty else { sendProgress = 1; return }

        let totalBytes = files.reduce(0) { $0 + $1.data.count }
        var bytesDone = 0

        for file in files {
            guard let token = fileTokens[file.id] else { continue }
            try await upload(file: file, sessionID: sessionID, token: token, to: target)
            bytesDone += file.data.count
            sendProgress = Double(bytesDone) / Double(max(totalBytes, 1))
        }
    }

    private func buildTransferFiles(from items: [Any]) async throws -> [TransferFile] {
        var result: [TransferFile] = []
        for item in items {
            if let url = item as? URL, url.isFileURL, let data = try? Data(contentsOf: url) {
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                result.append(TransferFile(id: UUID().uuidString, name: url.lastPathComponent, mimeType: mime, data: data))
            } else if let url = item as? URL {
                result.append(TransferFile(id: UUID().uuidString, name: "link.url", mimeType: "text/uri-list", data: Data(url.absoluteString.utf8)))
            } else if let text = item as? String {
                result.append(TransferFile(id: UUID().uuidString, name: "text.txt", mimeType: "text/plain", data: Data(text.utf8)))
            }
        }
        return result
    }

    private func prepareUpload(files: [TransferFile], to device: LocalSendDeviceInfo) async throws -> (String, [String: String]) {
        var filesMap: [String: Any] = [:]
        for f in files {
            filesMap[f.id] = ["id": f.id, "fileName": f.name, "size": f.data.count, "fileType": f.mimeType]
        }
        let payload: [String: Any] = [
            "info": [
                "alias": Host.current().localizedName ?? "Knotch", "version": "2.1",
                "deviceModel": "Mac", "deviceType": "desktop",
                "fingerprint": fingerprint, "port": Int(port), "protocol": "http", "download": false
            ],
            "files": filesMap
        ]

        guard let url = URL(string: "\(device.baseURL)/api/localsend/v2/prepare-upload") else {
            throw LocalSendServiceError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await trustedSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalSendServiceError.invalidResponse }
        if http.statusCode == 403 { throw LocalSendServiceError.transferRejected }
        guard (200...299).contains(http.statusCode) else { throw LocalSendServiceError.server(status: http.statusCode) }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = json["sessionId"] as? String,
              let rawTokens = json["files"] as? [String: Any]
        else { throw LocalSendServiceError.invalidResponse }

        var tokens: [String: String] = [:]
        for (k, v) in rawTokens { if let s = v as? String { tokens[k] = s } }
        return (sessionID, tokens)
    }

    private func upload(file: TransferFile, sessionID: String, token: String, to device: LocalSendDeviceInfo) async throws {
        var components = URLComponents(string: "\(device.baseURL)/api/localsend/v2/upload")
        components?.queryItems = [
            URLQueryItem(name: "sessionId", value: sessionID),
            URLQueryItem(name: "fileId", value: file.id),
            URLQueryItem(name: "token", value: token)
        ]
        guard let url = components?.url else { throw LocalSendServiceError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(file.mimeType, forHTTPHeaderField: "Content-Type")
        request.httpBody = file.data

        let (_, response) = try await trustedSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LocalSendServiceError.server(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    private lazy var trustedSession: URLSession = {
        URLSession(configuration: .default, delegate: LocalSendTLSDelegate(), delegateQueue: nil)
    }()
}

private class LocalSendTLSDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if let trust = challenge.protectionSpace.serverTrust {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.performDefaultHandling, nil)
    }
}
