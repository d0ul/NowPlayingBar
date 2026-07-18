import Foundation
import Darwin

final class DiscordRPC {
    static let shared = DiscordRPC()

    var applicationID: String = "1527866298032324720"

    private enum Opcode: UInt32 {
        case handshake = 0
        case frame = 1
        case close = 2
        case ping = 3
        case pong = 4
    }

    private var socketFD: Int32 = -1
    private var isConnected = false
    private var isHandshaking = false
    private let queue = DispatchQueue(label: "DiscordRPC.socket")
    private var readSource: DispatchSourceRead?
    private var reconnectTimer: DispatchSourceTimer?

    var isEnabled: Bool = false {
        didSet {
            guard isEnabled != oldValue else { return }
            log("isEnabled -> \(isEnabled)")
            if isEnabled {
                connect()
            } else {
                disconnect()
            }
        }
    }

    private var pendingActivity: [String: Any]?

    private init() {}


    func setActivity(
        details: String?,
        state: String?,
        largeImageURL: String? = nil,
        largeImageText: String? = nil,
        startTimestamp: Date? = nil,
        endTimestamp: Date? = nil,
        isPlaying: Bool = true
    ) {
        guard isEnabled else { return }

        var activity: [String: Any] = [:]
        if let details, !details.isEmpty { activity["details"] = details }
        if let state, !state.isEmpty { activity["state"] = state }

        if isPlaying, let startTimestamp {
            var timestamps: [String: Any] = [
                "start": Int(startTimestamp.timeIntervalSince1970)
            ]
            if let endTimestamp {
                timestamps["end"] = Int(endTimestamp.timeIntervalSince1970)
            }
            activity["timestamps"] = timestamps
        }

        if let largeImageURL, !largeImageURL.isEmpty {
            var assets: [String: Any] = ["large_image": largeImageURL]
            if let largeImageText { assets["large_image_text"] = largeImageText }
            activity["assets"] = assets
        }

        activity["type"] = 2

        queueSetActivity(activity)
    }

    func clearActivity() {
        guard isConnected else { return }
        send(opcode: .frame, payload: [
            "cmd": "SET_ACTIVITY",
            "args": [
                "pid": ProcessInfo.processInfo.processIdentifier
            ],
            "nonce": UUID().uuidString
        ])
    }


    private func connect() {
        queue.async { [weak self] in
            self?.tryConnect()
        }
    }

    private func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.clearActivityInternal()
            self.teardownSocket()
            self.cancelReconnectTimer()
        }
    }

    private func tryConnect() {
        guard isEnabled, !isConnected else { return }

        if applicationID.isEmpty || applicationID == "0000000000000000000" {
            log("applicationID is still the placeholder — set it to your real Discord Application ID (https://discord.com/developers/applications)")
        }

        let base = discordIPCBaseDirectory()
        log("looking for Discord IPC socket under \(base)")
        for i in 0..<10 {
            let path = base + "/discord-ipc-\(i)"
            if connectSocket(at: path) {
                log("connected to \(path)")
                isConnected = true
                sendHandshake()
                startReading()
                return
            }
        }
        log("no discord-ipc-N socket found under \(base) (0...9) — is the Discord desktop app running?")
        scheduleReconnect()
    }

    private func discordIPCBaseDirectory() -> String {
        if let xdg = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"], !xdg.isEmpty {
            return xdg
        }
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"], !tmp.isEmpty {
            return tmp.hasSuffix("/") ? String(tmp.dropLast()) : tmp
        }
        return "/tmp"
    }

    private func connectSocket(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd != -1 else { return false }

        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return false
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { cPtr in
                for (i, b) in pathBytes.enumerated() { cPtr[i] = CChar(bitPattern: b) }
                cPtr[pathBytes.count] = 0
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, size)
            }
        }

        if result == -1 {
            let err = errno
            log("connect(\(path)) failed: \(String(cString: strerror(err))) (errno \(err))")
            close(fd)
            return false
        }

        socketFD = fd
        return true
    }

    private func teardownSocket() {
        readSource?.cancel()
        readSource = nil
        if socketFD != -1 {
            close(socketFD)
            socketFD = -1
        }
        isConnected = false
        isHandshaking = false
    }

    private func scheduleReconnect() {
        cancelReconnectTimer()
        guard isEnabled else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15)
        timer.setEventHandler { [weak self] in
            self?.tryConnect()
        }
        timer.resume()
        reconnectTimer = timer
    }

    private func cancelReconnectTimer() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }


    private func sendHandshake() {
        isHandshaking = true
        send(opcode: .handshake, payload: [
            "v": 1,
            "client_id": applicationID
        ])
    }


    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleReadable()
        }
        source.setCancelHandler { [weak self] in
            self?.handleDisconnect()
        }
        source.resume()
        readSource = source
    }

    private func readExact(_ count: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { ptr -> Int in
                read(socketFD, ptr.baseAddress!.advanced(by: offset), count - offset)
            }
            if n <= 0 { return nil }
            offset += n
        }
        return buffer
    }

    private func handleReadable() {
        guard let header = readExact(8) else {
            handleDisconnect()
            return
        }
        let length = header[4..<8].withUnsafeBytes { $0.load(as: UInt32.self) }
        if length > 0 {
            _ = readExact(Int(length))
        }
        if isHandshaking {
            isHandshaking = false
            log("handshake complete")
            if let pendingActivity {
                self.pendingActivity = nil
                log("sending queued activity after handshake")
                send(opcode: .frame, payload: [
                    "cmd": "SET_ACTIVITY",
                    "args": [
                        "pid": ProcessInfo.processInfo.processIdentifier,
                        "activity": pendingActivity
                    ],
                    "nonce": UUID().uuidString
                ])
            }
        }
    }

    private func handleDisconnect() {
        log("socket disconnected, will retry")
        teardownSocket()
        scheduleReconnect()
    }


    private func queueSetActivity(_ activity: [String: Any]) {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.isConnected {
                self.pendingActivity = activity
                self.tryConnect()
                return
            }
            if self.isHandshaking {
                self.pendingActivity = activity
                return
            }
            self.send(opcode: .frame, payload: [
                "cmd": "SET_ACTIVITY",
                "args": [
                    "pid": ProcessInfo.processInfo.processIdentifier,
                    "activity": activity
                ],
                "nonce": UUID().uuidString
            ])
        }
    }

    private func clearActivityInternal() {
        guard isConnected, !isHandshaking else { return }
        send(opcode: .frame, payload: [
            "cmd": "SET_ACTIVITY",
            "args": [
                "pid": ProcessInfo.processInfo.processIdentifier
            ],
            "nonce": UUID().uuidString
        ])
    }

    private func send(opcode: Opcode, payload: [String: Any]) {
        guard socketFD != -1 else {
            log("send(\(opcode)) skipped — no open socket")
            return
        }
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else {
            log("send(\(opcode)) failed — payload is not valid JSON: \(payload)")
            return
        }

        var frame = Data()
        var op = opcode.rawValue.littleEndian
        var len = UInt32(json.count).littleEndian
        withUnsafeBytes(of: &op) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
        frame.append(json)

        let written = frame.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in
            write(socketFD, ptr.baseAddress, ptr.count)
        }
        if written != frame.count {
            log("send(\(opcode)) short/failed write: wrote \(written) of \(frame.count) bytes, errno \(errno)")
        } else if opcode == .frame, let cmd = payload["cmd"] as? String {
            log("sent \(cmd) frame")
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write("[DiscordRPC] \(message)\n".data(using: .utf8)!)
    }
}
