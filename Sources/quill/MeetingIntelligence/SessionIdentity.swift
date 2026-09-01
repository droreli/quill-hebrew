import CryptoKit
import Foundation

/// Resolves the stable identity used by meeting-intelligence artifacts.
///
/// Newer sessions may carry `session_id` in `meta.json`, while sessions made
/// before notes existed do not.  Legacy identities are deliberately derived
/// without changing `meta.json` (or any other recording artifact).
struct SessionIdentity: Sendable, Equatable {
    let value: String

    init(sessionDirectory: URL) throws {
        value = try Self.sessionID(for: sessionDirectory)
    }

    static func sessionID(for sessionDirectory: URL) throws -> String {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sessionDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SessionIdentityError.missingSessionDirectory(sessionDirectory)
        }

        if let sessionID = sessionIDInMetadata(at: sessionDirectory), !sessionID.isEmpty {
            return sessionID
        }

        // A canonical path is a stable, local namespace for a legacy session.
        // The digest is formatted as a UUID so it remains compatible with the
        // on-disk contract, without mutating the legacy session metadata.
        let canonicalPath = sessionDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        return legacyUUID(for: canonicalPath).uuidString.lowercased()
    }

    private static func sessionIDInMetadata(at sessionDirectory: URL) -> String? {
        let metadataURL = sessionDirectory.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: metadataURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sessionID = object["session_id"] as? String
        else {
            return nil
        }
        return sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func legacyUUID(for value: String) -> UUID {
        let digest = SHA256.hash(data: Data("quill.legacy-session.v1:\(value)".utf8))
        let bytes = Array(digest)
        var uuidBytes = Array(bytes.prefix(16))
        // UUID v5-style layout: deterministic content, standard UUID bits.
        uuidBytes[6] = (uuidBytes[6] & 0x0F) | 0x50
        uuidBytes[8] = (uuidBytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        ))
    }
}

enum SessionIdentityError: Error, LocalizedError, Equatable {
    case missingSessionDirectory(URL)

    var errorDescription: String? {
        switch self {
        case let .missingSessionDirectory(url):
            "Session directory does not exist: \(url.path)"
        }
    }
}
