import Foundation

public extension SessionOrigin {
    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SessionOrigin? {
        if environment["HERDR_ENV"] == "1",
           let workspace = safeIdentifier(environment["HERDR_WORKSPACE_ID"]),
           let pane = safeIdentifier(environment["HERDR_PANE_ID"]) {
            return SessionOrigin(
                kind: .herdr,
                workspaceId: workspace,
                tabId: safeIdentifier(environment["HERDR_TAB_ID"]),
                paneId: pane,
                sessionName: safeIdentifier(environment["HERDR_SESSION"]),
                socketPath: safeAbsolutePath(
                    environment["HERDR_SOCKET_PATH"]
                )
            )
        }
        if let workspace = safeIdentifier(environment["CMUX_WORKSPACE_ID"]),
           let surface = safeIdentifier(environment["CMUX_SURFACE_ID"]) {
            return SessionOrigin(
                kind: .cmux,
                windowId: safeIdentifier(environment["CMUX_WINDOW_ID"]),
                workspaceId: workspace,
                surfaceId: surface,
                socketPath: safeAbsolutePath(environment["CMUX_SOCKET_PATH"]),
                cliPath: safeCMUXExecutable(
                    environment["CMUX_BUNDLED_CLI_PATH"]
                )
            )
        }
        return nil
    }

    static func safeIdentifier(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.count <= 128 else {
            return nil
        }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_.:")
        )
        guard value.unicodeScalars.allSatisfy(allowed.contains) else {
            return nil
        }
        return value
    }

    static func safeAbsolutePath(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.hasPrefix("/"),
              value.count <= 1_024,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return value
    }

    static func safeCMUXExecutable(_ value: String?) -> String? {
        guard let path = safeAbsolutePath(value),
              (path as NSString).lastPathComponent == "cmux",
              path.contains(".app/Contents/") else {
            return nil
        }
        return path
    }
}
