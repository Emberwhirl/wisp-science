import Foundation
import Combine
import UIKit
import ImageIO
import WispRemote

struct AttachedPhoto: Identifiable {
    let id = UUID()
    let path: String
    let data: Data
}

enum WorkspaceSheet: Identifiable {
    case connection, inbox, files(ConversationRoute, String, Bool)
    var id: String {
        switch self {
        case .connection: return "connection"
        case .inbox: return "inbox"
        case .files(let route, let path, _): return "files:\(route.project):\(route.session):\(path)"
        }
    }
}

@MainActor final class RemoteWorkspace: ObservableObject {
    let connection: RemoteConnection
    private let credentials: any RemoteCredentialStoring
    private let preferences: UserDefaults?
    private static let demoPreference = "wisp.workspace.demo"
    private var demo: DemoDataset?
    @Published private(set) var isDemo = false
    @Published private(set) var configuration: RemoteConfiguration?
    @Published var projects: [RemoteValue] = []
    @Published var sessions: [RemoteValue] = []
    @Published var inbox: [RemoteValue] = []
    @Published var selectedProject: String? { didSet {
        if selectedProject != oldValue { selectedSession = nil; sessions = [] }
    } }
    @Published var selectedSession: String? { didSet {
        if selectedSession != oldValue { history = RemoteHistory(); error = nil }
    } }
    @Published var history = RemoteHistory()
    @Published var sheet: WorkspaceSheet?
    @Published var error: String?
    @Published var drafts: [ConversationRoute: String] = [:]
    @Published var photos: [ConversationRoute: [AttachedPhoto]] = [:]
    @Published var busy: Set<ConversationRoute> = []
    @Published var loadingEarlier = false
    @Published var creating = false
    var visibleRoute: ConversationRoute?
    private var identity = UUID()
    private var seen: Set<String> = []
    private var active = true
    private var restored = false

    init(connection: RemoteConnection? = nil, credentials: any RemoteCredentialStoring = RemoteCredentials(),
         preferences: UserDefaults? = .standard) {
        self.connection = connection ?? RemoteConnection()
        self.credentials = credentials
        self.preferences = preferences
        self.connection.authenticated = { [weak self] in
            guard let self, !self.isDemo, let configuration = self.configuration else { return }
            do { try self.credentials.save(configuration) }
            catch { self.error = error.localizedDescription }
            self.seen = []
        }
    }

    var route: ConversationRoute? {
        guard let project = selectedProject, let session = selectedSession else { return nil }
        return ConversationRoute(project: project, session: session)
    }
    var snapshot: RemoteSnapshot? { history.snapshot }
    var title: String { sessions.first { $0["id"].string == selectedSession }?["title"].string ?? "对话" }

    func restore() {
        guard !restored else { return }
        restored = true
        if preferences?.bool(forKey: Self.demoPreference) == true { enterDemo(); return }
        do {
            if let saved = try credentials.load() {
                configuration = saved
                if active { connection.connect(saved) }
            }
        } catch { self.error = error.localizedDescription }
    }
    func connect(address: String, code: String) {
        do {
            let configuration = try RemoteConfiguration(address: address, code: code)
            preferences?.set(false, forKey: Self.demoPreference)
            demo = nil
            isDemo = false
            clearWorkspace()
            self.configuration = configuration
            connection.connect(configuration)
        } catch { self.error = error.localizedDescription }
    }
    func setActive(_ active: Bool) {
        guard active != self.active else { return }
        self.active = active
        if isDemo { return }
        if active, let configuration { connection.connect(configuration) }
        else { connection.disconnect() }
    }
    func reconnect() { if let configuration { connection.connect(configuration) } }

