import Foundation
import Observation

// MARK: - Public Models

struct ChatActionTaken: Codable {
    let type: String
    let description: String
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: ChatRole
    let content: String
    let actions: [ChatActionTaken]
    let timestamp: Date

    enum ChatRole {
        case user
        case assistant
    }
}

// MARK: - Anthropic API Models

private struct AnthropicRequest: Encodable {
    let model: String
    let max_tokens: Int
    let system: String
    let tools: [AnthropicTool]
    let messages: [AnthropicMessage]
}

private struct AnthropicTool: Encodable {
    let name: String
    let description: String
    let input_schema: AnthropicSchema
}

private struct AnthropicSchema: Encodable {
    let type: String
    let properties: [String: AnthropicProperty]
    let required: [String]
}

private struct AnthropicProperty: Encodable {
    let type: String
    let description: String
    var enum_values: [String]?

    enum CodingKeys: String, CodingKey {
        case type, description
        case enum_values = "enum"
    }
}

private struct AnthropicMessage: Encodable {
    let role: String
    let content: AnthropicContent

    enum AnthropicContent: Encodable {
        case text(String)
        case blocks([AnthropicContentBlock])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let s): try container.encode(s)
            case .blocks(let b): try container.encode(b)
            }
        }
    }
}

// MARK: - Content Block (properly encodes only relevant fields per type)

private enum AnthropicContentBlock: Encodable {
    case text(String)
    case toolUse(id: String, name: String, input: [String: AnyCodableValue])
    case toolResult(toolUseId: String, content: String, isError: Bool? = nil)

    private enum CodingKeys: String, CodingKey {
        case type, text, id, name, input
        case tool_use_id, content, is_error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)

        case .toolUse(let id, let name, let input):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)

        case .toolResult(let toolUseId, let content, let isError):
            try container.encode("tool_result", forKey: .type)
            try container.encode(toolUseId, forKey: .tool_use_id)
            try container.encode(content, forKey: .content)
            if let isError { try container.encode(isError, forKey: .is_error) }
        }
    }
}

// MARK: - AnyCodableValue (preserves Int for whole numbers)

private struct AnyCodableValue: Encodable {
    let value: Any

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let v = value as? String { try container.encode(v) }
        else if let v = value as? Int { try container.encode(v) }
        else if let v = value as? Double {
            // Encode whole numbers as Int for clean JSON (e.g. deviceId: 5 not 5.0)
            if v == v.rounded() && v >= Double(Int.min) && v <= Double(Int.max) {
                try container.encode(Int(v))
            } else {
                try container.encode(v)
            }
        }
        else if let v = value as? Bool { try container.encode(v) }
        else { try container.encode(String(describing: value)) }
    }
}

// MARK: - Response Models

private struct AnthropicResponse: Decodable {
    let content: [ResponseBlock]
    let stop_reason: String?
}

private struct ResponseBlock: Decodable {
    let type: String
    let text: String?
    let id: String?
    let name: String?
    let input: [String: JSONValue]?
}

private enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else if let v = try? container.decode(Double.self) { self = .number(v) }
        else if let v = try? container.decode(String.self) { self = .string(v) }
        else { self = .null }
    }

    var stringValue: String? { if case .string(let v) = self { return v } else { return nil } }
    var doubleValue: Double? { if case .number(let v) = self { return v } else { return nil } }
    var intValue: Int? { doubleValue.map { Int($0) } }
}

// MARK: - Tool Definitions

private let chatTools: [AnthropicTool] = [
    AnthropicTool(
        name: "set_device_level",
        description: "Set a light or shade to a specific level (0-100). For lights, 0=off, 100=full brightness. For shades, 0=fully closed, 100=fully open.",
        input_schema: AnthropicSchema(
            type: "object",
            properties: [
                "deviceId": AnthropicProperty(type: "number", description: "The integration ID of the device"),
                "level": AnthropicProperty(type: "number", description: "Target level 0-100"),
                "fadeTime": AnthropicProperty(type: "number", description: "Fade duration in seconds (default 1)"),
            ],
            required: ["deviceId", "level"]
        )
    ),
    AnthropicTool(
        name: "activate_scene",
        description: "Activate a saved scene by its ID, which sets multiple devices to their saved levels.",
        input_schema: AnthropicSchema(
            type: "object",
            properties: [
                "sceneId": AnthropicProperty(type: "string", description: "The scene ID"),
            ],
            required: ["sceneId"]
        )
    ),
]

// MARK: - Chat Service

@Observable
class ChatService: @unchecked Sendable {
    var messages: [ChatMessage] = []
    var isLoading = false
    var errorMessage: String?

