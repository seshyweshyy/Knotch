//
//  LocalSendService.swift
//  Knotch
//

import Foundation
import Network
import Defaults
import UniformTypeIdentifiers

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
    private var discoveredByID: [String: (device: LocalSendDeviceInfo, lastSeen: Date)] = [:]
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