    func enterDemo() {
        do {
            let dataset = try DemoDataset()
            restored = true
            connection.disconnect()
            clearWorkspace()
            configuration = nil
            demo = dataset
            isDemo = true
            sheet = nil
            preferences?.set(true, forKey: Self.demoPreference)
            connection.useLocalService(name: "本地演示 · 合成数据", commands: DemoDataset.commands) { command, project, args in
                try dataset.call(command, project: project, args: args)
            }
            let identity = self.identity
            Task {
                guard self.identity == identity, self.isDemo else { return }
                await refreshSelection()
            }
        } catch { self.error = error.localizedDescription }
    }
    func exitDemo() {
        guard isDemo else { return }
        connection.disconnect()
        demo = nil
        isDemo = false
        configuration = nil
        sheet = nil
        preferences?.set(false, forKey: Self.demoPreference)
        clearWorkspace()
    }
    func forget() {
        if isDemo { exitDemo(); return }
        do {
            try credentials.remove()
            connection.disconnect()
            configuration = nil
            sheet = nil
            clearWorkspace()
        } catch { self.error = error.localizedDescription }
    }
    private func clearWorkspace() {
        identity = UUID()
        visibleRoute = nil
        selectedProject = nil; selectedSession = nil
        projects = []; sessions = []; inbox = []; drafts = [:]; photos = [:]
        busy = []; loadingEarlier = false; creating = false
        history = RemoteHistory(); seen = []; error = nil
    }

    func monitor() async {
        if isDemo { await refreshSelection(); return }
        let identity = self.identity
        var lastSidebar = Date.distantPast
        while !Task.isCancelled && connection.state == .online && active && self.identity == identity && !isDemo {
            do {
                if Date().timeIntervalSince(lastSidebar) > 8 {
                    try await refreshSidebar()
                    lastSidebar = Date()
                }
                try await refreshConversation()
            } catch is CancellationError { return }
            catch { if !Task.isCancelled && self.identity == identity { self.error = error.localizedDescription } }
            do { try await Task.sleep(nanoseconds: snapshot?.running == true ? 1_500_000_000 : 4_000_000_000) }
            catch { return }
        }
    }

    func refreshSidebar() async throws {
        let identity = self.identity
        let configuration = self.configuration
        let result = try await connection.call("list_projects")
        try Task.checkCancellation()
        guard self.configuration == configuration, self.identity == identity else { return }
        projects = result.array
        if let project = selectedProject {
            let result = try await connection.call("remote_sessions", project: project)
            try Task.checkCancellation()
            if selectedProject == project && self.configuration == configuration && self.identity == identity { sessions = result.array }
        }
        if let project = projects.first?["id"].string, connection.supports("native_conversation_inbox") {
            let result = try await connection.call("native_conversation_inbox", project: project)
            try Task.checkCancellation()
            if self.configuration == configuration && self.identity == identity { inbox = result.array }
        }
    }
    func refreshConversation() async throws {
        guard let route else { return }
        let identity = self.identity
        let configuration = self.configuration
        let result = try await connection.call("native_conversation_snapshot", project: route.project, args: route.args)
        let next = try RemoteSnapshot(result, route: route)
        try Task.checkCancellation()
        guard self.route == route, self.configuration == configuration, self.identity == identity else { return }
        history.replace(next)
        let stamp = "\(next.epoch):\(route.project):\(route.session):\(next.sequence)"
        if !next.running && active && visibleRoute == route && sheet == nil && connection.supports("native_conversation_seen"), !seen.contains(stamp) {
            _ = try await connection.call("native_conversation_seen", project: route.project, args: route.args)
            seen = [stamp]
        }
    }
    func refreshSelection() async {
        let identity = self.identity
        do {
            try await refreshSidebar()
            guard self.identity == identity else { return }
            try await refreshConversation()
            if isDemo && self.identity == identity { try await refreshSidebar() }
        }
        catch is CancellationError { }
        catch { if self.identity == identity { self.error = error.localizedDescription } }
    }

