import Foundation

// Port of configurator.py's state/file-I/O layer (atomic_write, parse_env_lines,
// bootstrap_state_from_env, generate_env, save_state_and_env, ...). Must keep
// the exact app.env line format ("export KEY=VALUE" / "#export KEY=VALUE",
// quoting rules, the packed DXMT_CONFIG line, foreign-line passthrough) and
// the configurator-state.json shape so existing installs stay compatible and
// scripts that `source` app.env keep working unmodified.

struct VarEntry: Codable {
    var enabled: Bool
    var value: String
}

struct ConfiguratorState: Codable {
    var version: Int = 1
    var vars: [String: VarEntry] = [:]
    var dxmtConfig: [String: VarEntry] = [:]
    var passthrough: [String: String] = [:]
    var foreignLines: [String] = []

    enum CodingKeys: String, CodingKey {
        case version
        case vars
        case dxmtConfig = "dxmt_config"
        case passthrough
        case foreignLines = "foreign_lines"
    }
}

func unquote(_ value: String) -> String {
    guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
    return String(value.dropFirst().dropLast())
}

func atomicWrite(path: String, text: String) throws {
    let url = URL(fileURLWithPath: path)
    let directory = url.deletingLastPathComponent()
    let tmpURL = directory.appendingPathComponent(".gamma-configurator-tmp-\(UUID().uuidString)")
    try text.write(to: tmpURL, atomically: false, encoding: .utf8)
    _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
}

/// "key=val;key2=val2" -> [key: val]. Ignores blank/malformed fragments.
func parseDXMTConfig(_ raw: String) -> [String: String] {
    var result: [String: String] = [:]
    for part in raw.split(separator: ";", omittingEmptySubsequences: true) {
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        guard let eq = trimmed.firstIndex(of: "=") else { continue }
        let key = String(trimmed[trimmed.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
        let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { continue }
        result[key] = unquote(value)
    }
    return result
}

private func isPointerComment(_ line: String) -> Bool {
    line.hasPrefix("# Edit via Contents/")
}

private func parseEnvLine(_ line: String) -> (key: String, enabled: Bool, value: String)? {
    var s = Substring(line)
    var enabled = true
    if s.hasPrefix("#") {
        enabled = false
        s = s.dropFirst()
    }
    guard s.hasPrefix("export") else { return nil }
    s = s.dropFirst("export".count)
    guard let start = s.firstIndex(where: { $0 != " " && $0 != "\t" }) else { return nil }
    s = s[start...]
    guard let eq = s.firstIndex(of: "=") else { return nil }
    let key = String(s[s.startIndex..<eq])
    guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
    let value = String(s[s.index(after: eq)...])
    return (key, enabled, value)
}

struct ParsedEnv {
    var vars: [String: (enabled: Bool, rawValue: String)] = [:]
    var passthrough: [String: String] = [:]
    var foreign: [String] = []
}

func parseEnvLines(path: String) -> ParsedEnv {
    var result = ParsedEnv()
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return result }
    for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
        let stripped = String(rawLine)
        if stripped.isEmpty || isPointerComment(stripped) { continue }
        guard let parsed = parseEnvLine(stripped) else {
            result.foreign.append(stripped)
            continue
        }
        if passthroughKeys.contains(parsed.key) {
            result.passthrough[parsed.key] = parsed.value
        } else if schemaByKey[parsed.key] != nil || parsed.key == "DXMT_CONFIG" {
            result.vars[parsed.key] = (parsed.enabled, parsed.value)
        } else {
            result.foreign.append(stripped)
        }
    }
    return result
}

func defaultState() -> ConfiguratorState {
    var state = ConfiguratorState()
    for entry in schema {
        state.vars[entry.key] = VarEntry(enabled: entry.alwaysOn, value: entry.defaultValue)
    }
    for entry in dxmtConfigKeys {
        state.dxmtConfig[entry.key] = VarEntry(enabled: false, value: entry.defaultValue)
    }
    return state
}

/// First-ever launch: seed state from whatever interactive-setup.sh wrote.
func bootstrapState(configFile: String) -> ConfiguratorState {
    var state = defaultState()
    let parsed = parseEnvLines(path: configFile)
    for (key, entry) in parsed.vars {
        if key == "DXMT_CONFIG" {
            for (subkey, value) in parseDXMTConfig(unquote(entry.rawValue)) {
                if state.dxmtConfig[subkey] != nil {
                    state.dxmtConfig[subkey] = VarEntry(enabled: true, value: value)
                }
            }
            continue
        }
        guard let schemaEntry = schemaByKey[key] else { continue }
        let value = schemaEntry.quoted ? unquote(entry.rawValue) : entry.rawValue
        state.vars[key] = VarEntry(enabled: entry.enabled, value: value)
    }
    state.passthrough = parsed.passthrough
    state.foreignLines = parsed.foreign
    return state
}

/// Pick up anything hand-added to app.env since the last regeneration.
func mergeForeignLines(_ state: inout ConfiguratorState, configFile: String) {
    let parsed = parseEnvLines(path: configFile)
    var known = Set(state.foreignLines)
    for line in parsed.foreign where !known.contains(line) {
        state.foreignLines.append(line)
        known.insert(line)
    }
}

func loadOrBootstrapState(configFile: String, stateFile: String) -> ConfiguratorState {
    var state: ConfiguratorState
    if let data = FileManager.default.contents(atPath: stateFile),
       let decoded = try? JSONDecoder().decode(ConfiguratorState.self, from: data) {
        state = decoded
    } else {
        state = bootstrapState(configFile: configFile)
        if let data = try? JSONEncoder.prettyPrinted.encode(state) {
            try? atomicWrite(path: stateFile, text: String(data: data, encoding: .utf8) ?? "")
        }
    }
    mergeForeignLines(&state, configFile: configFile)
    return state
}

func generateEnv(_ state: ConfiguratorState) -> String {
    let backend = state.vars["GAMMA_GRAPHICS_BACKEND"]?.value ?? "dxmt"
    var lines: [String] = [pointerComment, ""]

    for key in passthroughKeys {
        if let value = state.passthrough[key] {
            lines.append("export \(key)=\(value)")
        }
    }
    lines.append("")

    for entry in schema {
        if let family = entry.family, family != backend { continue }
        let varEntry = state.vars[entry.key] ?? VarEntry(enabled: entry.alwaysOn, value: entry.defaultValue)
        guard entry.alwaysOn || varEntry.enabled else { continue }
        let outValue = entry.quoted ? "\"\(varEntry.value)\"" : varEntry.value
        lines.append("export \(entry.key)=\(outValue)")
    }

    if backend == "dxmt" {
        // Iterate in schema order (not dictionary order) to match the
        // Python implementation's insertion-order dict iteration.
        let serialized = dxmtConfigKeys.compactMap { entry -> String? in
            guard let value = state.dxmtConfig[entry.key], value.enabled else { return nil }
            return "\(entry.key)=\(value.value);"
        }.joined()
        if !serialized.isEmpty {
            lines.append("export DXMT_CONFIG=\"\(serialized)\"")
        }
    }

    lines.append(contentsOf: state.foreignLines)
    return lines.joined(separator: "\n") + "\n"
}

func saveStateAndEnv(_ state: inout ConfiguratorState, configFile: String, stateFile: String) {
    mergeForeignLines(&state, configFile: configFile)
    if let data = try? JSONEncoder.prettyPrinted.encode(state) {
        try? atomicWrite(path: stateFile, text: String(data: data, encoding: .utf8) ?? "")
    }
    try? atomicWrite(path: configFile, text: generateEnv(state))
}

extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
