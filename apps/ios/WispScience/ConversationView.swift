import SwiftUI
import PhotosUI
import WispRemote

struct ConversationView: View {
    @ObservedObject var model: RemoteWorkspace
    @ObservedObject var connection: RemoteConnection
    let route: ConversationRoute
    @State private var chosenPhotos: [PhotosPickerItem] = []
    @State private var uploading = false
    @State private var followLatest = true
    @State private var initialScroll = true
    @FocusState private var composing: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    private var snapshot: RemoteSnapshot? { model.snapshot }
    private var draft: Binding<String> {
        Binding(get: { model.drafts[route] ?? "" }, set: { model.drafts[route] = $0 })
    }
    private var blocked: Bool {
        connection.state != .online || snapshot?.writable != true || model.busy.contains(route) || uploading
    }
    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if model.history.cursor != .null {
                        Button("加载更早的消息") { Task { await model.earlier() } }
                            .disabled(model.loadingEarlier).frame(maxWidth: .infinity)
                    }
                    ForEach(Array(model.history.older.enumerated()), id: \.offset) { _, item in
                        MessageView(item: item, model: model, route: route)
                    }
                    ForEach(Array((snapshot?.items ?? []).enumerated()), id: \.offset) { _, item in
                        MessageView(item: item, model: model, route: route)
                    }
                    if let runs = snapshot?.value["run_cards"].array, !runs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("运行记录").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            ForEach(runs, id: \.recordID) { run in RunCardView(run: run) }
                        }
                    }
                    ForEach(snapshot?.value["approvals"].array ?? [], id: \.approvalID) { approval in
                        approvalCard(approval)
                    }
                    if let snapshot {
                        if snapshot.running {
                            HStack { ProgressView(); Text(snapshot.value["activity_status"].string.isEmpty ? "运行中…" : snapshot.value["activity_status"].string) }
                                .font(.callout).foregroundStyle(.secondary)
                        } else if !snapshot.value["error"].string.isEmpty {
                            Text(snapshot.value["error"].string).foregroundStyle(.red)
                        }
                        if snapshot.writable && !snapshot.value["follow_ups"].array.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("继续探索").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                ForEach(Array(snapshot.value["follow_ups"].array.enumerated()), id: \.offset) { index, suggestion in
                                    Button { model.drafts[route] = suggestion.string } label: {
                                        Text(suggestion.string)
                                            .font(.subheadline).foregroundStyle(.primary)
                                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, 12).padding(.vertical, 11)
                                            .frame(minHeight: 44).contentShape(Rectangle())
                                    }
                                    .buttonStyle(WispRowButtonStyle())
                                    .background(WispStyle.canvas, in: RoundedRectangle(cornerRadius: 10))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(WispStyle.border, lineWidth: 1) }
                                    .accessibilityIdentifier("follow-up-\(index)")
                                    .accessibilityHint("填入输入框，确认后再发送")
                                }
                            }
                        }
                        ForEach(snapshot.value["queue"]["items"].array, id: \.recordID) { item in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item["message"].string).lineLimit(3)
                                    StatusBadge(status: item["state"].string)
                                }
                                Spacer()
                                if item["state"].string == "queued", connection.supports("native_conversation_queue_action") {
                                    Button("取消排队") {
                                        Task { await model.action("native_conversation_queue_action", route: route, extra: [
                                            "id": item["id"], "digest": item["digest"], "action": .object(["kind": .string("cancel")]),
                                        ]) }
                                    }.disabled(blocked)
                                }
                            }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                        }
                    } else { ProgressView("读取对话…").frame(maxWidth: .infinity) }
                    Color.clear.frame(height: 1).id("latest")
                        .onAppear { followLatest = true }
                        .onDisappear { followLatest = false }
                }
                .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 8)
                .frame(maxWidth: 780).frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("conversation-transcript")
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .refreshable { await model.refreshSelection() }
            .onChange(of: snapshot) { _, next in
                if next != nil && (initialScroll || followLatest) { reader.scrollTo("latest", anchor: .bottom); initialScroll = false }
            }
        }
        .background(WispStyle.canvas)
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(WispStyle.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            Button("文件") { model.sheet = .files(route, ".", true) }
                .disabled(!connection.supports("native_conversation_panel_file_directory"))
                .accessibilityIdentifier("conversation-files")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .onAppear { model.visibleRoute = route }
        .onDisappear { if model.visibleRoute == route { model.visibleRoute = nil } }
        .accessibilityIdentifier("conversation")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                if !(model.photos[route] ?? []).isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(model.photos[route] ?? []) { photo in
                                VStack(spacing: 4) {
                                    if let image = UIImage(data: photo.data) {
                                        Image(uiImage: image).resizable().scaledToFill().frame(width: 64, height: 64).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    Button("移除") { model.photos[route]?.removeAll { $0.id == photo.id } }
                                        .font(.caption).frame(minWidth: 44, minHeight: 44).buttonStyle(.plain)
                                        .disabled(model.busy.contains(route) || uploading)
                                }
                            }
                        }
                    }.padding(.horizontal, 12).padding(.top, 12)
                }
                TextField(model.isDemo ? "试试询问演示报告…" : "给 Wisp 发消息…", text: draft, axis: .vertical).lineLimit(1...(typeSize.isAccessibilitySize ? 3 : 6))
                    .font(.body).foregroundStyle(.primary).focused($composing)
                    .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
                    .disabled(snapshot?.writable != true).accessibilityIdentifier("message-draft")
                composerActions.padding(.horizontal, 8).padding(.bottom, 8)
            }
            .background(WispStyle.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(composing ? WispStyle.accent.opacity(0.6) : WispStyle.border, lineWidth: 1)
            }
            Text(model.isDemo ? "本地预设回复 · 不调用 AI，不执行分析" :
                    snapshot?.value["read_only"].bool == true ? "这个对话是只读的。" :
                    !(snapshot?.value["acp_agent_id"].string ?? "").isEmpty ? "ACP 会话请在桌面端继续。" :
                    "写文件和执行命令前，会请你批准")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
        .frame(maxWidth: 780).frame(maxWidth: .infinity).background(WispStyle.canvas)
        .overlay(alignment: .top) { Rectangle().fill(WispStyle.border).frame(height: 0.5) }
        .onChange(of: chosenPhotos) { _, selection in
            guard !selection.isEmpty, !uploading else { return }
            uploading = true
            model.busy.insert(route)
            Task {
                defer { uploading = false; model.busy.remove(route); chosenPhotos = [] }
                for item in selection {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                        await model.upload(data, route: route)
                    } catch { model.error = "无法读取所选图片，请重试。" }
                }
            }
        }
    }

    private var composerActions: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            if connection.supports("remote_attach_image") {
                PhotosPicker(selection: $chosenPhotos, maxSelectionCount: max(1, 4 - (model.photos[route]?.count ?? 0)), matching: .images) {
                    HStack(spacing: 6) {
                        if uploading { ProgressView().controlSize(.small) }
                        else { WispIcon(.image, size: 18) }
                        Text(uploading ? "上传中…" : "图片").font(.subheadline)
                    }.foregroundStyle(.secondary).padding(.horizontal, 6).frame(minHeight: 44)
                }
                .buttonStyle(WispRowButtonStyle())
                .accessibilityLabel(uploading ? "正在上传图片" : "添加图片")
                .disabled(blocked || (model.photos[route]?.count ?? 0) >= 4)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 4)
                if snapshot?.running == true && connection.supports("native_conversation_stop") {
                    Button("停止", role: .destructive) { Task { await model.action("native_conversation_stop", route: route) } }
                        .font(.subheadline).foregroundStyle(WispStyle.failure)
                        .frame(minWidth: 44, minHeight: 44).buttonStyle(WispRowButtonStyle())
                        .disabled(connection.state != .online || model.busy.contains(route) || snapshot?.value["stopping"].bool == true)
                }
                Button { Task { await model.send(route) } } label: {
                    HStack(spacing: 5) {
                        Text(snapshot?.running == true ? "排队" : "发送")
                        WispIcon(.arrowUp, size: 17)
                    }
                }
                    .buttonStyle(WispSendButtonStyle()).keyboardShortcut(.return, modifiers: .command)
                    .disabled(blocked || ((model.drafts[route] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (model.photos[route] ?? []).isEmpty)
                              || !connection.supports(snapshot?.running == true ? "native_conversation_enqueue" : "native_conversation_send"))
                    .accessibilityIdentifier("send-message")
            }
        }
    }

    private func approvalCard(_ approval: RemoteValue) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("需要你批准：\(approval["tool"].string)").font(.subheadline.weight(.semibold)).foregroundStyle(WispStyle.warning)
            Text(approval["message"].string).font(.subheadline).textSelection(.enabled)
            CodeText(text: approval["preview"].string)
            HStack {
                Spacer()
                Button("拒绝", role: .destructive) { decide(false, approval) }
                    .font(.subheadline).foregroundStyle(WispStyle.failure)
                    .frame(minWidth: 60, minHeight: 44).buttonStyle(WispRowButtonStyle())
                Button("批准一次") { decide(true, approval) }.buttonStyle(WispSendButtonStyle())
            }.disabled(connection.state != .online || model.busy.contains(route) || !connection.supports("native_conversation_approve"))
        }.padding(14).background(WispStyle.warning.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(WispStyle.warning.opacity(0.25), lineWidth: 1) }
    }
    private func decide(_ approved: Bool, _ approval: RemoteValue) {
        Task { await model.action("native_conversation_approve", route: route, extra: [
            "approval_id": approval["approval_id"], "approved": .bool(approved),
        ]) }
    }
}

