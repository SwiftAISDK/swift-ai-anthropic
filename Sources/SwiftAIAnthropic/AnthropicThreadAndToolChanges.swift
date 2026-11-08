import Foundation
import SwiftAIProvider
import SwiftAIProviderUtilities

struct AnthropicToolChange {
    var type: String
    var toolName: String?
    var tool: JSONValue?
}

func anthropicParsedToolChanges(_ value: JSONValue?) throws -> [AnthropicToolChange] {
    guard let value else { return [] }
    guard let changes = value.arrayValue else {
        throw AIError.invalidArgument(argument: "providerOptions.anthropic.toolChanges", message: "toolChanges must be an array.")
    }
    return try changes.map { change in
        guard let type = change["type"]?.stringValue, ["tool_addition", "tool_removal"].contains(type) else {
            throw AIError.invalidArgument(argument: "providerOptions.anthropic.toolChanges", message: "Invalid tool change type.")
        }
        if type == "tool_addition", let tool = change["tool"] {
            _ = try anthropicNativeInlineTool(tool)
            return AnthropicToolChange(type: type, tool: tool)
        }
        guard let name = change["toolName"]?.stringValue else {
            throw AIError.invalidArgument(argument: "providerOptions.anthropic.toolChanges", message: "A referenced tool change requires toolName.")
        }
        return AnthropicToolChange(type: type, toolName: name)
    }
}

func anthropicNativeInlineTool(_ tool: JSONValue) throws -> (name: String, schema: JSONValue) {
    guard let name = tool["name"]?.stringValue else {
        throw AIError.invalidArgument(argument: "toolChanges.tool.name", message: "An inline tool requires a name.")
    }
    if tool["type"]?.stringValue == "provider", tool["id"]?.stringValue != nil, tool["args"]?.objectValue != nil {
        return (name, tool)
    }
    guard tool["type"]?.stringValue == "function", var schema = tool["inputSchema"]?.objectValue else {
        throw AIError.invalidArgument(argument: "toolChanges.tool", message: "An inline tool must be a function tool with inputSchema or a provider tool with id and args.")
    }
    for key in ["description", "strict", "inputExamples", "providerOptions"] {
        if let value = tool[key] { schema[key] = value }
    }
    return (name, .object(schema))
}

func anthropicInlineTools(in messages: [AIMessage]) throws -> [String: JSONValue] {
    var tools: [String: JSONValue] = [:]
    for message in messages where message.role == .system {
        for change in try anthropicParsedToolChanges(message.providerMetadata["anthropic"]?["toolChanges"]) {
            guard let tool = change.tool else { continue }
            if tool["type"]?.stringValue == "provider", tool["id"]?.stringValue?.hasPrefix("anthropic.computer_") == true { continue }
            let native = try anthropicNativeInlineTool(tool)
            tools[native.name] = native.schema
        }
    }
    return tools
}

func anthropicValidateThread(_ thread: JSONValue?, body: [String: JSONValue], supported: Bool, providerID: String) throws {
    guard thread != nil else { return }
    guard supported else {
        throw AIError.invalidArgument(argument: "providerOptions.anthropic.thread", message: "\(providerID) does not support Anthropic message threads.")
    }
    let edits = body["context_management"]?["edits"]?.arrayValue ?? []
    if body["compaction"] != nil || edits.contains(where: { $0["type"]?.stringValue != "clear_thinking_20251015" || $0["keep"]?.stringValue != "all" }) {
        throw AIError.invalidArgument(argument: "providerOptions.anthropic.thread", message: "Anthropic message threads do not support compaction or context editing, except clear_thinking_20251015 with keep: \"all\".")
    }
}

