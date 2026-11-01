import Foundation
import SwiftAIProvider

// Native output grammars cannot represent recursive references or open maps.
// Definitions are visited only through references; instance data is not schema.
func anthropicHasCircularSchemaReference(_ schema: JSONValue) -> Bool {
    var visiting: Set<String> = []
    var visited: Set<String> = []
    func references(_ node: JSONValue) -> [String] {
        if let array = node.arrayValue { return array.flatMap(references) }
        guard let object = node.objectValue else { return [] }
        var result: [String] = []
        for (key, value) in object {
            if key == "$ref" {
                if let ref = value.stringValue, ref.hasPrefix("#") { result.append(ref) }
            } else if ["dependentSchemas", "patternProperties", "properties"].contains(key),
                      let children = value.objectValue {
                result.append(contentsOf: children.values.flatMap(references))
            } else if !["$defs", "definitions", "const", "default", "enum", "examples"].contains(key) {
                result.append(contentsOf: references(value))
            }
        }
        return result
    }
    func visit(_ pointer: String) -> Bool {
        if visiting.contains(pointer) { return true }
        if visited.contains(pointer) { return false }
        guard let target = anthropicResolveSchemaPointer(schema, pointer: pointer) else { return false }
        visiting.insert(pointer)
        let circular = references(target).contains(where: visit)
        visiting.remove(pointer)
        visited.insert(pointer)
        return circular
    }
    return visit("#")
}

func anthropicResolveSchemaPointer(_ schema: JSONValue, pointer: String) -> JSONValue? {
    if pointer == "#" { return schema }
    guard pointer.hasPrefix("#/"), let decoded = String(pointer.dropFirst(2)).removingPercentEncoding else { return nil }
    var current = schema
    for raw in decoded.split(separator: "/", omittingEmptySubsequences: false) {
        let segment = raw.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        if let array = current.arrayValue, let index = Int(segment), array.indices.contains(index) {
            current = array[index]
        } else if let object = current.objectValue, let next = object[segment] {
            current = next
        } else { return nil }
    }
    return current
}

func anthropicSupportsNativeStructuredOutputSchema(_ schema: JSONValue) -> Bool {
    guard !anthropicHasCircularSchemaReference(schema) else { return false }
    struct Stats { var optional = 0; var open = false }
    var cached: [String: Stats] = [:]
    func stats(_ node: JSONValue?) -> Stats {
        guard let object = node?.objectValue else { return Stats() }
        var result = Stats()
        func add(_ child: JSONValue?) {
            let value = stats(child)
            // A bounded count avoids overflow from repeated references.
            result.optional = min(11, result.optional + value.optional)
            result.open = result.open || value.open
        }
        if let ref = object["$ref"]?.stringValue, ref.hasPrefix("#") {
            let value: Stats
            if let existing = cached[ref] { value = existing }
            else {
                value = stats(anthropicResolveSchemaPointer(schema, pointer: ref))
                cached[ref] = value
            }
            result = value
        }
        let additional = object["additionalProperties"]
        let objectType = object["type"]?.stringValue == "object"
            || object["type"]?.arrayValue?.contains(.string("object")) == true
        result.open = result.open || additional == .bool(true) || additional?.objectValue != nil
            || object["patternProperties"]?.objectValue?.isEmpty == false
            || (objectType && object["properties"] == nil && additional != .bool(false))
        if let properties = object["properties"]?.objectValue {
            let required = Set(object["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            result.optional = min(11, result.optional + properties.keys.filter { !required.contains($0) }.count)
        }
        for key in ["additionalProperties", "contains", "else", "if", "items", "not", "then"] {
            if let array = object[key]?.arrayValue { for child in array { add(child) } }
            else { add(object[key]) }
        }
        for key in ["allOf", "anyOf", "oneOf", "prefixItems"] {
            for child in object[key]?.arrayValue ?? [] { add(child) }
        }
        for key in ["dependentSchemas", "patternProperties", "properties"] {
            if let children = object[key]?.objectValue {
                for child in children.values { add(child) }
            }
        }
        return result
    }
    let result = stats(schema)
    return !result.open && result.optional <= 10
}
