import Foundation

/// Documents/henge-env.txt as engine settings (EngineTuning): KEY=VALUE per line, # comments, {Documents} in a value
/// for that folder. Only the engine's own variables (HV_...) are taken: the file sits where Files and a computer can
/// write it, and any other variable (DYLD_..., MallocStackLogging, ...) would change the app itself.
enum EnvOverrides {
    static let prefix = "HV_"

    /// The settings the text gives, and the names it gave that are not the engine's (refused, for the log).
    static func parse(_ text: String, documents: String) -> (accepted: [String: String], refused: [String]) {
        var accepted: [String: String] = [:], refused: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard let eq = line.firstIndex(of: "="), eq != line.startIndex else { continue }
            let name = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard name.hasPrefix(prefix), name.count > prefix.count,
                  name.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }) else {
                refused.append(name)
                continue
            }
            // {Documents} stands for this folder: its absolute path changes when Solstice is reinstalled.
            accepted[name] = String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "{Documents}", with: documents)
        }
        return (accepted, refused)
    }
}
