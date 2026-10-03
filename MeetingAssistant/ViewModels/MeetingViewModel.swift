import Combine
import Foundation

/// Live text of the paragraph being spoken. Separate object so ~5 partial
/// updates per second re-render only the draft bubble, not the whole list.
@MainActor
final class LiveTranscript: ObservableObject {
    @Published fileprivate(set) var text = ""
}

/// The single entry point for the UI: listening, per-paragraph translation,
/// and reply hints when the user is addressed by name.
@MainActor
final class MeetingViewModel: ObservableObject {
    @Published private(set) var turns: [MeetingTurn] = [] {
        didSet { scheduleHistorySave() }
    }
    @Published private(set) var isListening = false
    @Published private(set) var statusText = "Idle."
    @Published private(set) var lastError: String?
    @Published private(set) var language: TranscriptionLanguage
    @Published private(set) var callAlertText: String?
    @Published var isStealthEnabled = true

    let live = LiveTranscript()
    let settings: SettingsViewModel

    private let transcription = SpeechTranscriptionService()
    private var translationTasks: [MeetingTurn.ID: Task<Void, Never>] = [:]
    private var hintTask: Task<Void, Never>?
    // Name calls in paragraphs at or below this index have been answered.
    private var handledCallThroughIndex = -1
    private var callCheckTask: Task<Void, Never>?
    private var shortCallGraceIndex: Int?
    private var callAlertTask: Task<Void, Never>?
    // The meeting being recorded: starts with the first paragraph after
    // launch or Clear, ends at the next Clear or quit.
    // ponytail: a meeting spans until Clear; split on long idle if one record ever covers two meetings.
    private var record: MeetingRecord?
    private var historySaveTask: Task<Void, Never>?

    private static let languageKey = "MeetingAssistant.Language"
    // Tokens stream far faster than the eye reads; every turns mutation
    // re-renders the list, so streamed text is pushed at most ~16 times/s.
    private static let renderInterval: TimeInterval = 0.06
    private let translationContextCount = 3
    // "Any questions?" at the end of a long talk needs the whole talk, so
    // the hint gets the newest paragraphs up to this many characters:
    // about 35 min of Japanese or 13 min of English speech, at most ~12k
    // tokens. Hints are rare, so the extra input cost is small.
    private let hintCharacterLimit = 12_000
    // The question usually follows the name; fire once the speaker pauses.
    // A closed paragraph already implies a pause, so this only debounces.
    private let callSettleDelay: Duration = .milliseconds(300)
    // A paragraph that is little more than "セキさん、" was cut at a breath
    // before the actual question; give the rest a moment to arrive.
    private let shortCallParagraphLength = 10
    private let shortCallGraceDelay: Duration = .milliseconds(1500)
    // Saves are throttled, not debounced: a busy meeting streams changes
    // continuously, so a debounce could postpone the write indefinitely.
    // At most this much is lost if the app crashes.
    private let historySaveInterval: Duration = .seconds(5)

    init(settings: SettingsViewModel? = nil) {
        self.settings = settings ?? SettingsViewModel()
        language = UserDefaults.standard.string(forKey: Self.languageKey)
            .flatMap(TranscriptionLanguage.init(rawValue:)) ?? .japanese
        transcription.onStateChange = { [weak self] state in
            self?.accept(state)
        }
    }

    // MARK: - Intents

    func toggleListening() {
        if isListening {
            transcription.stop()
        } else {
            Task { await transcription.start(language: language) }
        }
    }

    func setLanguage(_ newLanguage: TranscriptionLanguage) {
        guard newLanguage != language else { return }
        language = newLanguage
        UserDefaults.standard.set(newLanguage.rawValue, forKey: Self.languageKey)
        Task { await transcription.switchLanguage(to: newLanguage) }
    }

    func toggleLanguage() {
        setLanguage(language.next)
    }

    func toggleStealth() {
        isStealthEnabled.toggle()
    }

