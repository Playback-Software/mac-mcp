import Foundation
import Security

/// This process's code-signing identity. Permission grants are tied to it, so it is the first thing
/// to check when they seem to have vanished.
public struct SigningIdentity: Sendable {
    public let identifier: String
    public let teamID: String?
    public let isAdHoc: Bool
    /// The leaf certificate's common name, e.g. "Apple Development: …" or a self-signed local identity.
    public var certificate: String? = nil

    public static func current() -> SigningIdentity {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
              let dict = info as? [String: Any]
        else { return SigningIdentity(identifier: "unsigned", teamID: nil, isAdHoc: true) }
        // Ad hoc means no certificate at all. A self-signed certificate has no team but still keeps grants: they
        // follow the designated requirement, which pins the certificate.
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let leaf = (dict[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
        var name: CFString?
        if let leaf { SecCertificateCopyCommonName(leaf, &name) }
        return SigningIdentity(
            identifier: dict[kSecCodeInfoIdentifier as String] as? String ?? "unknown",
            teamID: dict[kSecCodeInfoTeamIdentifier as String] as? String,
            isAdHoc: leaf == nil || flags & SecCodeSignatureFlags.adhoc.rawValue != 0,
            certificate: name as String?
        )
    }

    public var summary: String {
        isAdHoc
            ? "\(identifier) (AD-HOC: permission grants will not survive rebuilds)"
            : "\(identifier), " + (teamID.map { "team \($0)" } ?? "certificate \"\(certificate ?? "?")\" (no team)")
    }
}

/// The launchd session type of this process: "Aqua" for the logged-in GUI session; "Background" for SSH
/// and other non-GUI contexts, where the login keychain, screen capture and GUI control are unavailable.
public func launchdSessionType() -> String {
    guard let r = try? Subprocess.runBlocking("/bin/launchctl", ["managername"], timeout: 5), !r.timedOut else { return "unknown" }
    return r.stdout
}
