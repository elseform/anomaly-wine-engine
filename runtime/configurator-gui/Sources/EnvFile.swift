import Foundation

// app.env is the Configurator's only store. The launcher sources it, and every
// setting's value and on/off state is recoverable from it: an enabled setting
// is "export KEY=VALUE", a disabled one keeps its value as "#export KEY=VALUE",
// DXMT_CONFIG sub-keys are packed into one line, EXE_PATH/EXE_RUN_DIR pass
// through, retired D3DMetal lines are dropped, and other unrecognised lines are
// kept verbatim. Keep that format stable;
// existing installs' app.env files and the scripts that source them rely on it.
//
// Installs made before this change also have a configurator-state.json next to
// app.env. It is read once, only to recover the values of settings that were
// disabled (and therefore absent from app.env), and is never written again.

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
    let value = shellWord(s[s.index(after: eq)...])
    return (key, enabled, value)
}

/// The value as the shell reads it: one word, ending at the first unquoted
/// space or tab, so a hand-written trailing "# comment" is not taken as
/// part of it. Quotes are kept; callers unquote where the schema says so.
private func shellWord(_ text: Substring) -> String {
    var quote: Character?
    var escaped = false
    var end = text.endIndex
    for index in text.indices {
        let character = text[index]
        if escaped {
            escaped = false
        } else if let open = quote {
            if character == "\\" && open == "\"" {
                escaped = true
            } else if character == open {
                quote = nil
            }
        } else if character == "\\" {
            escaped = true
        } else if character == "\"" || character == "'" {
            quote = character
        } else if character == " " || character == "\t" {
            end = index
            break
        }
    }
    return String(text[..<end])
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
        if retiredKeyPrefixes.contains(where: parsed.key.hasPrefix) {
            continue
        } else if passthroughKeys.contains(parsed.key) {
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
        state.dxmtConfig[entry.key] = VarEntry(enabled: entry.enabledByDefault, value: entry.defaultValue)
    }
    return state
}

/// Values of settings that are disabled and therefore missing from an
/// app.env written by a Configurator from before app.env became the only
/// store. Read-only; the file is never written again.
private func legacyDisabledValues(stateFile: String?) -> [String: String] {
    guard let stateFile,
          let data = FileManager.default.contents(atPath: stateFile),
          let legacy = try? JSONDecoder().decode(ConfiguratorState.self, from: data) else {
        return [:]
    }
    return legacy.vars.compactMapValues { $0.enabled ? nil : $0.value }
}

/// Everything the Configurator shows comes from app.env. A missing app.env
/// means a brand-new install: schema defaults, which the first save writes.
func loadState(configFile: String, legacyStateFile: String? = nil) -> ConfiguratorState {
    var state = defaultState()
    guard FileManager.default.fileExists(atPath: configFile) else { return state }
    let parsed = parseEnvLines(path: configFile)
    let legacy = legacyDisabledValues(stateFile: legacyStateFile)

    for entry in schema {
        if let line = parsed.vars[entry.key] {
            let value = entry.quoted ? unquote(line.rawValue) : line.rawValue
            state.vars[entry.key] = VarEntry(enabled: line.enabled || entry.alwaysOn, value: value)
        } else if !entry.alwaysOn {
            state.vars[entry.key] = VarEntry(enabled: false, value: legacy[entry.key] ?? entry.defaultValue)
        }
    }

    // An existing app.env is authoritative for DXMT_CONFIG: no enabled line
    // means every sub-key is off, not "use the defaults".
    let packed = parsed.vars["DXMT_CONFIG"].flatMap { $0.enabled ? parseDXMTConfig(unquote($0.rawValue)) : nil } ?? [:]
    for entry in dxmtConfigKeys {
        if let value = packed[entry.key] {
            state.dxmtConfig[entry.key] = VarEntry(enabled: true, value: value)
        } else {
            state.dxmtConfig[entry.key] = VarEntry(enabled: false, value: entry.defaultValue)
        }
    }

    state.passthrough = parsed.passthrough
    state.foreignLines = parsed.foreign
    return state
}

func generateEnv(_ state: ConfiguratorState) -> String {
    var lines: [String] = [pointerComment, ""]

    for key in passthroughKeys {
        if let value = state.passthrough[key] {
            lines.append("export \(key)=\(value)")
        }
    }
    lines.append("")

    for entry in schema {
        let varEntry = state.vars[entry.key] ?? VarEntry(enabled: entry.alwaysOn, value: entry.defaultValue)
        let outValue = entry.quoted ? "\"\(varEntry.value)\"" : varEntry.value
        if entry.alwaysOn || varEntry.enabled {
            lines.append("export \(entry.key)=\(outValue)")
        } else if !varEntry.value.isEmpty, varEntry.value != entry.defaultValue {
            // Disabled with a non-default value: keep it for when the row is
            // re-enabled. A disabled default needs no line at all.
            lines.append("#export \(entry.key)=\(outValue)")
        }
    }

    // Schema order, not dictionary order, so the line is stable.
    let serialized = dxmtConfigKeys.compactMap { entry -> String? in
        guard let value = state.dxmtConfig[entry.key], value.enabled else { return nil }
        return "\(entry.key)=\(value.value);"
    }.joined()
    if !serialized.isEmpty {
        lines.append("export DXMT_CONFIG=\"\(serialized)\"")
    }

    lines.append(contentsOf: state.foreignLines)
    return lines.joined(separator: "\n") + "\n"
}

/// Writes app.env. Lines added to the file by hand since it was loaded are
/// picked up first so a save never drops them.
func saveEnv(_ state: inout ConfiguratorState, configFile: String) {
    let current = parseEnvLines(path: configFile)
    var known = Set(state.foreignLines)
    for line in current.foreign where !known.contains(line) {
        state.foreignLines.append(line)
        known.insert(line)
    }
    try? atomicWrite(path: configFile, text: generateEnv(state))
}
