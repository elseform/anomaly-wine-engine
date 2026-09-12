import Foundation

// interactive-setup.sh writes Contents/Resources/paths.json into this app's
// bundle at install time (this app itself lives nested inside the main
// GAMMA.app bundle, so there's no sed-on-a-binary equivalent — a companion
// file is how it learns where app.env/configurator-state.json live for this
// particular install).
struct PathsConfig: Decodable {
    let configFile: String
    let stateFile: String

    enum CodingKeys: String, CodingKey {
        case configFile = "configFile"
        case stateFile = "stateFile"
    }

    static func load() -> PathsConfig? {
        guard let url = Bundle.main.url(forResource: "paths", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(PathsConfig.self, from: data)
    }
}
