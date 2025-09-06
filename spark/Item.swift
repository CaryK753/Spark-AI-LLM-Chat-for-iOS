//
//  Item.swift
//  spark
//
//  Created by Cary on 2025/8/31.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}

@Model
final class Conversation {
    var id: UUID
    var title: String
    var createdAt: Date
    var messages: [ChatMessageData]
    
    init(title: String = "新对话") {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.messages = []
    }
}

@Model
final class ChatMessageData {
    var id: UUID
    var role: String // "user" or "assistant"
    var content: String
    var timestamp: Date
    var attachments: [AttachmentData]
    var hasPlayedAnimation: Bool = false // 添加动画播放标记
    
    init(role: String, content: String, attachments: [AttachmentData] = []) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.attachments = attachments
        self.hasPlayedAnimation = false
    }
}

@Model
final class AttachmentData {
    var id: UUID
    var fileName: String
    var fileType: String // "image", "document"
    var filePath: String
    
    init(fileName: String, fileType: String, filePath: String) {
        self.id = UUID()
        self.fileName = fileName
        self.fileType = fileType
        self.filePath = filePath
    }
}