    var apiKey: String {
        get { KeychainHelper.loadString(for: "anthropicApiKey") ?? "" }
        set {
            if newValue.isEmpty {
                KeychainHelper.delete(for: "anthropicApiKey")
            } else {
                KeychainHelper.save(newValue, for: "anthropicApiKey")
            }
        }
    }

    var isConfigured: Bool {
        !apiKey.isEmpty
    }

    // MARK: - System Prompt

    private func buildSystemPrompt(store: LutronStore) -> String {
        let devices = Array(store.devices.values).sorted { ($0.room, $0.name) < ($1.room, $1.name) }

        // Group by room
        var roomDevices: [(room: String, devices: [DeviceState])] = []
        var currentRoom = ""
        var currentList: [DeviceState] = []
        for d in devices {
            if d.room != currentRoom {
                if !currentList.isEmpty { roomDevices.append((room: currentRoom, devices: currentList)) }
                currentRoom = d.room
                currentList = []
            }
            currentList.append(d)
        }
        if !currentList.isEmpty { roomDevices.append((room: currentRoom, devices: currentList)) }

        var deviceList = ""
        for group in roomDevices {
            deviceList += "\n## \(group.room)\n"
            for d in group.devices {
                let status: String
                if d.category == .light {
                    status = d.level > 0 ? "ON at \(Int(d.level))%" : "OFF"
                } else if d.type == .shade {
                    status = d.level == 100 ? "fully open" : d.level == 0 ? "fully closed" : "\(Int(d.level))% open"
                } else {
                    status = "\(Int(d.level))%"
                }
                deviceList += "- \(d.name) (id: \(d.integrationId), type: \(d.type.rawValue)) — \(status)\n"
            }
        }

        var sceneList = ""
        for s in store.scenes {
            sceneList += "- \"\(s.name)\" (id: \(s.id)) — sets \(s.targets.count) devices\n"
        }

        return """
        You are a home automation assistant for a Lutron lighting system. You help the user control their lights, shades, and scenes using natural language.

        DEVICES AND CURRENT STATE:
        \(deviceList.isEmpty ? "No devices configured." : deviceList)

        SAVED SCENES:
        \(sceneList.isEmpty ? "None saved." : sceneList)

        RULES:
        - For lights: level 0 = off, 100 = full brightness. Use set_device_level.
        - For shades: level 0 = fully closed, 100 = fully open. Use set_device_level.
        - When controlling multiple devices, make a SEPARATE set_device_level tool call for EACH device. Do not try to batch them.
        - When the user says "turn off all lights", set every light to level 0 using one set_device_level call per light.
        - When the user says "close all shades", set every shade to level 0 using one set_device_level call per shade.
        - When the user references a room or floor, control ALL matching devices in that area.
        - For ambiguous requests, use your best judgment based on room/device names.
        - If a request matches a saved scene, prefer activate_scene.
        - For status queries ("what's on?"), describe the current state without tool calls.
        - Be concise and friendly. Confirm what you did after executing commands.
        - Use a 1-second fade time unless the user specifies otherwise.
        """
    }

    // MARK: - Send Message

    func sendMessage(_ text: String, store: LutronStore) async {
        guard !apiKey.isEmpty else {
            await MainActor.run {
                errorMessage = "API key not configured. Add your Anthropic API key in Settings."
            }
            return
        }

        let userMessage = ChatMessage(role: .user, content: text, actions: [], timestamp: Date())

        await MainActor.run {
            messages.append(userMessage)
            isLoading = true
            errorMessage = nil
        }

        do {
            let result = try await callClaudeAndExecute(text, store: store)

            let assistantMessage = ChatMessage(
                role: .assistant,
                content: result.reply,
                actions: result.actions,
                timestamp: Date()
            )

            await MainActor.run {
                messages.append(assistantMessage)
                isLoading = false
            }
        } catch {
            let errorMsg = ChatMessage(
                role: .assistant,
                content: "Sorry, something went wrong: \(error.localizedDescription)",
                actions: [],
                timestamp: Date()
            )

            await MainActor.run {
                messages.append(errorMsg)
                isLoading = false
            }
        }
    }

    // MARK: - Claude API Call + Tool Execution Loop

