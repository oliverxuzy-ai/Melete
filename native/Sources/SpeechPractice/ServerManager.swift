import Foundation
import Darwin

/// Launches the bundled Python server (Contents/Resources/server/SpeechPracticeServer)
/// and waits until it answers. Set SPEECH_SERVER_URL to use an already running server.
@Observable
final class ServerManager {
    enum Status: Equatable { case starting, ready, failed(String) }
    var status: Status = .starting
    var baseURL: URL?
    var isExternal = false
    private var process: Process?

    var api: API? { baseURL.map { API(base: $0) } }

    func start() async {
        if let external = ProcessInfo.processInfo.environment["SPEECH_SERVER_URL"], let url = URL(string: external) {
            baseURL = url; isExternal = true
            await waitReady()
            return
        }
        guard let exe = Bundle.main.resourceURL?.appendingPathComponent("server/SpeechPracticeServer"),
              FileManager.default.isExecutableFile(atPath: exe.path) else {
            status = .failed("找不到内置的分析服务（server/SpeechPracticeServer）")
            return
        }
        let port = ServerManager.freePort()
        let p = Process()
        p.executableURL = exe
        var env = ProcessInfo.processInfo.environment
        env["PORT"] = String(port)
        env["PARENT_PID"] = String(getpid())
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                if self?.status == .ready || self?.status == .starting {
                    self?.status = .failed("分析服务退出了（code \(proc.terminationStatus)），看 logs/server.log")
                }
            }
        }
        do { try p.run() } catch {
            status = .failed("启动分析服务失败：\(error.localizedDescription)")
            return
        }
        process = p
        baseURL = URL(string: "http://127.0.0.1:\(port)")
        await waitReady()
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    private func waitReady(timeout: TimeInterval = 180) async {
        guard let api else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .failed = status { return }
            if (try? await api.config()) != nil { status = .ready; return }
            try? await Task.sleep(for: .milliseconds(400))
        }
        status = .failed("分析服务 \(Int(timeout)) 秒内没有响应")
    }

    static func freePort() -> Int {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, len) } }
        guard bound == 0 else { return 18765 }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) } }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
