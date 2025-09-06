//
//  ContentView.swift
//  spark
//
//  Created by Cary on 2025/8/31.
//

import SwiftUI
import WKMarkdownView
import SwiftData
import LLMChatOpenAI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import Foundation
import Supabase
import QuickLook

// MARK: - User Model
struct AppUser {
    let id: String
    let email: String
    let name: String
    let avatarURL: String?
    
    var displayName: String {
        return name.isEmpty ? email : name
    }
}

// MARK: - Supabase Configuration
struct SupabaseConfig {
    // 请填写您的 Supabase 配置
    static let url = "https://example.supabase.co"
    static let anonKey = "put_your_anonKey_here"
    static let avatarsBucket = "avatars" // SQL 中建议的 bucket 名称
    static let sessionDefaultsKey = "supabase.session"
}

// MARK: - Custom Supabase Error
struct SupabaseError: Error {
    let message: String
    let type: String
    
    var localizedDescription: String {
        return message
    }
}

// MARK: - Supabase Service (REST 实现)
class SupabaseService: ObservableObject {
    static let shared = SupabaseService()
    
    @Published var currentUser: AppUser?
    @Published var isLoggedIn = false
    
    private var accessToken: String? {
        didSet {
            if let token = accessToken {
                UserDefaults.standard.set(token, forKey: SupabaseConfig.sessionDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: SupabaseConfig.sessionDefaultsKey)
            }
        }
    }
    private var refreshToken: String? {
        didSet {
            if let rt = refreshToken {
                UserDefaults.standard.set(rt, forKey: "supabase.refresh_token")
            } else {
                UserDefaults.standard.removeObject(forKey: "supabase.refresh_token")
            }
        }
    }
    private var syncTask: Task<Void, Never>?
    private let syncQueue = SyncQueue()
    private var client: SupabaseClient?
    private var realtimeChannels: [RealtimeChannelV2] = []
    // Added guards to prevent duplicate starts/subscriptions
    private var isSyncStarted: Bool = false
    private var hasRealtimeSubscribed: Bool = false
    
    private init() {
        if let token = UserDefaults.standard.string(forKey: SupabaseConfig.sessionDefaultsKey) {
            self.accessToken = token
            Task { try? await self.refreshProfile() }
        }
        if let savedRT = UserDefaults.standard.string(forKey: "supabase.refresh_token"), accessToken == nil {
            Task { try? await self.refreshSession(with: savedRT) }
        }
        // 初始化 Supabase SDK 客户端
        if let url = URL(string: SupabaseConfig.url) {
            client = SupabaseClient(supabaseURL: url, supabaseKey: SupabaseConfig.anonKey)
        }
    }
    
    // MARK: - Auth
    func login(email: String, password: String) async throws {
        let urlString = "\(SupabaseConfig.url)/auth/v1/token?grant_type=password"
        guard let url = URL(string: urlString) else { throw SupabaseError(message: "无效URL", type: "url_invalid") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email,
            "password": password
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SupabaseError(message: "无响应", type: "network_error") }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "登录失败"
            throw SupabaseError(message: msg, type: "invalid_credentials")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let token = (json?["access_token"] as? String) ?? (json?["accessToken"] as? String)
        self.accessToken = token
        self.refreshToken = (json?["refresh_token"] as? String) ?? (json?["refreshToken"] as? String)
        try await refreshProfile()
    }
    
