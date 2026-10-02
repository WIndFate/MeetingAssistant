import Foundation

struct TranscriptionState: Equatable {
    var isListening = false
    var statusText = "Idle."
    var paragraphs: [String] = []
    var partialTranscript = ""
    var lastError: String?
}