    private func callClaudeAndExecute(_ text: String, store: LutronStore) async throws -> (reply: String, actions: [ChatActionTaken]) {
        let systemPrompt = buildSystemPrompt(store: store)
        var actions: [ChatActionTaken] = []

        // Build conversation history
        var apiMessages: [AnthropicMessage] = messages.suffix(20).compactMap { msg in
            guard msg.role == .user || msg.role == .assistant else { return nil }
            return AnthropicMessage(
                role: msg.role == .user ? "user" : "assistant",
                content: .text(msg.content)
            )
        }
        // The new user message is already in self.messages (appended above), so it's the last one

        // First API call
        var response = try await callClaude(system: systemPrompt, messages: apiMessages)

        // Tool use loop — keep calling until Claude stops requesting tools
        while response.stop_reason == "tool_use" {
            let toolBlocks = response.content.filter { $0.type == "tool_use" }

            // Build assistant message with properly-typed content blocks
            var assistantBlocks: [AnthropicContentBlock] = []
            for block in response.content {
                if block.type == "text", let text = block.text {
                    assistantBlocks.append(.text(text))
                } else if block.type == "tool_use", let id = block.id, let name = block.name {
                    var inputMap: [String: AnyCodableValue] = [:]
                    if let input = block.input {
                        for (k, v) in input {
                            switch v {
                            case .string(let s): inputMap[k] = AnyCodableValue(value: s)
                            case .number(let n):
                                // Preserve integer types for clean re-encoding
                                if n == n.rounded() && n >= Double(Int.min) && n <= Double(Int.max) {
                                    inputMap[k] = AnyCodableValue(value: Int(n))
                                } else {
                                    inputMap[k] = AnyCodableValue(value: n)
                                }
                            case .bool(let b): inputMap[k] = AnyCodableValue(value: b)
                            case .null: break
                            }
                        }
                    }
                    assistantBlocks.append(.toolUse(id: id, name: name, input: inputMap))
                }
            }
            apiMessages.append(AnthropicMessage(role: "assistant", content: .blocks(assistantBlocks)))

            // Execute each tool call and build result blocks
            var resultBlocks: [AnthropicContentBlock] = []
            for block in toolBlocks {
                let (resultText, action) = await executeToolCall(
                    name: block.name ?? "",
                    input: block.input ?? [:],
                    store: store
                )
                actions.append(action)
                resultBlocks.append(.toolResult(
                    toolUseId: block.id ?? "",
                    content: resultText
                ))
            }
            apiMessages.append(AnthropicMessage(role: "user", content: .blocks(resultBlocks)))

            response = try await callClaude(system: systemPrompt, messages: apiMessages)
        }

        // Extract text from final response
        let reply = response.content
            .compactMap { $0.text }
            .joined(separator: "\n")

        return (reply: reply.isEmpty ? "Done!" : reply, actions: actions)
    }

    // MARK: - HTTP Call

    private func callClaude(system: String, messages: [AnthropicMessage]) async throws -> AnthropicResponse {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 30

        let body = AnthropicRequest(
            model: "claude-sonnet-4-20250514",
            max_tokens: 1024,
            system: system,
            tools: chatTools,
            messages: messages
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, httpResponse) = try await URLSession.shared.data(for: request)

        guard let resp = httpResponse as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard resp.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "HTTP \(resp.statusCode)"
            throw NSError(domain: "Anthropic", code: resp.statusCode, userInfo: [NSLocalizedDescriptionKey: errorText])
        }

        return try JSONDecoder().decode(AnthropicResponse.self, from: data)
    }

    // MARK: - Tool Execution

    private func executeToolCall(name: String, input: [String: JSONValue], store: LutronStore) async -> (String, ChatActionTaken) {
        switch name {
        case "set_device_level":
            let deviceId = input["deviceId"]?.intValue ?? 0
            let level = input["level"]?.doubleValue ?? 0
            let fadeTime = input["fadeTime"]?.doubleValue ?? 1.0
            let device = store.devices[deviceId]
            let deviceName = device?.name ?? "Device \(deviceId)"

            await MainActor.run {
                store.setLevel(deviceId, level: level, fadeTime: fadeTime)
            }

            let desc: String
            if device?.type == .shade {
                desc = "Set \(deviceName) to \(Int(level))% open"
            } else if level == 0 {
                desc = "Turned off \(deviceName)"
            } else {
                desc = "Set \(deviceName) to \(Int(level))%"
            }
            return ("OK: \(desc)", ChatActionTaken(type: "set_device_level", description: desc))

        case "activate_scene":
            let sceneId = input["sceneId"]?.stringValue ?? ""
            guard let scene = store.scenes.first(where: { $0.id == sceneId }) else {
                return ("Error: Scene not found", ChatActionTaken(type: "activate_scene", description: "Scene not found"))
            }

            await MainActor.run {
                for target in scene.targets {
                    store.setLevel(target.deviceId, level: target.level, fadeTime: 2)
                }
            }

            let desc = "Activated scene \"\(scene.name)\""
            return ("OK: \(desc)", ChatActionTaken(type: "activate_scene", description: desc))

        default:
            return ("Error: Unknown tool \(name)", ChatActionTaken(type: name, description: "Unknown tool"))
        }
    }

    func clearHistory() {
        messages.removeAll()
    }
}