    func register(email: String, password: String, name: String) async throws {
        let urlString = "\(SupabaseConfig.url)/auth/v1/signup"
        guard let url = URL(string: urlString) else { throw SupabaseError(message: "无效URL", type: "url_invalid") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email,
            "password": password,
            "data": ["name": name]
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SupabaseError(message: "无响应", type: "network_error") }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "注册失败"
            throw SupabaseError(message: msg, type: "user_already_exists")
        }
        // 有的项目开启 "Email confirm" 时需要邮箱验证；此处尝试直接登录
        try await login(email: email, password: password)
    }
    
    func logout() async throws {
        // 可调用 signout，但前端清本地 token 即可
        self.accessToken = nil
        self.refreshToken = nil
        await MainActor.run {
            self.currentUser = nil
            self.isLoggedIn = false
        }
    }

    // 刷新会话：使用 refresh_token 获取新 access_token
    func refreshSession(with refreshToken: String) async throws {
        let urlString = "\(SupabaseConfig.url)/auth/v1/token?grant_type=refresh_token"
        guard let url = URL(string: urlString) else { throw SupabaseError(message: "无效URL", type: "url_invalid") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "refresh_token": refreshToken
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SupabaseError(message: "刷新会话失败", type: "session_refresh_failed")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let token = (json?["access_token"] as? String) ?? (json?["accessToken"] as? String)
        let newRT = (json?["refresh_token"] as? String) ?? (json?["refreshToken"] as? String)
        self.accessToken = token
        self.refreshToken = newRT ?? refreshToken
        try await refreshProfile()
    }
    
    private func authHeaders() throws -> [String: String] {
        guard let token = accessToken else { throw SupabaseError(message: "未登录", type: "session_invalid") }
        return [
            "Authorization": "Bearer \(token)",
            "apikey": SupabaseConfig.anonKey
        ]
    }
    
    @discardableResult
    func refreshProfile() async throws -> AppUser {
        let urlString = "\(SupabaseConfig.url)/auth/v1/user"
        guard let url = URL(string: urlString) else { throw SupabaseError(message: "无效URL", type: "url_invalid") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (k,v) in try authHeaders() { request.addValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "获取用户失败"
            throw SupabaseError(message: msg, type: "session_invalid")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let id = json?["id"] as? String ?? ""
        let email = json?["email"] as? String ?? ""
        let userMeta = json?["user_metadata"] as? [String: Any]
        let name = (userMeta?["name"] as? String) ?? ""
        let avatar = (userMeta?["avatarURL"] as? String)
        let appUser = AppUser(id: id, email: email, name: name, avatarURL: avatar)
            await MainActor.run {
                self.currentUser = appUser
                self.isLoggedIn = true
            }
        return appUser
    }
    
    // MARK: - Profile
    func updateName(name: String) async throws {
        let urlString = "\(SupabaseConfig.url)/auth/v1/user"
        guard let url = URL(string: urlString) else { throw SupabaseError(message: "无效URL", type: "url_invalid") }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (k,v) in try authHeaders() { request.addValue(v, forHTTPHeaderField: k) }
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "data": ["name": name]
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "更新姓名失败"
            throw SupabaseError(message: msg, type: "update_error")
        }
        // 更新本地
        if let cu = currentUser {
            await MainActor.run {
                self.currentUser = AppUser(id: cu.id, email: cu.email, name: name, avatarURL: cu.avatarURL)
            }
        } else {
            try await refreshProfile()
        }
    }
    
    func updatePassword(password: String, oldPassword: String) async throws {
        let urlString = "\(SupabaseConfig.url)/auth/v1/user"
        guard let url = URL(string: urlString) else { throw SupabaseError(message: "无效URL", type: "url_invalid") }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (k,v) in try authHeaders() { request.addValue(v, forHTTPHeaderField: k) }
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "password": password
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "更新密码失败"
            throw SupabaseError(message: msg, type: "update_error")
        }
    }
    
    // MARK: - Avatar
    func uploadAvatar(imageData: Data) async throws -> String {
        let user = try await refreshProfile()
        let fileName = "avatar_\(Int(Date().timeIntervalSince1970)).jpg"
        let path = "\(user.id)/\(fileName)"
        let urlString = "\(SupabaseConfig.url)/storage/v1/object/\(SupabaseConfig.avatarsBucket)/\(path)"
        guard let url = URL(string: urlString) else { throw SupabaseError(message: "无效URL", type: "url_invalid") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (k,v) in try authHeaders() { request.addValue(v, forHTTPHeaderField: k) }
        request.addValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, from: imageData)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "上传失败"
            throw SupabaseError(message: msg, type: "upload_error")
        }
        // 公有读取时的公开 URL
        let publicURL = "\(SupabaseConfig.url)/storage/v1/object/public/\(SupabaseConfig.avatarsBucket)/\(path)"
        // 写入 user metadata
        try await saveUserAvatarURL(url: publicURL)
            await MainActor.run {
            if let cu = self.currentUser {
                self.currentUser = AppUser(id: cu.id, email: cu.email, name: cu.name, avatarURL: publicURL)
            }
        }
        return publicURL
    }
    
    private func saveUserAvatarURL(url: String) async throws {
        let endpoint = "\(SupabaseConfig.url)/auth/v1/user"
        guard let u = URL(string: endpoint) else { return }
        var request = URLRequest(url: u)
        request.httpMethod = "PUT"
        for (k,v) in try authHeaders() { request.addValue(v, forHTTPHeaderField: k) }
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "data": ["avatarURL": url]
        ])
        _ = try await URLSession.shared.data(for: request)
    }
    
    // MARK: - Conversations Sync (REST skeleton)
    struct ConversationRow: Codable {
        let id: String
        let user_id: String
        let title: String
        let created_at: String
    }
    
    struct MessageRow: Codable {
        let id: String
        let conversation_id: String
        let user_id: String
        let role: String
        let content: String
        let attachments: AnyCodable?
        let created_at: String
    }
    
    // MARK: - Attachment Sync Helper
    private func syncAttachmentToStorage(_ attachment: AttachmentData, messageId: String) async throws -> String? {
        // 这里可以实现将附件上传到Supabase Storage的逻辑
        // 返回存储URL，如果不需要上传则返回nil
        // 目前暂时返回nil，表示使用本地文件路径
        return nil
    }
    
    struct AnyCodable: Codable {}
    
    func syncConversationToServer(conversation: Conversation) async throws {
        guard let user = currentUser else { return }
        // Upsert conversation
        let convBody: [String: Any] = [
            "id": conversation.id.uuidString,
            "user_id": user.id,
            "title": conversation.title,
            "created_at": iso8601(conversation.createdAt)
        ]
        try await postgrestUpsert(path: "/rest/v1/conversations", body: [convBody])
        
        // Upsert messages
        let msgs: [[String: Any]] = conversation.messages.map { msg in
            var attachmentsArray: [[String: Any]] = []
            for att in msg.attachments {
                // 检查文件是否存在，如果不存在则跳过
                let fileURL = URL(fileURLWithPath: att.filePath)
                if FileManager.default.fileExists(atPath: att.filePath) {
                    attachmentsArray.append([
                        "id": att.id.uuidString,
                        "fileName": att.fileName,
                        "fileType": att.fileType,
                        "filePath": att.filePath,
                        "fileSize": (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    ])
                } else {
                    print("Warning: Attachment file not found: \(att.filePath)")
                }
            }
            return [
                "id": msg.id.uuidString,
                "conversation_id": conversation.id.uuidString,
                "user_id": user.id,
                "role": msg.role,
                "content": msg.content,
                "attachments": attachmentsArray,
                "created_at": iso8601(msg.timestamp)
            ]
        }
        if !msgs.isEmpty {
            // 调试：打印附件信息
            for msg in msgs {
                if let attachments = msg["attachments"] as? [[String: Any]], !attachments.isEmpty {
                    print("Syncing message with \(attachments.count) attachments")
                    for att in attachments {
                        print("  - \(att["fileName"] ?? "unknown"): \(att["fileType"] ?? "unknown")")
                    }
                }
            }
            try await postgrestUpsert(path: "/rest/v1/messages", body: msgs)
        }
    }
    
    func loadConversationsFromServer() async throws -> [(ConversationRow, [MessageRow])] {
        let headers = try authHeaders()
        // Fetch conversations
        let convURL = URL(string: "\(SupabaseConfig.url)/rest/v1/conversations?select=*&order=created_at.desc")!
        var convReq = URLRequest(url: convURL)
        convReq.httpMethod = "GET"
        convReq.addValue(headers["Authorization"]!, forHTTPHeaderField: "Authorization")
        convReq.addValue(headers["apikey"]!, forHTTPHeaderField: "apikey")
        let (convData, convResp) = try await URLSession.shared.data(for: convReq)
        guard let http1 = convResp as? HTTPURLResponse, (200..<300).contains(http1.statusCode) else { return [] }
        let convRows = try JSONDecoder().decode([ConversationRow].self, from: convData)
        
        var result: [(ConversationRow, [MessageRow])] = []
        for row in convRows {
            let msgURL = URL(string: "\(SupabaseConfig.url)/rest/v1/messages?select=*&conversation_id=eq.\(row.id)&order=created_at")!
            var msgReq = URLRequest(url: msgURL)
            msgReq.httpMethod = "GET"
            msgReq.addValue(headers["Authorization"]!, forHTTPHeaderField: "Authorization")
            msgReq.addValue(headers["apikey"]!, forHTTPHeaderField: "apikey")
            let (msgData, msgResp) = try await URLSession.shared.data(for: msgReq)
            guard let http2 = msgResp as? HTTPURLResponse, (200..<300).contains(http2.statusCode) else { continue }
            let msgRows = try JSONDecoder().decode([MessageRow].self, from: msgData)
            result.append((row, msgRows))
        }
        return result
    }
    
    func startPollingSync(modelContext: ModelContext) {
        if isSyncStarted { return }
        isSyncStarted = true
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            guard let self else { return }
            // Start realtime subscriptions once when polling starts
            self.subscribeRealtime(modelContext: modelContext)
            while !Task.isCancelled {
                do {
                    await self.enqueuePullAndMerge(modelContext: modelContext)
                } catch {
                    // ignore transient errors
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
    
    func stopPollingSync() {
        syncTask?.cancel()
        syncTask = nil
        isSyncStarted = false
        // Unsubscribe and reset realtime flags
        realtimeChannels.forEach { channel in
            Task { await channel.unsubscribe() }
        }
        realtimeChannels.removeAll()
        hasRealtimeSubscribed = false
    }
    
    func pullAndMerge(modelContext: ModelContext) async throws {
        let items = try await loadConversationsFromServer()
            await MainActor.run {
            for (convRow, msgRows) in items {
                // Merge conversation
                let existing = try? modelContext.fetch(FetchDescriptor<Conversation>())
                let local = existing?.first { $0.id.uuidString == convRow.id }
                let conv: Conversation
                if let local = local {
                    conv = local
                    conv.title = convRow.title
                } else {
                    conv = Conversation()
                    conv.id = UUID(uuidString: convRow.id) ?? UUID()
                    conv.title = convRow.title
                    conv.createdAt = parseISO8601(convRow.created_at) ?? Date()
                    modelContext.insert(conv)
                }
                // Merge messages
                var localIds = Set(conv.messages.map { $0.id.uuidString })
                for m in msgRows {
                    if localIds.contains(m.id) { continue }
                    let msg = ChatMessageData(role: m.role, content: m.content)
                    msg.id = UUID(uuidString: m.id) ?? UUID()
                    msg.timestamp = parseISO8601(m.created_at) ?? Date()
                    // 标记为已播放动画的消息（来自云端同步）
                    msg.hasPlayedAnimation = true
                    
                    // 处理附件信息
                    if let attachmentsData = m.attachments as? [[String: Any]] {
                        for attData in attachmentsData {
                            if let idStr = attData["id"] as? String,
                               let fileName = attData["fileName"] as? String,
                               let fileType = attData["fileType"] as? String,
                               let filePath = attData["filePath"] as? String,
                               let id = UUID(uuidString: idStr) {
                                
                                // 检查文件是否存在，如果不存在则跳过
                                if FileManager.default.fileExists(atPath: filePath) {
                                    let attachment = AttachmentData(fileName: fileName, fileType: fileType, filePath: filePath)
                                    attachment.id = id
                                    msg.attachments.append(attachment)
                                } else {
                                    print("Warning: Attachment file not found during sync: \(filePath)")
                                }
                            }
                        }
                    }
                    
                    conv.messages.append(msg)
                    localIds.insert(m.id)
                }
            }
            try? modelContext.save()
        }
    }
    
    // MARK: - Helpers
    private func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
    
    private func parseISO8601(_ str: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: str) ?? ISO8601DateFormatter().date(from: str)
    }
    
    func postgrestUpsert(path: String, body: [[String: Any]]) async throws {
        var req = URLRequest(url: URL(string: "\(SupabaseConfig.url)\(path)")!)
        req.httpMethod = "POST"
        for (k,v) in try authHeaders() { req.addValue(v, forHTTPHeaderField: k) }
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Upsert失败"
            throw SupabaseError(message: msg, type: "upsert_error")
        }
    }

    // MARK: - Deletions
    func deleteConversation(id: String) async throws {
        // 根据 SQL: messages 对 conversations 有 ON DELETE CASCADE
        var req = URLRequest(url: URL(string: "\(SupabaseConfig.url)/rest/v1/conversations?id=eq.\(id)")!)
        req.httpMethod = "DELETE"
        for (k,v) in try authHeaders() { req.addValue(v, forHTTPHeaderField: k) }
        req.addValue("return=minimal", forHTTPHeaderField: "Prefer")
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SupabaseError(message: "删除对话失败", type: "delete_error")
        }
    }
    
    func deleteMessage(id: String) async throws {
        var req = URLRequest(url: URL(string: "\(SupabaseConfig.url)/rest/v1/messages?id=eq.\(id)")!)
        req.httpMethod = "DELETE"
        for (k,v) in try authHeaders() { req.addValue(v, forHTTPHeaderField: k) }
        req.addValue("return=minimal", forHTTPHeaderField: "Prefer")
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SupabaseError(message: "删除消息失败", type: "delete_error")
        }
    }

    // MARK: - Enqueue helpers (serialize ops)
    func enqueueUpsert(conversation: Conversation) async {
        await syncQueue.enqueue { [weak self] in
            guard let self else { return }
            do { try await self.syncConversationToServer(conversation: conversation) } catch { }
        }
    }
    
    func enqueueDeleteMessage(id: String) async {
        await syncQueue.enqueue { [weak self] in
            guard let self else { return }
            do { try await self.deleteMessage(id: id) } catch { }
        }
    }
    
    func enqueueDeleteConversation(id: String) async {
        await syncQueue.enqueue { [weak self] in
            guard let self else { return }
            do { 
                try await self.deleteConversation(id: id)
                print("Successfully deleted conversation \(id) from Supabase")
        } catch {
                print("Failed to delete conversation \(id) from Supabase: \(error)")
                // 可以考虑添加重试逻辑或用户通知
            }
        }
    }
    
    // 同步删除函数，用于确保删除成功
    func deleteConversationSync(id: String) async throws {
        try await deleteConversation(id: id)
    }
    
    func enqueuePullAndMerge(modelContext: ModelContext) async {
        await syncQueue.enqueue { [weak self] in
            guard let self else { return }
            do { try await self.pullAndMerge(modelContext: modelContext) } catch { }
        }
    }

    // MARK: - Realtime via supabase-swift SDK
    func subscribeRealtime(modelContext: ModelContext) {
        guard let client = client else { return }
        if hasRealtimeSubscribed { return }
        hasRealtimeSubscribed = true
        // 清理旧订阅（防御性）
        realtimeChannels.forEach { channel in
            Task { await channel.unsubscribe() }
        }
        realtimeChannels.removeAll()
        
        let conversationsChannel = client.realtimeV2.channel("rt-conversations")
        conversationsChannel.onPostgresChange(AnyAction.self, schema: "public", table: "conversations") { _ in
            NotificationCenter.default.post(name: .supabaseDidChange, object: nil)
        }
        Task {
            do { try await conversationsChannel.subscribe() }
            catch { print("Realtime conversations error: \(error)") }
        }
        realtimeChannels.append(conversationsChannel)
        
        let messagesChannel = client.realtimeV2.channel("rt-messages")
        messagesChannel.onPostgresChange(AnyAction.self, schema: "public", table: "messages") { _ in
            NotificationCenter.default.post(name: .supabaseDidChange, object: nil)
        }
        Task {
            do { try await messagesChannel.subscribe() }
            catch { print("Realtime messages error: \(error)") }
        }
        realtimeChannels.append(messagesChannel)
    }
}

// MARK: - SyncQueue (serial executor)
actor SyncQueue {
    private var isRunning = false
    private var tasks: [() async -> Void] = []
    
    func enqueue(_ task: @escaping () async -> Void) async {
        tasks.append(task)
        if !isRunning {
            isRunning = true
            await drain()
        }
    }
    
    private func drain() async {
        while !tasks.isEmpty {
            let t = tasks.removeFirst()
            await t()
        }
        isRunning = false
    }
}

// MARK: - Login View
struct LoginView: View {
    @StateObject private var supabaseService = SupabaseService.shared
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var isRegistering = false
    @State private var isLoading = false
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var logoScale: CGFloat = 0.5
    @State private var logoOpacity: Double = 0
    @State private var titleOffset: CGFloat = 50
    @State private var titleOpacity: Double = 0
    
    let onSkip: () -> Void
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(.systemBackground),
                        Color(.systemGray6)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button("跳过") {
                            onSkip()
                        }
                        .foregroundColor(.gray)
                        .padding()
                    }
                    
                    Spacer()
                    
                    VStack(spacing: 24) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 80))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.orange, .red, .pink],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .scaleEffect(logoScale)
                            .opacity(logoOpacity)
                        
                        Text("Spark")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.orange, .red, .pink],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .offset(y: titleOffset)
                            .opacity(titleOpacity)
                    }
                    .frame(height: geometry.size.height * 0.4)
                    
                    VStack(spacing: 20) {
                        VStack(spacing: 16) {
                            if isRegistering {
                                TextField("姓名", text: $name)
                                    .textFieldStyle(CustomTextFieldStyle())
                            }
                            
                            TextField("邮箱", text: $email)
                                .textFieldStyle(CustomTextFieldStyle())
                                .keyboardType(.emailAddress)
                                .autocapitalization(.none)
                            
                            SecureField("密码", text: $password)
                                .textFieldStyle(CustomTextFieldStyle())
                        }
                        
                        Button(action: {
                            Task {
                                await handleAuth()
                            }
                        }) {
                            HStack {
                                if isLoading {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.8)
                                } else {
                                    Text(isRegistering ? "注册" : "登录")
                                        .font(.headline)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(
                                LinearGradient(
                                    colors: [.orange, .red],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .disabled(isLoading || email.isEmpty || password.isEmpty || (isRegistering && name.isEmpty))
                        
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                isRegistering.toggle()
                            }
                        }) {
                            Text(isRegistering ? "已有账户？点击登录" : "没有账户？点击注册")
                                .font(.subheadline)
                                .foregroundColor(.blue)
                        }
                    }
                    .padding(.horizontal, 32)
                    
                    Spacer()
                }
            }
        }
        .alert("错误", isPresented: $showError) {
            Button("确定") { }
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            startAnimations()
        }
    }
    
    private func startAnimations() {
        withAnimation(.spring(response: 1.0, dampingFraction: 0.6, blendDuration: 0)) {
            logoScale = 1.0
            logoOpacity = 1.0
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.8, blendDuration: 0)) {
                titleOffset = 0
                titleOpacity = 1.0
            }
        }
    }
    
    private func handleAuth() async {
        isLoading = true
        errorMessage = ""
        
        do {
            if isRegistering {
                try await supabaseService.register(email: email, password: password, name: name)
            } else {
                try await supabaseService.login(email: email, password: password)
            }
        } catch {
            await MainActor.run {
                // 处理 Appwrite 特定错误
                if let appError = error as? SupabaseError {
                    switch appError.type {
                    case "invalid_credentials":
                        errorMessage = "邮箱或密码错误"
                    case "user_already_exists":
                        errorMessage = "该邮箱已被注册"
                    case "invalid_email":
                        errorMessage = "输入信息格式不正确"
                    default:
                        errorMessage = appError.message
                    }
                } else {
                    errorMessage = error.localizedDescription
                }
                showError = true
            }
        }
        
        await MainActor.run {
            isLoading = false
        }
    }
}