struct MessageView: View {
    let item: RemoteValue
    @ObservedObject var model: RemoteWorkspace
    let route: ConversationRoute
    var body: some View {
        switch item["role"].string {
        case "user":
            VStack(alignment: .leading, spacing: 8) {
                Text(item["text"].string).textSelection(.enabled)
                ForEach(Array(item["attachments"].array.enumerated()), id: \.offset) { _, attachment in
                    RemoteImageView(connection: model.connection, route: route, source: ["path": attachment], label: (attachment.string as NSString).lastPathComponent)
                }
            }.font(.body).foregroundStyle(.primary).multilineTextAlignment(.leading)
                .padding(14).background(WispStyle.surface, in: RoundedRectangle(cornerRadius: 16))
                .padding(.leading, 28)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case "assistant":
            MarkdownView(text: item["text"].string, resources: item["resources"].array, model: model, route: route)
        case "tool", "acp_tool", "reasoning":
            DisclosureGroup {
                if !item["input"].string.isEmpty { CodeText(text: item["input"].string) }
                CodeText(text: item["text"].string)
                if item["tool_name"].string == "generate_image", item["ok"].bool,
                   let path = RemoteMarkdown.localPath(item["input"].string) {
                    RemoteImageView(connection: model.connection, route: route, source: ["path": .string(path)], label: "生成的图片")
                }
            } label: {
                HStack {
                    Text(item["role"].string == "reasoning" ? "思考" : item["tool_name"].string)
                    Spacer()
                    StatusBadge(status: item["ok"] == .bool(false) ? "failed" : item["status"].string)
                }.font(.subheadline).foregroundStyle(.primary)
            }.disclosureGroupStyle(WispDisclosureStyle())
        case "plan":
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(item["proposal"]["entries"].array.enumerated()), id: \.offset) { index, entry in
                    Text("\(index + 1). \(entry["content"].string)")
                }
            }.foregroundStyle(.secondary)
        default:
            if !item["text"].string.isEmpty { Text(item["text"].string).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }
}

struct RunCardView: View {
    let run: RemoteValue
    @Environment(\.dynamicTypeSize) private var typeSize
    private var output: String {
        [run["stdout_tail"].string, run["stderr_tail"].string, run["last_poll_error"].string]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    var body: some View {
        DisclosureGroup {
            if !run["command"].string.isEmpty { CodeText(text: "$ " + run["command"].string) }
            if !output.isEmpty { CodeText(text: output) }
            else { Text("暂无输出").font(.caption).foregroundStyle(.secondary) }
        } label: {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
            layout {
                Text(run["title"].string.isEmpty ? run["kind"].string : run["title"].string)
                    .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatusBadge(status: run["status"].string).fixedSize()
            }
        }.disclosureGroupStyle(WispDisclosureStyle(identifier: "run-\(run.recordID)"))
    }
}