    /// Clear ends the current meeting: it is saved, and the next paragraph
    /// starts a new record.
    func clear() {
        saveHistoryNow()
        record = nil
        translationTasks.values.forEach { $0.cancel() }
        translationTasks = [:]
        hintTask?.cancel()
        hintTask = nil
        handledCallThroughIndex = -1
        cancelShortCallGrace()
        clearCallAlert()
        turns = []
        transcription.clear()
    }

    /// Hotkey / button: reply hint from the recent transcript, name or not.
    func requestHintNow() {
        Task {
            await transcription.commitLiveText()
            guard !turns.isEmpty else {
                showCallAlert("无可回答内容")
                return
            }
            requestHint(reason: "manual")
        }
    }

    var transcriptText: String {
        MeetingRecord.plainText(MeetingRecord.entries(from: turns))
    }

    /// Writes the current meeting to disk now (Clear, quit, opening history).
    func saveHistoryNow() {
        historySaveTask?.cancel()
        historySaveTask = nil
        guard var record, !turns.isEmpty else { return }
        record.endedAt = Date()
        record.entries = MeetingRecord.entries(from: turns)
        self.record = record
        do {
            try MeetingHistoryStore.save(record, in: MeetingHistoryStore.defaultFolder)
        } catch {
            print("[MeetingViewModel] history save failed error=\(error.localizedDescription)")
        }
    }

    var isAnyHintStreaming: Bool {
        turns.contains(where: \.isHintStreaming)
    }

    // MARK: - Transcription

    private func accept(_ state: TranscriptionState) {
        if isListening != state.isListening { isListening = state.isListening }
        if statusText != state.statusText { statusText = state.statusText }
        if lastError != state.lastError { lastError = state.lastError }
        if live.text != state.partialTranscript { live.text = state.partialTranscript }

        if state.paragraphs.count < turns.count {
            // Transcript was cleared underneath us.
            turns = []
            handledCallThroughIndex = -1
        }
        while turns.count < state.paragraphs.count {
            turns.append(MeetingTurn(text: state.paragraphs[turns.count]))
            translate(turnAt: turns.count - 1)
        }

        if callAlertText == nil, MeetingCallDetector.containsCall(state.partialTranscript, aliases: settings.aliases) {
            showCallAlert("被点名了 · 等对方说完")
        }
        scheduleCallCheck()
    }

    // MARK: - Translation

    private func translate(turnAt index: Int) {
        let turn = turns[index]
        let context = turns[max(0, index - translationContextCount)..<index].map(\.text)
        let knowledge = MeetingKnowledge.load(from: settings.knowledgeFolderURL)
        let system = MeetingPrompts.translationSystem(knowledge)
        let user = MeetingPrompts.translationUser(text: turn.text, context: context, language: language)
        turns[index].isTranslating = true

        translationTasks[turn.id] = Task { [weak self] in
            guard let self else { return }
            do {
                var text = ""
                var lastRender = Date.distantPast
                for try await delta in try self.client().stream(
                    model: self.settings.translationModel,
                    system: system,
                    user: user,
                    maxTokens: 800,
                    temperature: 0.2
                ) {
                    text += delta
                    guard Date().timeIntervalSince(lastRender) >= Self.renderInterval else { continue }
                    lastRender = Date()
                    self.updateTurn(turn.id) { $0.translation = text; $0.isTranslating = false }
                }
                self.updateTurn(turn.id) {
                    $0.translation = MeetingTranslationCleanup.trimmingDanglingTail(text)
                    $0.isTranslating = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.updateTurn(turn.id) {
                    $0.isTranslating = false
                    $0.translationError = error.localizedDescription
                }
            }
            self.translationTasks[turn.id] = nil
        }
    }

    // MARK: - Name call → reply hint

    private func scheduleCallCheck() {
        callCheckTask?.cancel()
        let delay = callSettleDelay
        callCheckTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.requestHintIfCallSettled()
        }
    }