// MARK: - Custom Text Field Style
struct CustomTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
    }
}





// MARK: - API Configuration Models
struct APIModel: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var modelId: String
    var isDefault: Bool = false
    
    static func == (lhs: APIModel, rhs: APIModel) -> Bool {
        return lhs.id == rhs.id
    }
}

struct APIConfiguration: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var apiKey: String
    var endpoint: String
    var models: [APIModel]
    var isDefault: Bool = false
    
    static func == (lhs: APIConfiguration, rhs: APIConfiguration) -> Bool {
        return lhs.id == rhs.id
    }
}

// MARK: - Settings Model
class AppSettings: ObservableObject {
    @Published var apiConfigurations: [APIConfiguration] = []
    @Published var selectedModelId: String?
    @Published var themeMode: ThemeMode = .system
    @Published var isLocalMode: Bool = UserDefaults.standard.bool(forKey: "app.isLocalMode")
    
    init() {
        loadAPIConfigurations()
    }
    
    // 获取当前选中的模型配置
    var currentModelConfiguration: (config: APIConfiguration, model: APIModel)? {
        guard let selectedModelId = selectedModelId else { return nil }
        
        for config in apiConfigurations {
            if let model = config.models.first(where: { $0.modelId == selectedModelId }) {
                return (config, model)
            }
        }
        return nil
    }
    
    // 获取默认模型配置
    var defaultModelConfiguration: (config: APIConfiguration, model: APIModel)? {
        // 首先查找默认API配置中的默认模型
        if let defaultConfig = apiConfigurations.first(where: { $0.isDefault }),
           let defaultModel = defaultConfig.models.first(where: { $0.isDefault }) {
            return (defaultConfig, defaultModel)
        }
        
        // 如果没有设置默认值，返回第一个配置的第一个模型
        if let firstConfig = apiConfigurations.first,
           let firstModel = firstConfig.models.first {
            return (firstConfig, firstModel)
        }
        
        return nil
    }
    
    private func loadAPIConfigurations() {
        if let data = UserDefaults.standard.data(forKey: "api.configurations"),
           let configurations = try? JSONDecoder().decode([APIConfiguration].self, from: data) {
            self.apiConfigurations = configurations
        } else {
            // 创建默认配置（从旧的设置迁移）
            let defaultApiKey = UserDefaults.standard.string(forKey: "api.key") ?? "put_your_api_key_here"
            let defaultEndpoint = UserDefaults.standard.string(forKey: "api.endpoint") ?? "https://example.com/api/v1/chat/completions"
            let defaultModelId = UserDefaults.standard.string(forKey: "api.model") ?? "put_your_model_id_here"
            
            let defaultModel = APIModel(name: "默认模型", modelId: defaultModelId, isDefault: true)
            let defaultConfig = APIConfiguration(
                name: "默认配置",
                apiKey: defaultApiKey,
                endpoint: defaultEndpoint,
                models: [defaultModel],
                isDefault: true
            )
            
            self.apiConfigurations = [defaultConfig]
            saveAPIConfigurations()
        }
        
        // 加载选中的模型ID
        self.selectedModelId = UserDefaults.standard.string(forKey: "selected.model.id")
        
        // 如果没有选中的模型，使用默认模型
        if selectedModelId == nil, let defaultConfig = defaultModelConfiguration {
            selectedModelId = defaultConfig.model.modelId
        }
    }
    
    func saveAPIConfigurations() {
        if let data = try? JSONEncoder().encode(apiConfigurations) {
            UserDefaults.standard.set(data, forKey: "api.configurations")
        }
        
        if let selectedModelId = selectedModelId {
            UserDefaults.standard.set(selectedModelId, forKey: "selected.model.id")
        }
    }
    
    func selectModel(_ modelId: String) {
        DispatchQueue.main.async {
            self.selectedModelId = modelId
            UserDefaults.standard.set(modelId, forKey: "selected.model.id")
        }
    }
    
    func addAPIConfiguration(_ config: APIConfiguration) {
        apiConfigurations.append(config)
        saveAPIConfigurations()
    }
    
    func updateAPIConfiguration(_ config: APIConfiguration) {
        if let index = apiConfigurations.firstIndex(where: { $0.id == config.id }) {
            apiConfigurations[index] = config
            saveAPIConfigurations()
        }
    }
    
    func deleteAPIConfiguration(_ config: APIConfiguration) {
        apiConfigurations.removeAll { $0.id == config.id }
        saveAPIConfigurations()
    }
    
    func setDefaultConfiguration(_ config: APIConfiguration) {
        for i in 0..<apiConfigurations.count {
            apiConfigurations[i].isDefault = (apiConfigurations[i].id == config.id)
        }
        saveAPIConfigurations()
    }
    
    func setDefaultModel(in configId: UUID, modelId: UUID) {
        if let configIndex = apiConfigurations.firstIndex(where: { $0.id == configId }) {
            for i in 0..<apiConfigurations[configIndex].models.count {
                apiConfigurations[configIndex].models[i].isDefault = (apiConfigurations[configIndex].models[i].id == modelId)
            }
            saveAPIConfigurations()
        }
    }
    
    enum ThemeMode: String, CaseIterable {
        case system = "自适应"
        case light = "亮色"
        case dark = "暗色"
    }
    
    func setLocalMode(_ enabled: Bool) {
        if isLocalMode == enabled { return }
        isLocalMode = enabled
        UserDefaults.standard.set(enabled, forKey: "app.isLocalMode")
        print(enabled ? "🏠 切换到本地模式" : "☁️ 切换到云端模式")
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.createdAt, order: .reverse) private var conversations: [Conversation]
    @StateObject private var settings = AppSettings()
    @StateObject private var supabaseService = SupabaseService.shared
    @State private var showingSidebar = false
    @State private var currentConversation: Conversation?
    @State private var searchText = ""
    @State private var sidebarOffset: CGFloat = 0
    @State private var isDragging = false
    @State private var showingLogin = false
    @State private var isFirstLaunch: Bool = !UserDefaults.standard.bool(forKey: "app.hasLaunchedBefore")
    
    var body: some View {
        TabView {
            // 聊天：主页面=会话列表，点进具体会话展示 ChatView
            NavigationView {
                ConversationsHomeView(
                        conversations: conversations,
                        currentConversation: $currentConversation,
                        settings: settings,
                    supabaseService: supabaseService,
                    onOpen: { conv in withAnimation(.easeInOut(duration: 0.25)) { currentConversation = conv } },
                    onCreate: { createNewConversation() }
                )
            }
            .tabItem {
                Image(systemName: "message")
                Text("聊天")
            }

            NavigationView {
                Text("图书馆功能正在开发中，敬请期待～").foregroundColor(.secondary)
            }
            .tabItem {
                Image(systemName: "books.vertical")
                Text("图书馆")
            }

            NavigationView {
                CombinedSettingsView(settings: settings, onDismiss: {})
            }
            .tabItem {
                Image(systemName: "gearshape")
                Text("设置")
            }
        }
        // 聊天详情以叠加+横向滑动过渡呈现，模拟现代IM右进左出
        .task { await initializeAppFlow() }
        .onReceive(NotificationCenter.default.publisher(for: .supabaseDidChange)) { _ in
            Task { await SupabaseService.shared.enqueuePullAndMerge(modelContext: modelContext) }
        }
        .onChange(of: settings.isLocalMode) { _, newValue in
            // 当从本地切换到云端且未登录时，弹出登录页
            if newValue == false {
                if supabaseService.isLoggedIn {
                    supabaseService.startPollingSync(modelContext: modelContext)
                } else {
                    showingLogin = true
                }
            } else {
                supabaseService.stopPollingSync()
            }
        }
        // 旧的侧边栏 UI 已移除
        .preferredColorScheme(colorScheme)
        .fullScreenCover(isPresented: $showingLogin) {
            LoginView {
                // 用户点击跳过按钮
                settings.setLocalMode(true)
            }
        }
        .overlay(
            Group {
                if let conv = currentConversation {
                    ChatScreen(
                        conversation: Binding(get: { conv }, set: { _ in }),
                        settings: settings,
                        onBack: { withAnimation(.easeInOut(duration: 0.25)) { currentConversation = nil } }
                    )
                    .background(Color(UIColor.systemBackground).ignoresSafeArea())
                    .transition(.move(edge: .trailing))
                    .zIndex(2)
                }
            }
        )
        .animation(.easeInOut(duration: 0.25), value: currentConversation != nil)
        .onAppear {
            if conversations.isEmpty {
                createNewConversation()
            } else {
                currentConversation = conversations.first
            }
            if isFirstLaunch == true {
                UserDefaults.standard.set(true, forKey: "app.hasLaunchedBefore")
                isFirstLaunch = false
            }
        }
        .onReceive(supabaseService.$isLoggedIn) { loggedIn in
            if loggedIn {
                showingLogin = false
                // 登录成功后自动开始同步
                supabaseService.startPollingSync(modelContext: modelContext)
                // 切换到云端模式以刷新全局UI
                settings.setLocalMode(false)
                // 登录后刷新资料，确保设置页立即更新头像/名称
                Task { try? await supabaseService.refreshProfile() }
            }
        }
    }
    
