import Foundation

/// Local meeting background read from a folder of Markdown/text files.
///
/// Read fresh on every request, so edits apply to the next translation or hint
/// without restarting anything. `instructions.md` is special: it is appended
/// to both prompts as extra instructions instead of background facts.
struct MeetingKnowledge: Equatable {
    var background: String
    var instructions: String

    static let instructionsFileName = "instructions.md"
    private static let extensions: Set<String> = ["md", "txt"]

    static func load(from folder: URL) -> MeetingKnowledge {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        )) ?? []
        var background: [String] = []
        var instructions = ""
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = file.lastPathComponent.lowercased()
            guard extensions.contains(file.pathExtension.lowercased()), !name.hasPrefix("readme") else {
                continue
            }
            guard let text = try? String(contentsOf: file, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            else { continue }
            if name == instructionsFileName {
                instructions = text
            } else {
                background.append(text)
            }
        }
        return MeetingKnowledge(background: background.joined(separator: "\n\n"), instructions: instructions)
    }
}