    private func requestHintIfCallSettled() {
        let paragraphs = transcription.state.paragraphs
        let firstUnhandled = handledCallThroughIndex + 1
        guard firstUnhandled < paragraphs.count,
              let callIndex = (firstUnhandled..<paragraphs.count).last(where: {
                  MeetingCallDetector.containsCall(paragraphs[$0], aliases: settings.aliases)
              })
        else { return }
        // Still talking: the question is not finished yet.
        guard transcription.state.partialTranscript.count < 2 else { return }

        let lastIndex = paragraphs.count - 1
        let callText = paragraphs[callIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        if callIndex == lastIndex, callText.count <= shortCallParagraphLength, shortCallGraceIndex != callIndex {
            shortCallGraceIndex = callIndex
            let delay = shortCallGraceDelay
            callCheckTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.requestHintIfCallSettled()
            }
            return
        }
        requestHint(reason: "name_call")
    }

    private func cancelShortCallGrace() {
        callCheckTask?.cancel()
        shortCallGraceIndex = nil
    }

    private func requestHint(reason: String) {
        cancelShortCallGrace()
        let paragraphs = transcription.state.paragraphs
        guard !paragraphs.isEmpty, turns.count == paragraphs.count else { return }
        handledCallThroughIndex = paragraphs.count - 1

        let transcript = MeetingPrompts.hintTranscript(paragraphs, characterLimit: hintCharacterLimit)
        // The hint attaches to the latest paragraph.
        let index = turns.count - 1
        if !turns[index].hint.isEmpty {
            turns[index].archivedHints.append(turns[index].hint)
            turns[index].hint = ""
        }
        turns[index].isHintStreaming = true
        let turnID = turns[index].id
        showCallAlert(reason == "manual" ? "生成回答提示中" : "被点名了 · 生成回答提示中")

        let knowledge = MeetingKnowledge.load(from: settings.knowledgeFolderURL)
        let system = MeetingPrompts.hintSystem(knowledge)
        let user = MeetingPrompts.hintUser(
            transcript: transcript,
            language: language,
            userName: settings.aliases.first ?? ""
        )
        print("[MeetingViewModel] hint request reason=\(reason) paragraphs=\(transcript.count)")

        hintTask?.cancel()
        hintTask = Task { [weak self] in
            guard let self else { return }
            do {
                var text = ""
                var lastRender = Date.distantPast
                for try await delta in try self.client().stream(
                    model: self.settings.hintModel,
                    system: system,
                    user: user,
                    maxTokens: 900,
                    temperature: 0.4
                ) {
                    text += delta
                    guard Date().timeIntervalSince(lastRender) >= Self.renderInterval else { continue }
                    lastRender = Date()
                    self.updateTurn(turnID) { $0.hint = text }
                }
                self.updateTurn(turnID) { $0.hint = text }
            } catch {
                if !Task.isCancelled {
                    self.updateTurn(turnID) { $0.hint = "Reply hint failed: \(error.localizedDescription)" }
                }
            }
            self.updateTurn(turnID) { $0.isHintStreaming = false }
            self.clearCallAlert()
        }
    }

    // MARK: - History

    private func scheduleHistorySave() {
        guard !turns.isEmpty else { return }
        if record == nil {
            let now = Date()
            record = MeetingRecord(id: UUID(), startedAt: now, endedAt: now, entries: [])
        }
        guard historySaveTask == nil else { return }
        let interval = historySaveInterval
        historySaveTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self?.saveHistoryNow()
        }
    }

    // MARK: - Helpers

    private func client() throws -> OpenAIChatClient {
        guard let key = settings.apiKey else { throw OpenAIChatError.missingAPIKey }
        return OpenAIChatClient(apiKey: key)
    }

    private func updateTurn(_ id: MeetingTurn.ID, _ mutate: (inout MeetingTurn) -> Void) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        mutate(&turns[index])
    }

    // Visual only: a chime plays through the system output, where a
    // speakerphone mic or "share computer sound" would send it to the meeting.
    private func showCallAlert(_ text: String) {
        callAlertTask?.cancel()
        callAlertText = text
        // Safety net: never leave the banner up if no hint follows.
        callAlertTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.callAlertText = nil
        }
    }

    private func clearCallAlert() {
        callAlertTask?.cancel()
        callAlertTask = nil
        callAlertText = nil
    }
}