    private var colorScheme: ColorScheme? {
        switch settings.themeMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    
    private func createNewConversation() {
        let newConversation = Conversation()
        modelContext.insert(newConversation)
        try? modelContext.save()
        currentConversation = newConversation
        Task { await SupabaseService.shared.enqueueUpsert(conversation: newConversation) }
    }
    
    private func calculateSidebarOffset() -> CGFloat {
        let sidebarWidth = UIScreen.main.bounds.width * 0.8
        
        if isDragging {
            return sidebarOffset
        } else {
            return showingSidebar ? 0 : -sidebarWidth
        }
    }
    
    private func openSidebar() {
        withAnimation(.interpolatingSpring(stiffness: 300, damping: 30)) {
            showingSidebar = true
        }
        // 振动反馈
        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
        impactFeedback.impactOccurred()
    }
    
    private func closeSidebar() {
        withAnimation(.interpolatingSpring(stiffness: 300, damping: 30)) {
            showingSidebar = false
        }
        // 振动反馈
        let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
        impactFeedback.impactOccurred()
    }
}

// MARK: - Profile Refresh helper
extension View {
    @MainActor
    func refreshProfileAndAvatarIfNeeded() async {
        let service = SupabaseService.shared
        do {
            try await service.refreshProfile()
        } catch {
            // 忽略刷新失败
        }
    }
}

// MARK: - Service helpers
extension SupabaseService {
    @MainActor
    static func sharedRefreshAndSync(conversation: Conversation) async {
        do {
            try await SupabaseService.shared.syncConversationToServer(conversation: conversation)
        } catch {
            // ignore
        }
    }
}

// MARK: - App Flow helpers
extension ContentView {
    @MainActor
    fileprivate func initializeAppFlow() async {
        // 非首次启动默认直接进入聊天页面，首次按登录态决定
        if isFirstLaunch {
            showingLogin = !settings.isLocalMode && !supabaseService.isLoggedIn
        } else {
            showingLogin = false
        }
        // 刷新会话；若失败且非本地模式则要求登录
        do {
            try await supabaseService.refreshProfile()
        } catch {
            if !settings.isLocalMode { showingLogin = true }
        }
        // 启动轮询同步
        supabaseService.startPollingSync(modelContext: modelContext)
    }
}

// MARK: - Chat View
struct ChatView: View {
    @Binding var conversation: Conversation?
    @Binding var showingSidebar: Bool
    let settings: AppSettings
    @Environment(\.modelContext) private var modelContext
    
    @State private var messageText = ""
    @State private var isLoading = false
    @State private var llmChat: LLMChatOpenAI?
    @State private var currentTask: Task<Void, Never>?
    @State private var showingImagePicker = false
    @State private var showingDocumentPicker = false
    @State private var showingCamera = false
    @State private var showingActionSheet = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var pendingAttachments: [AttachmentData] = []
    @State private var showingModelSelector = false
    
    // 当嵌入 ChatScreen 时，关闭内部头部
    var showHeader: Bool = true
    
