import Foundation

// interactive-setup.sh writes Contents/Resources/paths.json into this app's
// bundle at install time (this app itself lives nested inside the main
// GAMMA.app bundle, so there's no sed-on-a-binary equivalent — a companion
// file is how it learns where app.env/configurator-state.json live for this
// particular install).
struct PathsConfig: Decodable {
    let configFile: String
    let stateFile: String
    let dxmtOnly: Bool

    enum CodingKeys: String, CodingKey {
        case configFile = "configFile"
        case stateFile = "stateFile"
        case dxmtOnly = "dxmtOnly"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configFile = try container.decode(String.self, forKey: .configFile)
        stateFile = try container.decode(String.self, forKey: .stateFile)
        dxmtOnly = try container.decodeIfPresent(Bool.self, forKey: .dxmtOnly) ?? false
    }

    static func load() -> PathsConfig? {
        guard let url = Bundle.main.url(forResource: "paths", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(PathsConfig.self, from: data)
    }
}