func anthropicValidateInlineToolChoice(
    messages: [JSONValue], sourceMessages: [AIMessage], tools: [String: JSONValue], toolChoice: JSONValue?, actualToolChoice: JSONValue?,
    usesJSONResponseTool: Bool, mapping: AIToolNameMapping, body: inout [String: JSONValue]
) throws {
    let choice = toolChoice?["type"]?.stringValue
    guard (choice == "tool" && (actualToolChoice?["type"]?.stringValue == "auto" || usesJSONResponseTool)) || (choice == "none" && usesJSONResponseTool) else { return }
    if let servers = body["mcp_servers"]?.arrayValue {
        body["mcp_servers"] = .array(servers.map { server in
            guard var object = server.objectValue else { return server }
            var configuration = object["tool_configuration"]?.objectValue ?? [:]
            configuration["enabled"] = false
            object["tool_configuration"] = .object(configuration)
            return .object(object)
        })
    }
    let selectedSDKName = toolChoice?["toolName"]?.stringValue ?? toolChoice?["name"]?.stringValue
    let selected = selectedSDKName.map { tools[$0]?["type"]?.stringValue == "provider" ? mapping.toProviderToolName($0) : $0 }
    var visibleInlineNames: [(sdk: String, provider: String)] = []
    var sawConversation = false
    for message in sourceMessages {
        if message.role != .system { sawConversation = true; continue }
        guard sawConversation else { continue }
        for change in try anthropicParsedToolChanges(message.providerMetadata["anthropic"]?["toolChanges"]) {
            guard let tool = change.tool, let name = tool["name"]?.stringValue else { continue }
            visibleInlineNames.append((name, mapping.toProviderToolName(name)))
        }
    }
    for message in messages where message["role"]?.stringValue == "system" {
        for part in message["content"]?.arrayValue ?? [] where part["type"]?.stringValue == "tool_addition" && part["tool"]?["type"]?.stringValue == "tool_definition" {
            let definition = part["tool"]?["definition"]
            let hasConflictingSDKName = usesJSONResponseTool && visibleInlineNames.contains { $0.provider == definition?["name"]?.stringValue && $0.sdk != selectedSDKName }
            if choice == "none" || hasConflictingSDKName || definition?["name"]?.stringValue != selected {
                throw AIError.invalidArgument(argument: "toolChoice", message: "Inline tool '\(definition?["name"]?.stringValue ?? definition?["type"]?.stringValue ?? "unknown")' conflicts with tool choice '\(selectedSDKName ?? "none")'. Inline definitions must respect the tool choice when forced tool use falls back or the JSON response tool is used.")
            }
        }
    }
}

let anthropicComputerToolsetMembers = ["screenshot", "zoom", "left_click", "right_click", "middle_click", "double_click", "triple_click", "left_click_drag", "mouse_move", "left_mouse_down", "left_mouse_up", "cursor_position", "scroll", "type", "key", "hold_key", "wait"]

func anthropicValidateToolsetBlocks(_ blocks: [JSONValue], tools: [JSONValue], providerID: String) throws {
    for block in blocks where block["type"]?.stringValue == "tool_use" && block["toolset_name"] != nil {
        let name = block["name"]?.stringValue ?? ""
        let toolset = tools.first { $0["type"]?.stringValue == "computer_toolset_20260801" }
        guard block["toolset_name"]?.stringValue == "computer", let toolset,
              anthropicComputerToolsetMembers.contains(name), toolset["configs"]?[name]?["enabled"] != false else {
            throw AIError.invalidResponse(provider: providerID, message: "Received an unavailable toolset member: \(block["toolset_name"]?.stringValue ?? "").\(name).")
        }
        if block["input"]?.objectValue == nil {
            throw AIError.invalidResponse(provider: providerID, message: "Invalid toolset member input: expected an object.")
        }
    }
}

func anthropicComputerToolsetSchema(_ configs: [String: JSONValue]?) -> JSONValue {
    let coordinate: JSONValue = ["type": "array", "items": ["type": "integer"], "minItems": 2, "maxItems": 2]
    return ["type": "object", "properties": [
        "action": ["type": "string", "enum": .array(anthropicComputerToolsetMembers.filter { configs?[$0]?["enabled"] != false }.map(JSONValue.string))],
        "coordinate": coordinate, "start_coordinate": coordinate,
        "region": ["type": "array", "items": ["type": "integer"], "minItems": 4, "maxItems": 4],
        "duration": ["type": "number"], "repeat": ["type": "integer"], "scroll_amount": ["type": "number"],
        "scroll_direction": ["type": "string", "enum": ["up", "down", "left", "right"]], "text": ["type": "string"]
    ], "required": ["action"]]
}

func anthropicInlineToolNames(in messages: [AIMessage]) throws -> [String] {
    try messages.filter { $0.role == .system }.flatMap { message in
        try anthropicParsedToolChanges(message.providerMetadata["anthropic"]?["toolChanges"]).compactMap { change in
            guard let tool = change.tool,
                  !(tool["type"]?.stringValue == "provider" && tool["id"]?.stringValue?.hasPrefix("anthropic.computer_") == true) else { return nil }
            return tool["name"]?.stringValue
        }
    }
}