    var body: some View {
        VStack(spacing: 0) {
            // 会话页面需要不透明背景，避免看到下层列表
            Color(UIColor.systemBackground)
                .ignoresSafeArea()
                .frame(height: 0)
            // Navigation Bar - 紧凑设计（可隐藏）
            if showHeader {
            HStack {
                Button(action: {
                    print("Sidebar button tapped, current state: \(showingSidebar)")
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        showingSidebar.toggle()
                    }
                    print("Sidebar button tapped, new state: \(showingSidebar)")
                }) {
                    Image(systemName: "sidebar.left")
                        .font(.title3)
                        .foregroundColor(.primary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(BorderlessButtonStyle())
                
                Spacer()
                
                VStack(spacing: 2) {
                    Text(conversation?.title ?? "新对话")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    
                    if let currentModel = settings.currentModelConfiguration {
                        Text(currentModel.model.name)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                // 模型选择器按钮（会话页面保留，已移除"新建对话"）
                Button(action: { showingModelSelector = true }) {
                    Image(systemName: "cpu")
                        .font(.title3)
                        .foregroundColor(.primary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(BorderlessButtonStyle())
                .sheet(isPresented: $showingModelSelector) { ModelSelectorView(settings: settings) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color(UIColor.systemBackground))
                Divider()
            }
                
                // Messages Area
                if let conversation = conversation {
                    if conversation.messages.isEmpty {
                        // Welcome Screen
                        GeometryReader { geometry in
                            VStack(spacing: 24) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 70))
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [.orange, .red, .pink],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                
                                Text("Spark")
                                    .font(.largeTitle)
                                    .fontWeight(.bold)
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [.orange, .red, .pink],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                
                                Text(welcomeMessage)
                                    .font(.title3)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .padding(.horizontal, 32)
                            }
                            .frame(maxWidth: .infinity)
                            .position(x: geometry.size.width / 2, y: geometry.size.height * 0.4)
                        }
                    } else {
                        // Messages List
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 12) {
                                    let orderedMessages = conversation.messages.sorted { lhs, rhs in
                                        if lhs.timestamp == rhs.timestamp { return lhs.id.uuidString < rhs.id.uuidString }
                                        return lhs.timestamp < rhs.timestamp
                                    }
                                    ForEach(Array(orderedMessages.enumerated()), id: \.element.id) { index, message in
                                        MessageBubble(
                                            message: message,
                                            isNewMessage: index == orderedMessages.count - 1 && message.role == "assistant",
                                            onDelete: {
                                                if let messageIndex = conversation.messages.firstIndex(where: { $0.id == message.id }) {
                                                    conversation.messages.remove(at: messageIndex)
                                                    try? modelContext.save()
                                                    // 同步删除后端消息
                                                    Task { await SupabaseService.shared.enqueueDeleteMessage(id: message.id.uuidString) }
                                                }
                                            }
                                        )
                                        .id(message.id)
                                    }
                                    
                                    if isLoading && (conversation.messages.isEmpty || (conversation.messages.last?.role == "assistant" && conversation.messages.last?.content.isEmpty == true)) {
                                        ThinkingIndicator()
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                            }
                            .onChange(of: conversation.messages.count) { _, _ in
                                let lastMessage = conversation.messages.sorted { $0.timestamp < $1.timestamp }.last
                                if let lastMessage = lastMessage {
                                    withAnimation {
                                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Spacer()
                    Text("选择或创建一个对话")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                
                // Input Area
                VStack(spacing: 0) {
                    // Attachments Preview
                    if !pendingAttachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(pendingAttachments, id: \.id) { attachment in
                                    AttachmentPreview(attachment: attachment) {
                                        pendingAttachments.removeAll { $0.id == attachment.id }
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                        .padding(.vertical, 8)
                        .background(Color(UIColor.systemGray6))
                    }
                    
                    Divider()
                    
                    HStack(spacing: 12) {
                        Button(action: {
                            print("Attachment button tapped")
                            showingActionSheet = true
                        }) {
                            Image(systemName: "plus")
                                .font(.title2)
                                .foregroundColor(.blue)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        
                        TextField("输入消息...", text: $messageText, axis: .vertical)
                            .padding(8)
                            .background(Color(UIColor.systemBackground))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                            )
                            .lineLimit(1...5)
                        
                        Button(action: {
                            print("Send button tapped")
                            if isLoading {
                                stopGeneration()
                            } else {
                                sendMessage()
                            }
                        }) {
                            Image(systemName: isLoading ? "stop.fill" : "arrow.up.circle.fill")
                                .font(.title2)
                                .foregroundColor(isLoading ? .red : .blue)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading)
                    }
                    .padding()
                }
        }
        // 侧滑打开旧侧边栏已移除
        .task {
            // 进入聊天后再次确保资料刷新与同步开启
            await refreshProfileAndAvatarIfNeeded()
        }
        .onTapGesture {
            // 收起键盘
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            
            if showingSidebar {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                    showingSidebar = false
                }
            }
        }
        .confirmationDialog("选择附件", isPresented: $showingActionSheet, titleVisibility: .visible) {
            Button("相册") {
                print("Photo picker selected")
                showingImagePicker = true
            }
            Button("相机") {
                print("Camera selected")
                showingCamera = true
            }
            Button("文件") {
                print("Document picker selected")
                showingDocumentPicker = true
            }
            Button("取消", role: .cancel) {
                print("Cancelled")
            }
        }
        .photosPicker(isPresented: $showingImagePicker, selection: $selectedPhotos, maxSelectionCount: 5, matching: .images)
        .fileImporter(isPresented: $showingDocumentPicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            handleDocumentSelection(result)
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraView { image in
                handleCameraImage(image)
            }
        }
        .onChange(of: settings.selectedModelId) { _, _ in
            setupLLMChat()
        }
        .onChange(of: settings.apiConfigurations) { _, _ in
            setupLLMChat()
        }
        .onChange(of: selectedPhotos) { _, newPhotos in
            Task {
                for photo in newPhotos {
                    if let data = try? await photo.loadTransferable(type: Data.self) {
                        let fileName = "photo_\(Date().timeIntervalSince1970).jpg"
                        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        let filePath = documentsPath.appendingPathComponent(fileName)
                        
                        do {
                            try data.write(to: filePath)
                            let attachment = AttachmentData(fileName: fileName, fileType: "image", filePath: filePath.path)
                            await MainActor.run {
                                pendingAttachments.append(attachment)
                                print("Added image attachment: \(fileName), path: \(filePath.path)")
                            }
                        } catch {
                            print("Error saving photo: \(error)")
                        }
                    }
                }
                selectedPhotos.removeAll()
            }
        }
        .onAppear {
            setupLLMChat()
            testNetworkConnection()
        }
    }
    
    private var welcomeMessage: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:
            return "早上好，我能为你做什么？"
        case 12..<18:
            return "下午好，有什么可以帮助你的吗？"
        case 18..<22:
            return "晚上好，今天过得怎么样？"
        default:
            return "夜深了，还在工作吗？我能帮你什么？"
        }
    }
    
    private func setupLLMChat() {
        guard let currentConfig = settings.currentModelConfiguration ?? settings.defaultModelConfiguration else {
            print("No API configuration available")
            return
        }
        
        print("Setting up LLMChat with:")
        print("Config: \(currentConfig.config.name)")
        print("API Key: \(currentConfig.config.apiKey.prefix(10))...")
        print("Endpoint: \(currentConfig.config.endpoint)")
        print("Model: \(currentConfig.model.name) (\(currentConfig.model.modelId))")
        
        if let url = URL(string: currentConfig.config.endpoint) {
            llmChat = LLMChatOpenAI(
                apiKey: currentConfig.config.apiKey,
                endpoint: url
            )
            print("LLMChat initialized with custom endpoint")
        } else {
            llmChat = LLMChatOpenAI(apiKey: currentConfig.config.apiKey)
            print("LLMChat initialized with default endpoint")
        }
    }
    
    private func createNewConversation() {
        let newConversation = Conversation()
        modelContext.insert(newConversation)
        try? modelContext.save()
        conversation = newConversation
    }
    
    private func sendMessage() {
        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let conversation = conversation,
              let llmChat = llmChat else { return }
        
        let userMessage = ChatMessageData(role: "user", content: messageText, attachments: pendingAttachments)
        conversation.messages.append(userMessage)
        
        // Save user message first to ensure proper ordering
        try? modelContext.save()
        Task { await SupabaseService.shared.enqueueUpsert(conversation: conversation) }
        
        let userContent = messageText
        messageText = ""
        pendingAttachments.removeAll()
        isLoading = true
        
        // Update conversation title if it's the first message
        if conversation.messages.count == 1 {
            conversation.title = String(userContent.prefix(20)) + (userContent.count > 20 ? "..." : "")
        }
        
        // Prepare messages for API with Vision support - 只发送用户消息，不包含AI回复
        let userMessages = conversation.messages.filter { $0.role == "user" }
        let apiMessages = userMessages.map { msg in
            if msg.role == "user" {
                // Check if there are image attachments
                let imageAttachments = msg.attachments.filter { $0.fileType == "image" }
                
                if !imageAttachments.isEmpty {
                    // Create content parts for vision API
                    var contentParts: [ChatMessage.Content] = []
                    
                    // Add text content if not empty
                    if !msg.content.isEmpty {
                        contentParts.append(.text(msg.content))
                    }
                    
                    // Add image attachments
                    for attachment in imageAttachments {
                        if let imageData = loadImageData(from: attachment.filePath) {
                            let base64String = imageData.base64EncodedString()
                            let dataURL = "data:image/jpeg;base64,\(base64String)"
                            contentParts.append(.image(dataURL, detail: .high))
                            print("Added image to API message: \(attachment.fileName)")
                        }
                    }
                    
                    // Create message with content parts
                    return ChatMessage(role: .user, content: contentParts)
                } else {
                    // Text only message
                    return ChatMessage(role: .user, content: msg.content)
                }
            } else {
                return ChatMessage(role: .assistant, content: msg.content)
            }
        }
        
        currentTask = Task {
            do {
                print("Starting API request...")
                let currentModelId = settings.currentModelConfiguration?.model.modelId ?? settings.defaultModelConfiguration?.model.modelId ?? "default"
                print("Model: \(currentModelId)")
                print("Messages count: \(apiMessages.count)")
                
                // Debug: Print message content
                for (index, message) in apiMessages.enumerated() {
                    print("Message \(index): role=\(message.role)")
                    print("  Content: \(String(describing: message.content).prefix(100))...")
                }
                
                // Create assistant message with a timestamp after user message
                try await Task.sleep(nanoseconds: 1_000_000) // 1ms delay to ensure later timestamp
                let assistantMessage = ChatMessageData(role: "assistant", content: "")
                await MainActor.run {
                    conversation.messages.append(assistantMessage)
                    try? modelContext.save()
                }
                
                // Try streaming first for better user experience
                do {
                    print("Attempting streaming...")
                    
                    var tokenCount = 0
                    let modelId = settings.currentModelConfiguration?.model.modelId ?? settings.defaultModelConfiguration?.model.modelId ?? "default"
                    for try await chunk in llmChat.stream(model: modelId, messages: apiMessages) {
                        if let content = chunk.choices.first?.delta.content {
                            tokenCount += 1
                            
                            await MainActor.run {
                                assistantMessage.content += content
                                // 添加振动反馈 - 与MarkdownMessageView保持一致
                                if tokenCount % 8 == 0 {
                                    let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                                    impactFeedback.impactOccurred()
                                }
                            }
                            
                            // Save every 10 tokens to prevent data loss
                            if tokenCount % 10 == 0 {
                                try? modelContext.save()
                            }
                        }
                    }
                } catch {
                    print("Streaming failed: \(error)")
                    
                    // Remove the empty message and create a new one with full content
                    await MainActor.run {
                        if let lastMessage = conversation.messages.last, lastMessage.content.isEmpty {
                            conversation.messages.removeLast()
                        }
                    }
                    
                    // Fallback to regular completion
                    print("Attempting regular completion...")
                    let modelId = settings.currentModelConfiguration?.model.modelId ?? settings.defaultModelConfiguration?.model.modelId ?? "default"
                    let completion = try await llmChat.send(model: modelId, messages: apiMessages)
                    print("Received completion response")
                    
                    if let content = completion.choices.first?.message.content {
                        let newAssistantMessage = ChatMessageData(role: "assistant", content: content)
                        await MainActor.run {
                            conversation.messages.append(newAssistantMessage)
                            print("Content updated: \(content.prefix(50))...")
                        }
                    } else {
                        print("No content in response")
                        let errorMessage = ChatMessageData(role: "assistant", content: "收到了空响应")
                        await MainActor.run {
                            conversation.messages.append(errorMessage)
                        }
                    }
                }
                
                await MainActor.run {
                    isLoading = false
                    try? modelContext.save()
                    print("Message saved successfully")
                }
                // 助手消息保存后做一次上行同步
                Task { await SupabaseService.shared.enqueueUpsert(conversation: conversation) }
            } catch {
                await MainActor.run {
                    isLoading = false
                    if let lastMessage = conversation.messages.last, lastMessage.role == "assistant" {
                        conversation.messages.removeLast()
                    }
                    
                    // Detailed error handling
                    var errorMessage = "网络连接失败"
                    
                    if let llmError = error as? LLMChatOpenAIError {
                        switch llmError {
                        case .serverError(let statusCode, let message):
                            errorMessage = "服务器错误 [\(statusCode)]: \(message)"
                        case .networkError(let networkError):
                            errorMessage = "网络错误: \(networkError.localizedDescription)"
                        case .decodingError(let decodingError):
                            errorMessage = "响应解析错误: \(decodingError.localizedDescription)"
                        case .streamError:
                            errorMessage = "流式响应错误"
                        case .cancelled:
                            errorMessage = "请求已取消"
                        }
                    } else {
                        errorMessage = "未知错误: \(error.localizedDescription)"
                    }
                    
                    let errorMsg = ChatMessageData(role: "assistant", content: "❌ \(errorMessage)")
                    conversation.messages.append(errorMsg)
                    try? modelContext.save()
                    
                    print("Detailed Error: \(error)")
                    if let llmError = error as? LLMChatOpenAIError {
                        print("LLMChatOpenAI Error Type: \(llmError)")
                    }
                }
            }
        }
    }
    
    private func stopGeneration() {
        currentTask?.cancel()
        isLoading = false
    }
    
    private func handleDocumentSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                let fileName = url.lastPathComponent
                let attachment = AttachmentData(fileName: fileName, fileType: "document", filePath: url.path)
                pendingAttachments.append(attachment)
            }
        case .failure(let error):
            print("Document selection error: \(error)")
        }
    }
    
    private func handleCameraImage(_ image: UIImage) {
        // Save image and create attachment
        if let data = image.jpegData(compressionQuality: 0.8) {
            let fileName = "camera_\(Date().timeIntervalSince1970).jpg"
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let filePath = documentsPath.appendingPathComponent(fileName)
            
            do {
                try data.write(to: filePath)
                let attachment = AttachmentData(fileName: fileName, fileType: "image", filePath: filePath.path)
                pendingAttachments.append(attachment)
                print("Added camera image attachment: \(fileName), path: \(filePath.path)")
            } catch {
                print("Error saving camera image: \(error)")
            }
        }
    }
    
    private func loadImageData(from filePath: String) -> Data? {
        let url = URL(fileURLWithPath: filePath)
        do {
            let data = try Data(contentsOf: url)
            print("Loaded image data: \(data.count) bytes from \(filePath)")
            return data
        } catch {
            print("Failed to load image data from \(filePath): \(error)")
            return nil
        }
    }
    
    private func testNetworkConnection() {
        guard let currentConfig = settings.currentModelConfiguration ?? settings.defaultModelConfiguration,
              let url = URL(string: currentConfig.config.endpoint) else {
            print("Invalid endpoint URL or no API configuration")
            return
        }
        
        print("Testing network connection to: \(url)")
        
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let httpResponse = response as? HTTPURLResponse {
                    print("Network test - Status code: \(httpResponse.statusCode)")
                    print("Network test - Headers: \(httpResponse.allHeaderFields)")
                } else {
                    print("Network test - Non-HTTP response")
                }
            } catch {
                print("Network test failed: \(error)")
                if let urlError = error as? URLError {
                    print("URLError code: \(urlError.code)")
                    print("URLError description: \(urlError.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Chat Screen (custom top bar, no nav bar)
struct ChatScreen: View {
    @Binding var conversation: Conversation?
    let settings: AppSettings
    var onBack: () -> Void
    @State private var showModelSelector = false
    @State private var appearOffsetX: CGFloat = UIScreen.main.bounds.width

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.title3)
                        .foregroundColor(.primary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(BorderlessButtonStyle())

                Spacer(minLength: 8)

                VStack(spacing: 2) {
                    Text(conversation?.title ?? "")
                        .font(.subheadline).fontWeight(.medium).lineLimit(1)
                    if let currentModel = settings.currentModelConfiguration {
                        Text(currentModel.model.name)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Button(action: { showModelSelector = true }) {
                    Image(systemName: "cpu")
                        .font(.title3)
                        .foregroundColor(.primary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(BorderlessButtonStyle())
                .sheet(isPresented: $showModelSelector) { ModelSelectorView(settings: settings) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color(UIColor.systemBackground))

            Divider()

            ChatView(
                conversation: $conversation,
                showingSidebar: .constant(false),
                settings: settings,
                showHeader: false
            )
            .navigationBarHidden(true)
            .offset(x: appearOffsetX)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.25)) {
                    appearOffsetX = 0
                }
            }
            .onDisappear { appearOffsetX = UIScreen.main.bounds.width }
        }
        .gesture(
            DragGesture()
                .onEnded { value in
                    if value.startLocation.x < 20 && value.translation.width > 80 {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        onBack()
                    }
                }
        )
    }
}

extension Notification.Name {
    static let openModelSelector = Notification.Name("openModelSelector")
}

// MARK: - Markdown Message View
struct MarkdownMessageView: View {
    let content: String
    let isTyping: Bool
    let message: ChatMessageData // 添加消息引用
    @State private var displayedContent = ""
    @State private var currentIndex = 0
    @State private var hasStartedTyping = false
    @State private var vibrationCounter = 0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !displayedContent.isEmpty {
                MarkdownView(displayedContent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
        .onAppear {
            if isTyping && !content.isEmpty && !hasStartedTyping && !message.hasPlayedAnimation {
                startTypewriterEffect()
            } else if !isTyping || message.hasPlayedAnimation {
                displayedContent = content
                hasStartedTyping = true
            }
        }
        .onChange(of: content) { _, newContent in
            // 如果消息已经播放过动画，直接显示完整内容
            if message.hasPlayedAnimation {
                displayedContent = newContent
                hasStartedTyping = true
                return
            }
            
            if isTyping && !hasStartedTyping && !newContent.isEmpty {
                startTypewriterEffect()
            } else if isTyping && hasStartedTyping && currentIndex < newContent.count {
                continueTypewriterEffect(with: newContent)
            } else if !isTyping {
                displayedContent = newContent
                hasStartedTyping = true
            }
        }
    }
    
    private func startTypewriterEffect() {
        guard !hasStartedTyping && !message.hasPlayedAnimation else { return }
        hasStartedTyping = true
        message.hasPlayedAnimation = true // 标记动画已播放
        displayedContent = ""
        currentIndex = 0
        vibrationCounter = 0
        continueTypewriterEffect(with: content)
    }
    
    private func continueTypewriterEffect(with text: String) {
        guard currentIndex < text.count && hasStartedTyping else { return }
        
        let index = text.index(text.startIndex, offsetBy: currentIndex)
        displayedContent = String(text[..<index])
        currentIndex += 1
        vibrationCounter += 1
        
        // 更细腻更频繁的振动反馈：轻触+更高频率
        if vibrationCounter % 4 == 0 {
            let impactFeedback = UIImpactFeedbackGenerator(style: .light)
            impactFeedback.impactOccurred(intensity: 0.6)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            continueTypewriterEffect(with: text)
        }
    }
}

// MARK: - Message Bubble
struct MessageBubble: View {
    let message: ChatMessageData
    let isNewMessage: Bool // 新增参数来判断是否是新消息
    let onDelete: () -> Void // 添加删除回调
    @State private var showingContextMenu = false
    @State private var displayedText = ""
    @State private var isTyping = false
    
    init(message: ChatMessageData, isNewMessage: Bool = false, onDelete: @escaping () -> Void = {}) {
        self.message = message
        self.isNewMessage = isNewMessage
        self.onDelete = onDelete
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.role == "assistant" {
                // AI消息在左侧
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        if !message.content.isEmpty {
                            MarkdownMessageView(content: message.content, isTyping: isNewMessage, message: message)
                                .frame(maxWidth: UIScreen.main.bounds.width * 0.9, alignment: .leading)
                        }
                    }
                    .contextMenu {
                        Button("复制") {
                            UIPasteboard.general.string = message.content
                        }
                        Button("删除", role: .destructive) {
                            onDelete()
                        }
                        Button("选择文本") {
                            showTextSelection()
                        }
                    }
                    
                    Spacer(minLength: 0)
                }
            } else {
                // 用户消息在右侧
                HStack(alignment: .top, spacing: 0) {
                    Spacer(minLength: 0)
                    
                    VStack(alignment: .trailing, spacing: 4) {
                        // Attachments
                        if !message.attachments.isEmpty {
                            ForEach(message.attachments, id: \.id) { attachment in
                                AttachmentBubble(attachment: attachment)
                            }
                        }
                        
                        if !message.content.isEmpty {
                            Text(message.content)
                                .padding(12)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .frame(maxWidth: UIScreen.main.bounds.width * 0.75, alignment: .trailing)
                        }
                    }
                    .contextMenu {
                        Button("复制") {
                            UIPasteboard.general.string = message.content
                        }
                        Button("删除", role: .destructive) {
                            onDelete()
                        }
                        Button("选择文本") {
                            showTextSelection()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
    
    private func showTextSelection() {
        // 创建一个可选择文本的视图控制器
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController {
            
            let textViewController = UIViewController()
            textViewController.view.backgroundColor = UIColor.systemBackground
            
            // 创建标题栏
            let titleLabel = UILabel()
            titleLabel.text = "选择文本"
            titleLabel.font = UIFont.boldSystemFont(ofSize: 18)
            titleLabel.textAlignment = .center
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            
            // 创建完成按钮
            let doneButton = UIButton(type: .system)
            doneButton.setTitle("完成", for: .normal)
            doneButton.titleLabel?.font = UIFont.systemFont(ofSize: 16)
            doneButton.addTarget(textViewController, action: #selector(UIViewController.dismissModal), for: .touchUpInside)
            doneButton.translatesAutoresizingMaskIntoConstraints = false
            
            // 创建分隔线
            let separatorView = UIView()
            separatorView.backgroundColor = UIColor.separator
            separatorView.translatesAutoresizingMaskIntoConstraints = false
            
            // 创建文本视图
            let textView = UITextView()
            textView.text = message.content
            textView.isEditable = false
            textView.isSelectable = true
            textView.font = UIFont.systemFont(ofSize: 16)
            textView.backgroundColor = UIColor.systemBackground
            textView.translatesAutoresizingMaskIntoConstraints = false
            
            // 添加所有子视图
            textViewController.view.addSubview(titleLabel)
            textViewController.view.addSubview(doneButton)
            textViewController.view.addSubview(separatorView)
            textViewController.view.addSubview(textView)
            
            // 设置约束
            NSLayoutConstraint.activate([
                // 标题约束
                titleLabel.topAnchor.constraint(equalTo: textViewController.view.safeAreaLayoutGuide.topAnchor, constant: 16),
                titleLabel.centerXAnchor.constraint(equalTo: textViewController.view.centerXAnchor),
                
                // 完成按钮约束
                doneButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
                doneButton.trailingAnchor.constraint(equalTo: textViewController.view.trailingAnchor, constant: -16),
                
                // 分隔线约束
                separatorView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
                separatorView.leadingAnchor.constraint(equalTo: textViewController.view.leadingAnchor),
                separatorView.trailingAnchor.constraint(equalTo: textViewController.view.trailingAnchor),
                separatorView.heightAnchor.constraint(equalToConstant: 0.5),
                
                // 文本视图约束
                textView.topAnchor.constraint(equalTo: separatorView.bottomAnchor, constant: 16),
                textView.leadingAnchor.constraint(equalTo: textViewController.view.leadingAnchor, constant: 16),
                textView.trailingAnchor.constraint(equalTo: textViewController.view.trailingAnchor, constant: -16),
                textView.bottomAnchor.constraint(equalTo: textViewController.view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
            ])
            
            // 自动全选文本
            DispatchQueue.main.async {
                textView.selectAll(nil)
            }
            
            rootViewController.present(textViewController, animated: true)
        }
    }
}

// MARK: - Typewriter Text
struct TypewriterText: View {
    let text: String
    @Binding var displayedText: String
    @Binding var isTyping: Bool
    
    var body: some View {
        HStack {
            Text(displayedText)
                .multilineTextAlignment(.leading)
            
            if isTyping {
                Text("▋")
                    .foregroundColor(.blue)
                    .opacity(0.7)
                    .animation(
                        Animation.easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                        value: isTyping
                    )
            }
            
            Spacer()
        }
    }
}

// MARK: - Thinking Indicator
struct ThinkingIndicator: View {
    @State private var animationOffset: CGFloat = 0
    
    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 8, height: 8)
                        .scaleEffect(animationOffset == CGFloat(index) ? 1.2 : 0.8)
                        .animation(
                            Animation.easeInOut(duration: 0.6)
                                .repeatForever()
                                .delay(Double(index) * 0.2),
                            value: animationOffset
                        )
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.blue.opacity(0.3), lineWidth: 1)
            )
            
            Spacer()
        }
        .onAppear {
            animationOffset = 2
        }
    }
}

// MARK: - Sidebar View
struct SidebarView: View {
    let conversations: [Conversation]
    @Binding var currentConversation: Conversation?
    @Binding var showingSidebar: Bool
    @Binding var searchText: String
    let settings: AppSettings
    let supabaseService: SupabaseService
    @Environment(\.modelContext) private var modelContext
    @State private var showingSettings = false
    
    var filteredConversations: [Conversation] {
        if searchText.isEmpty {
            return conversations
        } else {
            return conversations.filter { conversation in
                conversation.title.localizedCaseInsensitiveContains(searchText) ||
                conversation.messages.contains { $0.content.localizedCaseInsensitiveContains(searchText) }
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Search Bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                
                TextField("搜索对话...", text: $searchText)
                    .textFieldStyle(PlainTextFieldStyle())
            }
            .padding(12)
            .background(Color(UIColor.systemGray6))
            .cornerRadius(10)
            .padding()
            
            // Conversations List
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filteredConversations, id: \.id) { conversation in
                        ConversationRow(
                            conversation: conversation,
                            isSelected: currentConversation?.id == conversation.id
                        )
                        .onTapGesture {
                            currentConversation = conversation
                            showingSidebar = false
                        }
                        .contextMenu {
                            Button("重命名") {
                                // Rename logic
                            }
                            Button("以Markdown分享") {
                                shareAsMarkdown(conversation)
                            }
                            Button("删除", role: .destructive) {
                                deleteConversation(conversation)
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
            
            Spacer()
            
            // 底部用户信息和设置区域
            VStack(spacing: 0) {
                Divider()
                    .padding(.horizontal)
                
                HStack(spacing: 12) {
                    // 用户头像
                    AsyncImage(url: avatarURL) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Circle()
                            .fill(Color.blue.gradient)
                            .overlay(
                                Text(userInitials)
                                    .font(.headline)
                                    .foregroundColor(.white)
                            )
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                    
                    // 用户信息
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.isLocalMode ? "本地用户" : (supabaseService.currentUser?.displayName ?? "用户"))
                            .font(.headline)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text(settings.isLocalMode ? "本地模式" : (supabaseService.currentUser?.email ?? ""))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    // 设置按钮
                    Button(action: {
                        showingSettings = true
                    }) {
                        Image(systemName: "gear")
                            .font(.title2)
                            .foregroundColor(.primary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding()
            }
        }
        .background(Color(UIColor.systemBackground))
        .cornerRadius(20, corners: [.topRight, .bottomRight])
        .overlay(
            RoundedCorner(radius: 20, corners: [.topRight, .bottomRight])
                .stroke(Color.primary.opacity(0.2), lineWidth: 1)
        )
        .shadow(radius: 10)
        .sheet(isPresented: $showingSettings) {
            NavigationView {
                CombinedSettingsView(settings: settings, onDismiss: {
                    showingSettings = false
                })
            }
        }
    }
    
    private var userInitials: String {
        guard let user = supabaseService.currentUser else { return "U" }
        let name = user.displayName
        let components = name.components(separatedBy: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
        } else {
            return String(name.prefix(1)).uppercased()
        }
    }
    
    private var avatarURL: URL? {
        guard let user = supabaseService.currentUser,
              let urlStr = user.avatarURL else { return nil }
        return URL(string: urlStr)
    }
    
    private func deleteConversation(_ conversation: Conversation) {
        let conversationId = conversation.id.uuidString
        
        // 先删除本地数据
        modelContext.delete(conversation)
        do {
            try modelContext.save()
            print("Successfully deleted conversation \(conversationId) from local storage")
        } catch {
            print("Failed to save after deleting conversation \(conversationId): \(error)")
            return // 如果本地删除失败，不继续删除远程
        }
        
        if currentConversation?.id == conversation.id {
            currentConversation = conversations.first { $0.id != conversation.id }
        }
        
        // 同步删除后端对话（级联删除消息），使用重试机制
        Task {
            var retryCount = 0
            let maxRetries = 3
            
            while retryCount < maxRetries {
                do {
                    try await SupabaseService.shared.deleteConversationSync(id: conversationId)
                    print("Successfully deleted conversation \(conversationId) from Supabase")
                    break
                } catch {
                    retryCount += 1
                    print("Failed to delete conversation \(conversationId) from Supabase (attempt \(retryCount)/\(maxRetries)): \(error)")
                    
                    if retryCount < maxRetries {
                        // 等待一段时间后重试
                        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
                    } else {
                        print("Failed to delete conversation \(conversationId) from Supabase after \(maxRetries) attempts")
                    }
                }
            }
        }
    }
    
    private func shareAsMarkdown(_ conversation: Conversation) {
        var markdown = "# \(conversation.title)\n\n"
        
        for message in conversation.messages {
            let role = message.role == "user" ? "用户" : "AI"
            markdown += "## \(role)\n\n\(message.content)\n\n"
        }
        
        let activityVC = UIActivityViewController(
            activityItems: [markdown],
            applicationActivities: nil
        )
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            window.rootViewController?.present(activityVC, animated: true)
        }
    }
}

// MARK: - Conversation Row
struct ConversationRow: View {
    let conversation: Conversation
    let isSelected: Bool
    
    // 使用固定的DateFormatter避免闪烁
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conversation.title)
                .font(.headline)
                .lineLimit(1)
            
            if let lastMessage = conversation.messages.last {
                Text(lastMessage.content)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            
            Text(Self.dateFormatter.string(from: conversation.createdAt))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        .cornerRadius(10)
        .contentShape(Rectangle())
    }
}



// MARK: - Combined Settings View
struct CombinedSettingsView: View {
    @StateObject private var supabaseService = SupabaseService.shared
    @ObservedObject var settings: AppSettings
    @Environment(\.modelContext) private var modelContext
    @Query private var conversations: [Conversation]
    @State private var showingClearAlert = false
    @State private var showingLogoutAlert = false
    
    // User Profile States
    @State private var newName = ""
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isLoading = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showSuccess = false
    @State private var successMessage = ""
    @State private var showingAddAPIConfig = false
    @State private var showingLogin = false
    
    let onDismiss: () -> Void
    
    var body: some View {
        Form {
            // 用户头像和基本信息
            Section {
                HStack {
                    Spacer()
                    
                    VStack(spacing: 16) {
                        AsyncImage(url: settings.isLocalMode ? nil : avatarURL) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Circle()
                                .fill(Color.blue.gradient)
                                .overlay(
                                    Text(settings.isLocalMode ? "本" : userInitials)
                                        .font(.title)
                                        .foregroundColor(.white)
                                )
                        }
                        .frame(width: 80, height: 80)
                        .clipShape(Circle())
                        
                        if !settings.isLocalMode {
                            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                                Text("更换头像")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                        } else {
                            Text("本地模式")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                }
                .padding(.vertical)
            }
            
            // 个人信息编辑（仅在云端模式下显示）
            if !settings.isLocalMode {
                Section("个人信息") {
                    HStack {
                        Text("邮箱")
                        Spacer()
                        Text(supabaseService.currentUser?.email ?? "")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("姓名")
                        TextField("输入姓名", text: $newName)
                            .multilineTextAlignment(.trailing)
                    }
                    
                    Button("更新姓名") {
                        Task {
                            await updateName()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .disabled(newName.isEmpty || isLoading)
                }
                
                // 密码修改
                Section("密码管理") {
                    SecureField("当前密码", text: $currentPassword)
                    SecureField("新密码", text: $newPassword)
                    SecureField("确认新密码", text: $confirmPassword)
                    
                    Button("更新密码") {
                        Task {
                            await updatePassword()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .disabled(currentPassword.isEmpty || newPassword.isEmpty ||
                             confirmPassword.isEmpty || newPassword != confirmPassword || isLoading)
                }
            }
            
            // API 配置管理
            Section("API 配置管理") {
                ForEach(settings.apiConfigurations) { config in
                    NavigationLink(destination: APIConfigurationDetailView(
                        settings: settings,
                        configuration: config
                    )) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(config.name)
                                    .font(.headline)
                                Text("\(config.models.count) 个模型")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            if config.isDefault {
                                Text("默认")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.blue.opacity(0.2))
                                    .foregroundColor(.blue)
                                    .cornerRadius(8)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                }
                .onDelete(perform: deleteAPIConfiguration)
                
                Button("添加新配置") {
                    showingAddAPIConfig = true
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .sheet(isPresented: $showingAddAPIConfig) {
                    NavigationView {
                        AddAPIConfigurationView(settings: settings)
                    }
                }
            }
            
            // 外观设置
            Section("外观") {
                Picker("主题模式", selection: $settings.themeMode) {
                    ForEach(AppSettings.ThemeMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
            }
            
            // 同步模式设置
            Section("同步模式") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(settings.isLocalMode ? "本地模式" : "云端模式")
                            .font(.headline)
                        Text(settings.isLocalMode ? "数据仅存储在本设备" : "数据同步到云端服务器")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button(settings.isLocalMode ? "切换到云端" : "切换到本地") {
                        if settings.isLocalMode {
                            // 从本地模式切换到云端模式，需要登录
                            showingLogin = true
                        } else {
                            // 从云端模式切换到本地模式
                            Task {
                                // 先退出登录
                                try? await supabaseService.logout()
                                // 然后切换到本地模式（保留数据）
                                await MainActor.run {
                                    settings.setLocalMode(true)
                                    onDismiss() // 关闭设置页面
                                }
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .buttonStyle(.bordered)
                    .disabled(isLoading)
                }
            }
            
            // 数据管理
            Section("数据管理") {
                if settings.isLocalMode {
                Button("清除所有对话记录", role: .destructive) {
                    showingClearAlert = true
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                } else {
                    HStack {
                        Text("清除所有对话记录")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("仅本地模式可用")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // 账户操作
                Section("账户操作") {
                if settings.isLocalMode {
                    Button("重新登录") {
                        showingLogin = true
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .foregroundColor(.blue)
                    .disabled(isLoading)
                } else {
                    Button("退出登录") {
                        showingLogoutAlert = true
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .foregroundColor(.red)
                    .disabled(isLoading)
                }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 启动或进入设置页时，云端模式自动刷新头像/资料
            if !settings.isLocalMode {
                try? await supabaseService.refreshProfile()
            }
        }
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    // 点击空白处收起键盘
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
        )
        .onAppear {
            newName = supabaseService.currentUser?.name ?? ""
        }
        .onChange(of: selectedPhoto) { _, newPhoto in
            if let newPhoto = newPhoto {
                Task {
                    await uploadAvatar(photo: newPhoto)
                }
            }
        }
        .onReceive(supabaseService.$isLoggedIn) { loggedIn in
            if loggedIn {
                showingLogin = false
                // 登录成功后自动开始同步
                supabaseService.startPollingSync(modelContext: modelContext)
                // 登录后刷新用户资料，确保头像显示
                Task { try? await supabaseService.refreshProfile() }
            }
        }
        .alert("确认清除", isPresented: $showingClearAlert) {
            Button("取消", role: .cancel) { }
            Button("清除", role: .destructive) {
                clearAllConversations()
            }
        } message: {
            Text("此操作将删除所有对话记录，且无法恢复。")
        }
        .alert("确认退出", isPresented: $showingLogoutAlert) {
            Button("取消", role: .cancel) { }
            Button("退出", role: .destructive) {
                Task {
                    await logout()
                }
            }
        } message: {
            Text("确定要退出登录吗？")
        }
        .alert("错误", isPresented: $showError) {
            Button("确定") { }
        } message: {
            Text(errorMessage)
        }
        .alert("成功", isPresented: $showSuccess) {
            Button("确定") { }
        } message: {
            Text(successMessage)
        }
        .sheet(isPresented: $showingLogin) {
            LoginView {
                // 用户点击跳过按钮，保持当前模式
                showingLogin = false
            }
        }
    }
    
    private var userInitials: String {
        guard let user = supabaseService.currentUser else { return "U" }
        let name = user.displayName
        let components = name.components(separatedBy: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
        } else {
            return String(name.prefix(1)).uppercased()
        }
    }
    
    private var avatarURL: URL? {
        guard let user = supabaseService.currentUser,
              let urlStr = user.avatarURL else { return nil }
        return URL(string: urlStr)
    }
    
    private func updateName() async {
        isLoading = true
        
        do {
            try await supabaseService.updateName(name: newName)
            await MainActor.run {
                successMessage = "姓名更新成功"
                showSuccess = true
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
        
        await MainActor.run {
            isLoading = false
        }
    }
    
    private func updatePassword() async {
        guard newPassword == confirmPassword else {
            errorMessage = "新密码和确认密码不匹配"
            showError = true
            return
        }
        
        isLoading = true
        
        do {
            try await supabaseService.updatePassword(password: newPassword, oldPassword: currentPassword)
            await MainActor.run {
                currentPassword = ""
                newPassword = ""
                confirmPassword = ""
                successMessage = "密码更新成功"
                showSuccess = true
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
        
        await MainActor.run {
            isLoading = false
        }
    }
    
    private func uploadAvatar(photo: PhotosPickerItem) async {
        isLoading = true
        
        do {
            if let data = try await photo.loadTransferable(type: Data.self) {
                let _ = try await supabaseService.uploadAvatar(imageData: data)
                
                await MainActor.run {
                    successMessage = "头像更新成功"
                    showSuccess = true
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = "头像上传失败: \(error.localizedDescription)"
                showError = true
            }
        }
        
        await MainActor.run {
            isLoading = false
        }
    }
    
    private func logout() async {
        do {
            try await supabaseService.logout()
            
            // 清除所有本地数据（从云端下载的数据）
            await clearAllCloudData()
            
            // 切换到本地模式
            await MainActor.run {
                settings.setLocalMode(true)
                onDismiss()
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
    
    private func clearAllCloudData() async {
        // 清除所有对话记录（从云端下载的数据）
        await MainActor.run {
            for conversation in conversations {
                modelContext.delete(conversation)
            }
            try? modelContext.save()
        }
    }
    
    private func clearAllConversations() {
        for conversation in conversations {
            modelContext.delete(conversation)
        }
        try? modelContext.save()
    }
    
    private func deleteAPIConfiguration(at offsets: IndexSet) {
        for index in offsets {
            let config = settings.apiConfigurations[index]
            settings.deleteAPIConfiguration(config)
        }
    }
}

// MARK: - QuickLook Preview
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        return controller
    }
    
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let parent: QuickLookPreview
        
        init(_ parent: QuickLookPreview) {
            self.parent = parent
        }
        
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            return 1
        }
        
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            return parent.url as QLPreviewItem
        }
        
        func previewControllerDidDismiss(_ controller: QLPreviewController) {
            parent.dismiss()
        }
    }
}

// MARK: - Attachment Bubble
struct AttachmentBubble: View {
    let attachment: AttachmentData
    @State private var showingPreview = false
    
    var body: some View {
        Button(action: { showingPreview = true }) {
            HStack(spacing: 8) {
                // 如果是图片，显示缩略图
                if attachment.fileType == "image" {
                    AsyncImage(url: URL(fileURLWithPath: attachment.filePath)) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: "photo")
                            .foregroundColor(.white)
                    }
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: "doc")
                        .foregroundColor(.white)
                        .frame(width: 30, height: 30)
                }
                
                Text(attachment.fileName)
                    .font(.caption)
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .padding(6)
            .background(Color.white.opacity(0.2))
            .cornerRadius(8)
        }
        .buttonStyle(PlainButtonStyle())
        .sheet(isPresented: $showingPreview) {
            QuickLookPreview(url: URL(fileURLWithPath: attachment.filePath))
        }
    }
}

// MARK: - Attachment Preview
struct AttachmentPreview: View {
    let attachment: AttachmentData
    let onRemove: () -> Void
    @State private var showingPreview = false
    
    var body: some View {
        HStack(spacing: 8) {
            // 如果是图片，显示缩略图
            if attachment.fileType == "image" {
                Button(action: { showingPreview = true }) {
                    AsyncImage(url: URL(fileURLWithPath: attachment.filePath)) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: "photo")
                .foregroundColor(.blue)
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                Image(systemName: "doc")
                    .foregroundColor(.blue)
                    .frame(width: 40, height: 40)
            }
            
            VStack(alignment: .leading, spacing: 2) {
            Text(attachment.fileName)
                .font(.caption)
                .lineLimit(1)
                
                Button(action: { showingPreview = true }) {
                    Text("预览")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
                .buttonStyle(PlainButtonStyle())
            }
            
            Spacer()
            
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.gray)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(UIColor.systemGray5))
        .cornerRadius(8)
        .sheet(isPresented: $showingPreview) {
            QuickLookPreview(url: URL(fileURLWithPath: attachment.filePath))
        }
    }
}

// MARK: - Camera View
struct CameraView: UIViewControllerRepresentable {
    let onImageCaptured: (UIImage) -> Void
    @Environment(\.presentationMode) var presentationMode
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraView
        
        init(_ parent: CameraView) {
            self.parent = parent
        }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImageCaptured(image)
            }
            parent.presentationMode.wrappedValue.dismiss()
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }
}

// MARK: - Extensions
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

extension UIViewController {
    @objc func dismissModal() {
        dismiss(animated: true, completion: nil)
    }
}

extension UINavigationController {
    @objc func dismissTextSelection() {
        dismiss(animated: true, completion: nil)
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

// MARK: - Add API Configuration View
struct AddAPIConfigurationView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    
    @StateObject private var vm = AddAPIConfigViewModel()
    @State private var newModelName = ""
    @State private var newModelId = ""
    @State private var showingAddModel = false
    
    var body: some View {
            Form {
                Section("配置信息") {
                    TextField("配置名称", text: $vm.configName)
                    SecureField("API Key", text: $vm.apiKey)
                    TextField("API 端点", text: $vm.endpoint)
                }
                
                Section("模型列表") {
                    ForEach(vm.models) { model in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.name)
                                    .font(.headline)
                                Text(model.modelId)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            if model.isDefault {
                                Text("默认")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.blue.opacity(0.2))
                                    .foregroundColor(.blue)
                                    .cornerRadius(8)
                            }
                        }
                        .onTapGesture {
                            setDefaultModel(model)
                        }
                    }
                    .onDelete(perform: deleteModel)
                    
                    Button("添加模型") {
                        showingAddModel = true
                    }
                    .sheet(isPresented: $showingAddModel) {
                        NavigationView {
                            AddModelView(
                                modelName: $newModelName,
                                modelId: $newModelId,
                                onSave: addModel
                            )
                        }
                    }
                }
            }
            .navigationTitle("添加API配置")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        saveConfiguration()
                    }
                    .disabled(vm.configName.isEmpty || vm.apiKey.isEmpty || vm.endpoint.isEmpty || vm.models.isEmpty)
            }
        }
    }
    
    private func addModel() {
        guard !newModelName.isEmpty && !newModelId.isEmpty else { return }
        
        let isFirstModel = vm.models.isEmpty
        let newModel = APIModel(name: newModelName, modelId: newModelId, isDefault: isFirstModel)
        vm.models.append(newModel)
        
        newModelName = ""
        newModelId = ""
        showingAddModel = false
    }
    
    private func deleteModel(at offsets: IndexSet) {
        vm.models.remove(atOffsets: offsets)
        
        // 如果删除了默认模型，设置第一个模型为默认
        if !vm.models.isEmpty && !vm.models.contains(where: { $0.isDefault }) {
            vm.models[0].isDefault = true
        }
    }
    
    private func setDefaultModel(_ model: APIModel) {
        for i in 0..<vm.models.count {
            vm.models[i].isDefault = (vm.models[i].id == model.id)
        }
    }
    
    private func saveConfiguration() {
        let newConfig = APIConfiguration(
            name: vm.configName,
            apiKey: vm.apiKey,
            endpoint: vm.endpoint,
            models: vm.models,
            isDefault: settings.apiConfigurations.isEmpty
        )
        
        settings.addAPIConfiguration(newConfig)
        dismiss()
    }
}

final class AddAPIConfigViewModel: ObservableObject {
    @Published var configName: String = ""
    @Published var apiKey: String = ""
    @Published var endpoint: String = ""
    @Published var models: [APIModel] = []
}

// MARK: - Add Model View
struct AddModelView: View {
    @Binding var modelName: String
    @Binding var modelId: String
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
            Form {
                Section("模型信息") {
                    TextField("模型名称", text: $modelName)
                        .textInputAutocapitalization(.words)
                    TextField("模型ID", text: $modelId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                
                Section {
                    Text("模型名称是显示给用户看的友好名称，模型ID是实际调用API时使用的标识符。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("添加模型")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        onSave()
                    }
                    .disabled(modelName.isEmpty || modelId.isEmpty)
            }
        }
    }
}

// MARK: - API Configuration Detail View
struct APIConfigurationDetailView: View {
    @ObservedObject var settings: AppSettings
    @State private var configuration: APIConfiguration
    @Environment(\.dismiss) private var dismiss
    
    @State private var showingAddModel = false
    @State private var newModelName = ""
    @State private var newModelId = ""
    
    init(settings: AppSettings, configuration: APIConfiguration) {
        self.settings = settings
        // 创建配置的深拷贝，避免直接修改原始配置
        var configCopy = configuration
        // 深拷贝模型数组
        configCopy.models = configuration.models.map { model in
            var modelCopy = model
            return modelCopy
        }
        self._configuration = State(initialValue: configCopy)
    }
    
    var body: some View {
        Form {
            Section("配置信息") {
                TextField("配置名称", text: $configuration.name)
                SecureField("API Key", text: $configuration.apiKey)
                TextField("API 端点", text: $configuration.endpoint)
                
                Toggle("设为默认配置", isOn: Binding(
                    get: { configuration.isDefault },
                    set: { newValue in
                        if newValue {
                            // 先更新本地状态
                            configuration.isDefault = true
                            // 然后更新设置中的配置
                            if let index = settings.apiConfigurations.firstIndex(where: { $0.id == configuration.id }) {
                                settings.apiConfigurations[index].isDefault = true
                                // 清除其他配置的默认状态
                                for i in 0..<settings.apiConfigurations.count {
                                    if i != index {
                                        settings.apiConfigurations[i].isDefault = false
                                    }
                                }
                                settings.saveAPIConfigurations()
                            }
                        } else {
                            // 如果取消默认状态，也要更新本地状态
                            configuration.isDefault = false
                        }
                    }
                ))
            }
            
            Section("模型列表") {
                ForEach(configuration.models) { model in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.name)
                                .font(.headline)
                            Text(model.modelId)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        if model.isDefault {
                            Text("默认")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.2))
                                .foregroundColor(.blue)
                                .cornerRadius(8)
                        }
                    }
                    .onTapGesture {
                        setDefaultModel(model)
                    }
                }
                .onDelete(perform: deleteModel)
                
                Button("添加模型") {
                    showingAddModel = true
                }
                .sheet(isPresented: $showingAddModel) {
                    AddModelView(
                        modelName: $newModelName,
                        modelId: $newModelId,
                        onSave: addModel
                    )
                }
            }
        }
        .navigationTitle("编辑配置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("保存") {
                    // 确保配置信息被正确保存
                    settings.updateAPIConfiguration(configuration)
                    dismiss()
                }
            }
        }
    }
    
    private func addModel() {
        guard !newModelName.isEmpty && !newModelId.isEmpty else { return }
        
        let isFirstModel = configuration.models.isEmpty
        let newModel = APIModel(name: newModelName, modelId: newModelId, isDefault: isFirstModel)
        configuration.models.append(newModel)
        
        newModelName = ""
        newModelId = ""
        showingAddModel = false
    }
    
    private func deleteModel(at offsets: IndexSet) {
        configuration.models.remove(atOffsets: offsets)
        
        // 如果删除了默认模型，设置第一个模型为默认
        if !configuration.models.isEmpty && !configuration.models.contains(where: { $0.isDefault }) {
            configuration.models[0].isDefault = true
        }
    }
    
    private func setDefaultModel(_ model: APIModel) {
        for i in 0..<configuration.models.count {
            configuration.models[i].isDefault = (configuration.models[i].id == model.id)
        }
        settings.setDefaultModel(in: configuration.id, modelId: model.id)
    }
}

// MARK: - Model Selector View
struct ModelSelectorView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            List {
                ForEach(settings.apiConfigurations) { config in
                    Section(config.name) {
                        ForEach(config.models) { model in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.name)
                                        .font(.headline)
                                    Text(model.modelId)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                if settings.selectedModelId == model.modelId {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.blue)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                settings.selectModel(model.modelId)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择模型")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }
}

extension Notification.Name {
    static let supabaseDidChange = Notification.Name("supabaseDidChange")
}

#Preview {
    ContentView()
        .modelContainer(for: [Conversation.self, ChatMessageData.self, AttachmentData.self], inMemory: true)
}

// MARK: - Conversations Home View (as main list)
struct ConversationsHomeView: View {
    let conversations: [Conversation]
    @Binding var currentConversation: Conversation?
    let settings: AppSettings
    let supabaseService: SupabaseService
    var onOpen: (Conversation) -> Void
    var onCreate: () -> Void
    @State private var searchText: String = ""

    var filteredConversations: [Conversation] {
        if searchText.isEmpty { return conversations }
        return conversations.filter { c in
            c.title.localizedCaseInsensitiveContains(searchText) ||
            c.messages.contains { $0.content.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.gray)
                    TextField("搜索对话...", text: $searchText)
                        .textFieldStyle(PlainTextFieldStyle())
                        .submitLabel(.search)
                        .onSubmit {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                }
                .padding(10)
                .background(Color(UIColor.systemGray6))
                .cornerRadius(10)

                Button(action: {
                    if !searchText.isEmpty {
                        // 取消搜索
                        searchText = ""
                    } else {
                        onCreate()
                    }
                }) {
                    if !searchText.isEmpty {
                        Text("取消")
                            .font(.headline)
                    } else {
                        Image(systemName: "plus")
                            .font(.headline)
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .padding()

            if !searchText.isEmpty {
                HStack {
                    Text("共 \(filteredConversations.count) 个结果")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 4)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filteredConversations, id: \.id) { conversation in
                        Button(action: { onOpen(conversation) }) {
                            ConversationRow(conversation: conversation, isSelected: false)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .contextMenu {
                            Button("删除", role: .destructive) {
                                deleteConversation(conversation)
                            }
                            Button("重命名") {
                                renameConversation(conversation)
                            }
                            Button("以Markdown分享") { shareConversationAsMarkdown(conversation) }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .navigationTitle("会话")
        .navigationBarTitleDisplayMode(.inline)
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    // 点击空白区域收起键盘
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
        )
    }

    private func deleteConversation(_ conversation: Conversation) {
        let conversationId = conversation.id.uuidString
        
        // 先删除本地数据
        if let modelContext = conversation.modelContext {
            modelContext.delete(conversation)
            do {
                try modelContext.save()
                print("Successfully deleted conversation \(conversationId) from local storage")
            } catch {
                print("Failed to save after deleting conversation \(conversationId): \(error)")
                return // 如果本地删除失败，不继续删除远程
            }
        }
        
        // 然后同步删除到Supabase，使用重试机制
        Task {
            var retryCount = 0
            let maxRetries = 3
            
            while retryCount < maxRetries {
                do {
                    try await SupabaseService.shared.deleteConversationSync(id: conversationId)
                    print("Successfully deleted conversation \(conversationId) from Supabase")
                    break
                } catch {
                    retryCount += 1
                    print("Failed to delete conversation \(conversationId) from Supabase (attempt \(retryCount)/\(maxRetries)): \(error)")
                    
                    if retryCount < maxRetries {
                        // 等待一段时间后重试
                        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
                    } else {
                        print("Failed to delete conversation \(conversationId) from Supabase after \(maxRetries) attempts")
                        // 可以考虑添加用户通知或回滚本地删除
                    }
                }
            }
        }
    }

    private func renameConversation(_ conversation: Conversation) {
        // 简单重命名：使用当前最后一条消息前20字，实际可用弹窗输入
        let newTitle = String((conversation.messages.last?.content ?? conversation.title).prefix(20))
        
        // 先更新本地数据
        conversation.title = newTitle
        if let modelContext = conversation.modelContext {
            try? modelContext.save()
        }
        
        // 然后同步到Supabase
        Task {
            // 手工Upsert仅包含会话元数据
            let convRow: [String: Any] = [
                "id": conversation.id.uuidString,
                "title": newTitle
            ]
            try? await SupabaseService.shared.postgrestUpsert(path: "/rest/v1/conversations", body: [convRow])
        }
    }
}

// 提供分享Markdown的顶层函数供会话列表使用
private func shareConversationAsMarkdown(_ conversation: Conversation) {
    var markdown = "# \(conversation.title)\n\n"
    for message in conversation.messages {
        let role = message.role == "user" ? "用户" : "AI"
        markdown += "## \(role)\n\n\(message.content)\n\n"
    }
    let activityVC = UIActivityViewController(activityItems: [markdown], applicationActivities: nil)
    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let window = windowScene.windows.first {
        window.rootViewController?.present(activityVC, animated: true)
    }
}