    func createConversation() async {
        guard let project = selectedProject, !creating else { return }
        let identity = self.identity
        creating = true
        defer { creating = false }
        do {
            let result = try await connection.call("native_conversation_create", project: project)
            guard selectedProject == project, self.identity == identity else { return }
            guard !result.string.isEmpty else { throw RemoteError.incompatibleResponse }
            selectedSession = result.string
            await refreshSelection()
        } catch { if self.identity == identity { self.error = error.localizedDescription } }
    }
    func send(_ route: ConversationRoute) async {
        guard self.route == route, let snapshot, snapshot.writable, !busy.contains(route) else { return }
        let identity = self.identity
        let message = (drafts[route] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let attached = photos[route] ?? []
        guard !message.isEmpty || !attached.isEmpty else { return }
        busy.insert(route)
        defer { busy.remove(route) }
        do {
            var args = route.args
            args["request_id"] = .string(UUID().uuidString)
            args["message"] = .string(message)
            args["attachments"] = .array(attached.map { .string($0.path) })
            _ = try await connection.call(snapshot.running ? "native_conversation_enqueue" : "native_conversation_send",
                                          project: route.project, args: args)
            guard self.identity == identity else { return }
            // A typed replacement draft must survive an in-flight response.
            if (drafts[route] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == message { drafts[route] = "" }
            photos[route]?.removeAll { photo in attached.contains { $0.id == photo.id } }
            if self.route == route { try await refreshConversation() }
        } catch { if self.identity == identity { self.error = error.localizedDescription } }
    }
    func action(_ command: String, route: ConversationRoute, extra: [String: RemoteValue] = [:]) async {
        guard !busy.contains(route) else { return }
        let identity = self.identity
        busy.insert(route)
        defer { busy.remove(route) }
        do {
            _ = try await connection.call(command, project: route.project, args: route.args.merging(extra) { _, new in new })
            guard self.identity == identity else { return }
            if self.route == route { try await refreshConversation() }
            if isDemo { try await refreshSidebar() }
        } catch { if self.identity == identity { self.error = error.localizedDescription } }
    }
    func earlier() async {
        guard let route, let snapshot, history.cursor != .null, !loadingEarlier else { return }
        loadingEarlier = true
        defer { loadingEarlier = false }
        let cursor = history.cursor
        do {
            let result = try await connection.call("native_conversation_snapshot", project: route.project,
                args: route.args.merging(["before_seq": cursor]) { _, v in v })
            let page = try RemoteSnapshot(result, route: route)
            guard self.route == route else { return }
            history.prepend(page, expectedEpoch: snapshot.epoch, expectedBoundary: snapshot.before, requestedCursor: cursor)
        } catch { self.error = error.localizedDescription }
    }
    func upload(_ data: Data, route: ConversationRoute) async {
        let identity = self.identity
        guard (photos[route]?.count ?? 0) < 4 else { error = "一条消息最多添加 4 张图片。"; return }
        do {
            let jpeg = try PhotoPreparation.jpeg(data)
            let result = try await connection.call("remote_attach_image", project: route.project,
                args: route.args.merging(["base64": .string(jpeg.base64EncodedString())]) { _, v in v })
            guard self.identity == identity else { return }
            guard !result["path"].string.isEmpty else { throw RemoteError.incompatibleResponse }
            photos[route, default: []].append(AttachedPhoto(path: result["path"].string, data: jpeg))
        } catch { if self.identity == identity { self.error = error.localizedDescription } }
    }
    func openInbox(_ entry: RemoteValue) {
        selectedProject = entry["project_id"].string
        selectedSession = entry["id"].string
        sheet = nil
    }
}

enum PhotoPreparation {
    /// Downsample before decoding a full-size camera image, then fit the same
    /// 560 KiB budget as remote.js (base64 nested inside an encrypted frame).
    static func jpeg(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw RemoteError.service("无法读取图片。") }
        for side in [1600, 1120, 784, 548, 400] {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: side]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { continue }
            let size = CGSize(width: CGFloat(thumbnail.width), height: CGFloat(thumbnail.height))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1; format.opaque = true
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
                UIImage(cgImage: thumbnail).draw(in: CGRect(origin: .zero, size: size))
            }
            if let jpeg = image.jpegData(compressionQuality: 0.8), jpeg.count <= 560 * 1024 { return jpeg }
        }
        throw RemoteError.service("无法将图片缩小到上传限制内。")
    }
}
