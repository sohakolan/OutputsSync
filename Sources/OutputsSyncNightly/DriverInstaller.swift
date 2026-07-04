import AppKit
import Foundation

/// Installe le driver loopback embarqué dans l'app vers /Library/Audio/Plug-Ins/HAL
/// via une élévation de privilèges (dialogue mot de passe admin), puis redémarre
/// coreaudiod. Utilisé pour proposer l'installation au 1ᵉʳ lancement.
enum DriverInstaller {

    static let halPath = "/Library/Audio/Plug-Ins/HAL/OutputsSyncDriver.driver"

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: halPath)
    }

    /// Chemin du driver embarqué dans Contents/Resources.
    private static var bundledDriverPath: String? {
        Bundle.main.url(forResource: "OutputsSyncDriver", withExtension: "driver")?.path
    }

    /// Lance l'installation (dialogue admin). Renvoie nil si OK, sinon un message.
    @discardableResult
    static func install() -> String? {
        guard let src = bundledDriverPath else {
            return "Driver introuvable dans l'app."
        }
        let dest = "/Library/Audio/Plug-Ins/HAL"
        let shell = """
        mkdir -p '\(dest)' && rm -rf '\(dest)/OutputsSyncDriver.driver' && \
        cp -R '\(src)' '\(dest)/' && chown -R root:wheel '\(dest)/OutputsSyncDriver.driver' && \
        killall coreaudiod
        """
        // Échappe pour l'insertion dans une chaîne AppleScript (guillemets + backslashes).
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

        var errorInfo: NSDictionary?
        NSAppleScript(source: appleScript)?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            // -128 = l'utilisateur a annulé le dialogue.
            if (errorInfo["NSAppleScriptErrorNumber"] as? Int) == -128 { return "Installation annulée." }
            return errorInfo["NSAppleScriptErrorMessage"] as? String ?? "Échec de l'installation."
        }
        return nil
    }

    /// Propose l'installation via une alerte. `completion(true)` si installé.
    @MainActor
    static func promptIfNeeded(completion: @escaping (Bool) -> Void) {
        guard !isInstalled else { completion(true); return }
        let alert = NSAlert()
        alert.messageText = "Installer le driver OutputsSync ?"
        alert.informativeText = "OutputsSync a besoin de son périphérique audio « OutputsSync Nightly ». "
            + "L'installation demande ton mot de passe admin et redémarre brièvement le serveur audio (2-3 s)."
        alert.addButton(withTitle: "Installer")
        alert.addButton(withTitle: "Plus tard")
        alert.alertStyle = .informational
        guard alert.runModal() == .alertFirstButtonReturn else { completion(false); return }

        if let error = install() {
            let fail = NSAlert()
            fail.messageText = "Installation impossible"
            fail.informativeText = error
            fail.alertStyle = .warning
            fail.runModal()
            completion(false)
        } else {
            completion(true)
        }
    }
}
