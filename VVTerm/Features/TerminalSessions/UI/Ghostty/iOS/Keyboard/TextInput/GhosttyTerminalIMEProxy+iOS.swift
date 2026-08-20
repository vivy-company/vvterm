#if os(iOS)
import OSLog
import UIKit

@MainActor
final class TerminalIMEProxyTextView: UIView, UITextInput {
    enum DocumentMode: Equatable {
        case terminalInput
        case nativeSelection
    }

    weak var terminalOwner: GhosttyTerminalView?
    /// Local mirror of recently typed input. Committed text stays in the document after
    /// being sent to the terminal (until the session is invalidated by Enter, control
    /// keys, focus changes, …) so system text services — most importantly inline
    /// dictation — can read context back and revise text through the standard
    /// UITextInput document model. Revisions are reconciled to the terminal as
    /// backspaces plus retyped text by TerminalTextInputModel.
    private var documentBuffer = ""
    /// Range of `documentBuffer` holding the in-progress composition (IME preedit or an
    /// active dictation span). This portion has not been sent to the terminal yet.
    private var markedRange: NSRange?
    private var deleteRepeatAnchorUsesAlternate = false

    /// While a dictation session is active, inserted text is buffered like an IME
    /// composition instead of being committed to the terminal. Inline dictation (iOS 16+)
    /// keeps revising previously inserted text through the document model, which only works
    /// if that text is still present in the document. The buffer is committed when the
    /// session ends (input mode change, placeholder removal, or focus loss).
    enum DictationSessionOrigin: String {
        case inputMode
        case placeholder
    }

    private(set) var dictationSessionOrigin: DictationSessionOrigin?
    private var activeDictationPlaceholder: NSObject?
    private var dictationAnchorLocation = 0

    var isDictationSessionActive: Bool { dictationSessionOrigin != nil }

    // Per-keystroke IME tracing floods the console; opt in only while debugging dictation.
    static let dictationLogger: Logger = Foundation.ProcessInfo.processInfo.environment["VVTERM_DICTATION_LOG"] != nil
        ? Logger.forCategory("Dictation")
        : Logger(.disabled)

    private var currentPrimaryLanguage: String {
        textInputMode?.primaryLanguage ?? "nil"
    }

    var documentMode: DocumentMode {
        terminalOwner?.isNativeSelectionTextInputContext == true
            ? .nativeSelection
            : .terminalInput
    }
    private lazy var terminalNavigationCommands: [UIKeyCommand] = Self.makeTerminalNavigationCommands(
        action: #selector(handleTerminalNavigationCommand(_:))
    )

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        clearSystemInputAssistant()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isMultipleTouchEnabled = true
        clearSystemInputAssistant()
    }

    private static let terminalNavigationInputs: [String] = [
        UIKeyCommand.inputEscape,
        UIKeyCommand.inputUpArrow,
        UIKeyCommand.inputDownArrow,
        UIKeyCommand.inputLeftArrow,
        UIKeyCommand.inputRightArrow,
        UIKeyCommand.inputHome,
        UIKeyCommand.inputEnd,
        UIKeyCommand.inputPageUp,
        UIKeyCommand.inputPageDown,
    ]

    private static let terminalNavigationModifierCombinations: [UIKeyModifierFlags] = {
        let supportedFlags: [UIKeyModifierFlags] = [.shift, .control, .alternate, .command]
        return (0..<(1 << supportedFlags.count)).map { mask in
            var modifiers: UIKeyModifierFlags = []
            for (index, flag) in supportedFlags.enumerated() where (mask & (1 << index)) != 0 {
                modifiers.insert(flag)
            }
            return modifiers
        }
    }()

    var text: String? {
        get { documentBuffer }
        set {
            documentBuffer = newValue?.precomposedStringWithCanonicalMapping ?? ""
            markedRange = nil
            selectedRange = NSRange(location: documentBuffer.utf16.count, length: 0)
        }
    }

    var selectedRange = NSRange(location: 0, length: 0) {
        didSet { selectedRange = clampedRange(selectedRange) }
    }

    weak var inputDelegate: UITextInputDelegate?
    var markedTextStyle: [NSAttributedString.Key: Any]?
    lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    override var canBecomeFirstResponder: Bool {
        terminalOwner?.imeProxyCanBecomeFirstResponder ?? false
    }

    override var canResignFirstResponder: Bool {
        true
    }

    override var inputAccessoryView: UIView? {
        get { terminalOwner?.resolvedInputAccessoryView() }
        set { }
    }

    override var inputView: UIView? {
        get { terminalOwner?.resolvedInputView() }
        set { }
    }

    override var textInputContextIdentifier: String? {
        terminalOwner?.currentTextInputContextIdentifier
    }

    override var keyCommands: [UIKeyCommand]? {
        terminalNavigationCommands + (super.keyCommands ?? [])
    }

    var keyboardType: UIKeyboardType {
        get { .default }
        set { }
    }

    var keyboardAppearance: UIKeyboardAppearance {
        get { terminalOwner?.resolvedKeyboardAppearance ?? .default }
        set { }
    }

    private func clearSystemInputAssistant() {
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
    }

    var autocorrectionType: UITextAutocorrectionType {
        get { .no }
        set { }
    }

    var autocapitalizationType: UITextAutocapitalizationType {
        get { .none }
        set { }
    }

    var spellCheckingType: UITextSpellCheckingType {
        get { .no }
        set { }
    }

    var smartQuotesType: UITextSmartQuotesType {
        get { .no }
        set { }
    }

    var smartDashesType: UITextSmartDashesType {
        get { .no }
        set { }
    }

    var smartInsertDeleteType: UITextSmartInsertDeleteType {
        get { .no }
        set { }
    }

    @available(iOS 17.0, *)
    var inlinePredictionType: UITextInlinePredictionType {
        get { .no }
        set { }
    }

    var enablesReturnKeyAutomatically: Bool {
        get { false }
        set { }
    }

    var returnKeyType: UIReturnKeyType {
        get { .default }
        set { }
    }

    override func becomeFirstResponder() -> Bool {
        terminalOwner?.logKeyboardLifecycle("imeProxy.become.begin")
        let result = super.becomeFirstResponder()
        terminalOwner?.imeProxyFocusDidChange(isFocused: result || isFirstResponder)
        terminalOwner?.logKeyboardLifecycle("imeProxy.become.end", result: result)
        return result
    }

    override func resignFirstResponder() -> Bool {
        terminalOwner?.logKeyboardLifecycle("imeProxy.resign.begin")
        let result = super.resignFirstResponder()
        terminalOwner?.imeProxyFocusDidChange(isFocused: isFirstResponder)
        terminalOwner?.logKeyboardLifecycle("imeProxy.resign.end", result: result)
        return result
    }

    var hasText: Bool {
        if documentMode == .nativeSelection {
            guard let terminalOwner else { return false }
            return terminalOwner.nativeSelectionSnapshot.length > 0
                || (terminalOwner.nativeSelectedRange?.length ?? 0) > 0
        }
        // The terminal itself can still accept Backspace when the local document is
        // empty, and UIKit uses this value to keep software-keyboard delete
        // active/repeating.
        return !documentBuffer.isEmpty || (terminalOwner?.canRouteProxyDeleteBackward ?? false)
    }

    func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        guard prepareTerminalInputDocument() else { return }
        Self.dictationLogger.debug("insertText text=\(text, privacy: .public) mode=\(self.currentPrimaryLanguage, privacy: .public) session=\(self.dictationSessionOrigin?.rawValue ?? "none", privacy: .public) doc=\(self.documentBuffer, privacy: .public)")
        beginDictationSessionIfInputModeActive()
        if let origin = dictationSessionOrigin {
            if origin == .placeholder
                || TerminalVisiblePreeditPolicy.isDictationInputMode(textInputMode?.primaryLanguage) {
                insertDictationBufferText(text)
                return
            }
            // The input mode already left dictation (notification missed or pending):
            // commit the session and handle this insertion normally.
            endDictationSession(commit: true)
        }
        _ = terminalOwner?.handleIMEProxyInsertText(text, fromIMEComposition: markedRange != nil)
    }

    /// Inserts plain text into the persistent local document. The text input model
    /// reconciles the change with the terminal by sending only the delta.
    func insertCommittedText(_ text: String) {
        guard !text.isEmpty else { return }
        performDocumentEdit {
            let normalized = text.precomposedStringWithCanonicalMapping
            let nsText = documentBuffer as NSString
            let replacementRange = markedRange ?? clampedRange(selectedRange)
            documentBuffer = nsText.replacingCharacters(in: replacementRange, with: normalized)
            markedRange = nil
            selectedRange = NSRange(
                location: replacementRange.location + (normalized as NSString).length,
                length: 0
            )
        }
    }

    /// Brackets a local document mutation with the UITextInputDelegate notifications
    /// the system keyboard relies on, then syncs the text input model.
    private func performDocumentEdit(_ mutate: () -> Void) {
        inputDelegate?.textWillChange(self)
        inputDelegate?.selectionWillChange(self)
        mutate()
        inputDelegate?.selectionDidChange(self)
        inputDelegate?.textDidChange(self)
        notifyTextInputStateDidChange()
    }

    private func beginDictationSessionIfInputModeActive() {
        guard dictationSessionOrigin == nil,
              TerminalVisiblePreeditPolicy.isDictationInputMode(textInputMode?.primaryLanguage) else { return }
        beginDictationSession(origin: .inputMode)
    }

    func insertDictationResult(_ dictationResult: [UIDictationPhrase]) {
        let text = dictationResult.map(\.text).joined()
        Self.dictationLogger.log("insertDictationResult phrases=\(dictationResult.count) text=\(text, privacy: .public) session=\(self.dictationSessionOrigin?.rawValue ?? "none", privacy: .public)")
        if !text.isEmpty {
            insertText(text)
        }
        endDictationSession(commit: true)
    }

    func dictationRecordingDidEnd() {
        // Recognition results can still arrive after recording stops; the buffer is
        // committed when the session ends.
        Self.dictationLogger.log("dictationRecordingDidEnd session=\(self.dictationSessionOrigin?.rawValue ?? "none", privacy: .public) doc=\(self.documentBuffer, privacy: .public)")
    }

    func dictationRecognitionFailed() {
        Self.dictationLogger.log("dictationRecognitionFailed session=\(self.dictationSessionOrigin?.rawValue ?? "none", privacy: .public) doc=\(self.documentBuffer, privacy: .public)")
        endDictationSession(commit: true)
    }

    func insertDictationResultPlaceholder() -> Any {
        Self.dictationLogger.log("insertDictationResultPlaceholder mode=\(self.currentPrimaryLanguage, privacy: .public)")
        let placeholder = NSObject()
        activeDictationPlaceholder = placeholder
        beginDictationSession(origin: .placeholder)
        return placeholder
    }

    func frame(forDictationResultPlaceholder placeholder: Any) -> CGRect {
        let rect = terminalOwner?.imeProxyCaretRect(for: endOfDocument) ?? .zero
        Self.dictationLogger.debug("frameForDictationResultPlaceholder -> \(String(describing: rect), privacy: .public)")
        return rect
    }

    func removeDictationResultPlaceholder(_ placeholder: Any, willInsertResult: Bool) {
        Self.dictationLogger.log("removeDictationResultPlaceholder willInsertResult=\(willInsertResult) session=\(self.dictationSessionOrigin?.rawValue ?? "none", privacy: .public) doc=\(self.documentBuffer, privacy: .public)")
        activeDictationPlaceholder = nil
        if !willInsertResult {
            // Recognition failed: commit whatever was buffered so far.
            endDictationSession(commit: true)
        }
        // Otherwise insertDictationResult delivers the result and ends the session.
    }

    func beginDictationSession(origin: DictationSessionOrigin = .inputMode) {
        guard dictationSessionOrigin == nil else { return }
        Self.dictationLogger.log("beginDictationSession origin=\(origin.rawValue, privacy: .public)")
        // Commit any pending IME composition so dictation starts from a clean state.
        if markedRange != nil {
            unmarkText()
        }
        dictationAnchorLocation = clampedRange(selectedRange).location
        dictationSessionOrigin = origin
    }

    func endDictationSession(commit: Bool) {
        guard let origin = dictationSessionOrigin else { return }
        Self.dictationLogger.log("endDictationSession origin=\(origin.rawValue, privacy: .public) commit=\(commit) doc=\(self.documentBuffer, privacy: .public)")
        dictationSessionOrigin = nil
        activeDictationPlaceholder = nil
        guard let marked = markedRange, marked.length > 0 else {
            markedRange = nil
            notifyTextInputStateDidChange()
            return
        }
        if commit {
            unmarkText()
        } else {
            removeMarkedSpan()
        }
    }

    private func insertDictationBufferText(_ text: String) {
        performDocumentEdit {
            let normalized = text.precomposedStringWithCanonicalMapping
            let nsText = documentBuffer as NSString
            let insertionRange = clampedRange(selectedRange)
            documentBuffer = nsText.replacingCharacters(in: insertionRange, with: normalized)
            selectedRange = NSRange(
                location: insertionRange.location + (normalized as NSString).length,
                length: 0
            )
            refreshDictationMarkedRange()
        }
    }

    /// During a dictation session everything dictated since the session anchor stays
    /// marked, so it renders as preedit and is not sent until the session ends.
    private func refreshDictationMarkedRange() {
        guard isDictationSessionActive else { return }
        let documentLength = (documentBuffer as NSString).length
        let anchor = min(dictationAnchorLocation, documentLength)
        markedRange = documentLength > anchor
            ? NSRange(location: anchor, length: documentLength - anchor)
            : nil
    }

    private func removeMarkedSpan() {
        guard let marked = markedRange, marked.length > 0 else {
            markedRange = nil
            return
        }
        performDocumentEdit {
            documentBuffer = (documentBuffer as NSString).replacingCharacters(in: marked, with: "")
            markedRange = nil
            selectedRange = NSRange(location: marked.location, length: 0)
        }
    }

    func deleteBackward() {
        guard prepareTerminalInputDocument() else { return }
        Self.dictationLogger.debug("deleteBackward doc=\(self.documentBuffer, privacy: .public) session=\(self.dictationSessionOrigin?.rawValue ?? "none", privacy: .public)")
        let before = terminalOwner?.imeProxySnapshot()
        guard !documentBuffer.isEmpty else {
            notifyVirtualDeleteAnchorDidChange()
            terminalOwner?.imeProxyDidDeleteBackward(before: before)
            return
        }

        inputDelegate?.textWillChange(self)
        inputDelegate?.selectionWillChange(self)
        let nsText = documentBuffer as NSString
        let deletionRange: NSRange
        if selectedRange.length > 0 {
            deletionRange = NSIntersectionRange(selectedRange, NSRange(location: 0, length: nsText.length))
        } else if selectedRange.location > 0 {
            deletionRange = nsText.rangeOfComposedCharacterSequence(at: selectedRange.location - 1)
        } else {
            deletionRange = NSRange(location: 0, length: 0)
        }
        if deletionRange.length > 0 {
            documentBuffer = nsText.replacingCharacters(in: deletionRange, with: "")
            adjustMarkedRange(afterReplacing: deletionRange, insertedLength: 0)
            selectedRange = NSRange(location: deletionRange.location, length: 0)
        }
        inputDelegate?.selectionDidChange(self)
        inputDelegate?.textDidChange(self)
        terminalOwner?.imeProxyDidDeleteBackward(before: before)
    }

    private func adjustMarkedRange(afterReplacing range: NSRange, insertedLength: Int) {
        if isDictationSessionActive {
            refreshDictationMarkedRange()
            return
        }
        guard let marked = markedRange else { return }
        let delta = insertedLength - range.length
        let markedEnd = marked.location + marked.length
        let rangeEnd = range.location + range.length
        if rangeEnd <= marked.location {
            markedRange = NSRange(location: max(marked.location + delta, 0), length: marked.length)
        } else if range.location >= markedEnd {
            // Replacement after the composition: nothing to adjust.
        } else {
            // Replacement overlaps the composition: recompute a best-effort span.
            let newStart = min(marked.location, range.location)
            let newEnd = max(markedEnd + delta, range.location + insertedLength)
            markedRange = newEnd > newStart
                ? NSRange(location: newStart, length: newEnd - newStart)
                : nil
        }
    }

    override func draw(_ rect: CGRect) {
    }

    var selectedTextRange: UITextRange? {
        get {
            if documentMode == .nativeSelection {
                guard let terminalOwner else { return nil }
                return terminalOwner.nativeSelectionSnapshot.nativeRange(
                    terminalOwner.nativeSelectedRange
                )
            }
            let range = effectiveTextInputSelectedRange
            return TerminalNativeTextRange(
                start: range.location,
                end: range.location + range.length
            )
        }
        set {
            if documentMode == .nativeSelection {
                guard let terminalOwner else { return }
                terminalOwner.setNativeSelectedRange(
                    terminalOwner.nativeSelectionSnapshot.nativeRange(from: newValue)
                )
                return
            }
            guard let range = newValue as? TerminalNativeTextRange else { return }
            Self.dictationLogger.debug("setSelectedTextRange range=\(String(describing: range.nsRange), privacy: .public) session=\(self.dictationSessionOrigin?.rawValue ?? "none", privacy: .public)")
            inputDelegate?.selectionWillChange(self)
            selectedRange = usesDeleteRepeatAnchor ? NSRange(location: 0, length: 0) : clampedRange(range.nsRange)
            inputDelegate?.selectionDidChange(self)
            notifyTextInputStateDidChange()
        }
    }

    var markedTextRange: UITextRange? {
        guard documentMode == .terminalInput else { return nil }
        guard let markedRange, markedRange.length > 0 else { return nil }
        return TerminalNativeTextRange(
            start: markedRange.location,
            end: markedRange.location + markedRange.length
        )
    }

    var beginningOfDocument: UITextPosition {
        TerminalNativeTextPosition(offset: 0)
    }

    var endOfDocument: UITextPosition {
        TerminalNativeTextPosition(offset: activeDocumentLength)
    }

    var textInputView: UIView {
        self
    }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        guard prepareTerminalInputDocument() else { return }
        Self.dictationLogger.debug("setMarkedText text=\(markedText ?? "nil", privacy: .public) sel=\(selectedRange.location),\(selectedRange.length) mode=\(self.currentPrimaryLanguage, privacy: .public) session=\(self.dictationSessionOrigin?.rawValue ?? "none", privacy: .public)")
        terminalOwner?.cancelHardwareKeyRepeatForIMEComposition()
        performDocumentEdit {
            let normalized = markedText?.precomposedStringWithCanonicalMapping ?? ""
            let nsText = documentBuffer as NSString
            let replacementRange = markedRange ?? clampedRange(self.selectedRange)
            documentBuffer = nsText.replacingCharacters(in: replacementRange, with: normalized)
            let normalizedLength = (normalized as NSString).length
            if normalizedLength > 0 {
                let newMarkedRange = NSRange(location: replacementRange.location, length: normalizedLength)
                markedRange = newMarkedRange
                // The selection passed by UIKit is relative to the marked text.
                let selectionLocation = min(max(selectedRange.location, 0), normalizedLength)
                let selectionLength = min(max(selectedRange.length, 0), normalizedLength - selectionLocation)
                self.selectedRange = NSRange(
                    location: newMarkedRange.location + selectionLocation,
                    length: selectionLength
                )
            } else {
                markedRange = nil
                self.selectedRange = NSRange(location: replacementRange.location, length: 0)
            }
            if isDictationSessionActive {
                refreshDictationMarkedRange()
            }
        }
    }

    func unmarkText() {
        guard prepareTerminalInputDocument() else { return }
        Self.dictationLogger.debug("unmarkText doc=\(self.documentBuffer, privacy: .public) marked=\(String(describing: self.markedRange), privacy: .public) session=\(self.dictationSessionOrigin?.rawValue ?? "none", privacy: .public)")
        guard let marked = markedRange, marked.length > 0 else {
            markedRange = nil
            notifyTextInputStateDidChange()
            return
        }
        if isDictationSessionActive {
            // Keep the dictated span marked (unsent) so the system can keep revising
            // it; the span is committed when the session ends.
            notifyTextInputStateDidChange()
            return
        }
        // The text input model observes the composition becoming committed text and
        // sends it to the terminal.
        performDocumentEdit {
            markedRange = nil
            selectedRange = NSRange(location: marked.location + marked.length, length: 0)
        }
    }

    func text(in range: UITextRange) -> String? {
        if documentMode == .nativeSelection {
            guard let terminalOwner,
                  let range = terminalOwner.nativeSelectionSnapshot.nativeRange(from: range) else {
                return nil
            }
            return terminalOwner.nativeSelectionSnapshot.text(in: range)
        }
        guard let range = range as? TerminalNativeTextRange else { return nil }
        let clamped = clampedTextInputRange(range.nsRange)
        let result: String
        if clamped.length > 0 {
            result = (textInputDocument as NSString).substring(with: clamped)
        } else {
            result = ""
        }
        Self.dictationLogger.debug("textIn range=\(String(describing: range.nsRange), privacy: .public) -> \(result, privacy: .public)")
        return result
    }

    func replace(_ range: UITextRange, withText text: String) {
        if documentMode == .nativeSelection {
            guard !text.isEmpty,
                  terminalOwner?.exitNativeSelectionTextInputContextForTerminalInput() == true else {
                return
            }
            _ = terminalOwner?.handleIMEProxyInsertText(text, fromIMEComposition: false)
            return
        }
        Self.dictationLogger.debug("replace range=\(String(describing: (range as? TerminalNativeTextRange)?.nsRange), privacy: .public) text=\(text, privacy: .public) doc=\(self.documentBuffer, privacy: .public) session=\(self.dictationSessionOrigin?.rawValue ?? "none", privacy: .public)")
        guard let range = range as? TerminalNativeTextRange else {
            if !text.isEmpty {
                insertText(text)
            }
            return
        }
        if documentBuffer.isEmpty, text.isEmpty {
            notifyVirtualDeleteAnchorDidChange()
            terminalOwner?.imeProxyDidDeleteBackward(before: terminalOwner?.imeProxySnapshot())
            return
        }
        beginDictationSessionIfInputModeActive()
        performDocumentEdit {
            let normalized = text.precomposedStringWithCanonicalMapping
            let clamped = clampedRange(range.nsRange)
            documentBuffer = (documentBuffer as NSString).replacingCharacters(in: clamped, with: normalized)
            adjustMarkedRange(afterReplacing: clamped, insertedLength: (normalized as NSString).length)
            selectedRange = NSRange(
                location: clamped.location + (normalized as NSString).length,
                length: 0
            )
        }
    }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? TerminalNativeTextPosition,
              let to = toPosition as? TerminalNativeTextPosition else { return nil }
        return TerminalNativeTextRange(start: from.offset, end: to.offset)
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? TerminalNativeTextPosition else { return nil }
        return TerminalNativeTextPosition(
            offset: activeClampedOffset(position.offset, adding: offset)
        )
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        guard let position = position as? TerminalNativeTextPosition else { return nil }
        switch direction {
        case .left:
            return TerminalNativeTextPosition(
                offset: activeClampedOffset(position.offset, subtracting: offset)
            )
        case .right:
            return TerminalNativeTextPosition(
                offset: activeClampedOffset(position.offset, adding: offset)
            )
        case .up:
            return TerminalNativeTextPosition(
                offset: activeClampedOffset(
                    position.offset,
                    subtracting: saturatingProduct(offset, activeDocumentColumns)
                )
            )
        case .down:
            return TerminalNativeTextPosition(
                offset: activeClampedOffset(
                    position.offset,
                    adding: saturatingProduct(offset, activeDocumentColumns)
                )
            )
        @unknown default:
            return TerminalNativeTextPosition(
                offset: activeClampedOffset(position.offset, adding: offset)
            )
        }
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let position = position as? TerminalNativeTextPosition,
              let other = other as? TerminalNativeTextPosition else { return .orderedSame }
        if position.offset < other.offset { return .orderedAscending }
        if position.offset > other.offset { return .orderedDescending }
        return .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard let from = from as? TerminalNativeTextPosition,
              let to = toPosition as? TerminalNativeTextPosition else { return 0 }
        return activeClampedOffset(to.offset) - activeClampedOffset(from.offset)
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        guard let range = range as? TerminalNativeTextRange else { return nil }
        switch direction {
        case .left, .up:
            return TerminalNativeTextPosition(
                offset: activeClampedOffset(range.startPosition.offset)
            )
        case .right, .down:
            return TerminalNativeTextPosition(
                offset: activeClampedOffset(range.endPosition.offset)
            )
        @unknown default:
            return TerminalNativeTextPosition(
                offset: activeClampedOffset(range.endPosition.offset)
            )
        }
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let position = position as? TerminalNativeTextPosition else { return nil }
        switch direction {
        case .left, .up:
            return TerminalNativeTextRange(
                start: activeClampedOffset(position.offset, adding: -1),
                end: activeClampedOffset(position.offset)
            )
        case .right, .down:
            return TerminalNativeTextRange(
                start: activeClampedOffset(position.offset),
                end: activeClampedOffset(position.offset, adding: 1)
            )
        @unknown default:
            return TerminalNativeTextRange(
                start: activeClampedOffset(position.offset),
                end: activeClampedOffset(position.offset, adding: 1)
            )
        }
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .natural
    }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {
    }

    func firstRect(for range: UITextRange) -> CGRect {
        if documentMode == .nativeSelection {
            guard let terminalOwner,
                  let range = terminalOwner.nativeSelectionSnapshot.nativeRange(from: range) else {
                return .zero
            }
            return terminalOwner.nativeSelectionSnapshot.firstRect(for: range)
        }
        return terminalOwner?.imeProxyFirstRect(for: range) ?? .zero
    }

    func caretRect(for position: UITextPosition) -> CGRect {
        if documentMode == .nativeSelection {
            guard let terminalOwner,
                  let position = position as? TerminalNativeTextPosition else {
                return .zero
            }
            return terminalOwner.nativeSelectionSnapshot.caretRect(for: position.offset)
        }
        return terminalOwner?.imeProxyCaretRect(for: position) ?? .zero
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
        guard documentMode == .nativeSelection,
              let terminalOwner,
              let range = terminalOwner.nativeSelectionSnapshot.nativeRange(from: range) else {
            return []
        }
        return terminalOwner.nativeSelectionSnapshot.selectionRects(for: range)
    }

    func closestPosition(to point: CGPoint) -> UITextPosition? {
        if documentMode == .nativeSelection, let terminalOwner {
            return TerminalNativeTextPosition(
                offset: terminalOwner.nativeSelectionSnapshot.offset(for: point)
            )
        }
        return TerminalNativeTextPosition(offset: textInputDocumentLength)
    }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        if documentMode == .nativeSelection {
            guard let terminalOwner,
                  let range = terminalOwner.nativeSelectionSnapshot.nativeRange(from: range) else {
                return nil
            }
            let offset = terminalOwner.nativeSelectionSnapshot.offset(for: point)
            let upperBound = terminalOwner.nativeSelectionSnapshot.upperBound(of: range)
            return TerminalNativeTextPosition(
                offset: min(max(offset, range.location), upperBound)
            )
        }
        guard let range = range as? TerminalNativeTextRange else {
            return closestPosition(to: point)
        }
        return TerminalNativeTextPosition(offset: range.endPosition.offset)
    }

    func characterRange(at point: CGPoint) -> UITextRange? {
        guard documentMode == .nativeSelection,
              let terminalOwner,
              let range = terminalOwner.nativeSelectionSnapshot.characterRange(at: point) else {
            return nil
        }
        let upperBound = terminalOwner.nativeSelectionSnapshot.upperBound(of: range)
        return TerminalNativeTextRange(start: range.location, end: upperBound)
    }

    func textStyling(at position: UITextPosition, in direction: UITextStorageDirection) -> [NSAttributedString.Key: Any]? {
        markedTextStyle
    }

    @available(iOS 16.0, *)
    func editMenu(for textRange: UITextRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard documentMode == .nativeSelection, let terminalOwner else { return nil }
        return UIMenu(children: terminalOwner.nativeSelectionMenuElements())
    }

    func position(within range: UITextRange, atCharacterOffset offset: Int) -> UITextPosition? {
        guard let range = range as? TerminalNativeTextRange else { return nil }
        return TerminalNativeTextPosition(
            offset: activeClampedOffset(range.startPosition.offset, adding: offset)
        )
    }

    func characterOffset(of position: UITextPosition, within range: UITextRange) -> Int {
        guard let position = position as? TerminalNativeTextPosition,
              let range = range as? TerminalNativeTextRange else {
            return 0
        }
        return activeClampedOffset(position.offset)
            - activeClampedOffset(range.startPosition.offset)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let terminalOwner else {
            super.pressesBegan(presses, with: event)
            return
        }
        let pendingCount = terminalOwner.pendingSystemTextInputHardwareKeys.count
        let result = terminalOwner.processHardwarePressesBegan(presses, event: event)
        if !result.forwardedToSystem.isEmpty {
            super.pressesBegan(result.forwardedToSystem, with: event)
            terminalOwner.removeUnconsumedPendingSystemTextInputHardwareKeys(after: pendingCount)
        }
        if result.didHandleGhosttyInput {
            terminalOwner.requestRender()
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let terminalOwner else {
            super.pressesEnded(presses, with: event)
            return
        }
        let result = terminalOwner.processHardwarePressesEnded(presses, event: event)
        if !result.forwardedToSystem.isEmpty {
            super.pressesEnded(result.forwardedToSystem, with: event)
        }
        if result.didHandleGhosttyInput {
            terminalOwner.requestRender()
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesCancelled(presses, with: event)
        terminalOwner?.processHardwarePressesCancelled(presses)
    }

    func moveSelectionLeft() {
        guard selectedRange.location > 0 else { return }
        let previousRange = (documentBuffer as NSString).rangeOfComposedCharacterSequence(at: selectedRange.location - 1)
        selectedRange = NSRange(location: previousRange.location, length: 0)
        notifyTextInputStateDidChange()
    }

    func moveSelectionRight() {
        let length = documentBuffer.utf16.count
        guard selectedRange.location < length else { return }
        let nextRange = (documentBuffer as NSString).rangeOfComposedCharacterSequence(at: selectedRange.location)
        selectedRange = NSRange(location: nextRange.location + nextRange.length, length: 0)
        notifyTextInputStateDidChange()
    }

    func moveSelectionToStart() {
        selectedRange = NSRange(location: 0, length: 0)
        notifyTextInputStateDidChange()
    }

    func moveSelectionToEnd() {
        selectedRange = NSRange(location: documentBuffer.utf16.count, length: 0)
        notifyTextInputStateDidChange()
    }

    @objc
    private func handleTerminalNavigationCommand(_ sender: UIKeyCommand) {
        terminalOwner?.handleIMEProxyNavigationCommand(sender)
    }

    private func notifyTextInputStateDidChange() {
        terminalOwner?.syncTextInputModelFromIMEProxy()
    }

    private func prepareTerminalInputDocument() -> Bool {
        guard documentMode == .nativeSelection else { return true }
        guard terminalOwner?.suppressIMEProxyCallbacks != true else { return true }
        return terminalOwner?.exitNativeSelectionTextInputContextForTerminalInput() == true
    }

    private var usesDeleteRepeatAnchor: Bool {
        documentBuffer.isEmpty && terminalOwner?.canRouteProxyDeleteBackward == true
    }

    private var deleteRepeatAnchorText: String {
        deleteRepeatAnchorUsesAlternate ? "\u{2060}" : "\u{200B}"
    }

    private var textInputDocument: String {
        usesDeleteRepeatAnchor ? deleteRepeatAnchorText : documentBuffer
    }

    private var textInputDocumentLength: Int {
        (textInputDocument as NSString).length
    }

    private var activeDocumentLength: Int {
        if documentMode == .nativeSelection {
            return terminalOwner?.nativeSelectionSnapshot.length ?? 0
        }
        return textInputDocumentLength
    }

    private var activeDocumentColumns: Int {
        if documentMode == .nativeSelection {
            return terminalOwner?.nativeSelectionSnapshot.columns ?? 1
        }
        return 1
    }

    private var effectiveTextInputSelectedRange: NSRange {
        usesDeleteRepeatAnchor ? NSRange(location: textInputDocumentLength, length: 0) : selectedRange
    }

    private func notifyVirtualDeleteAnchorDidChange() {
        inputDelegate?.textWillChange(self)
        deleteRepeatAnchorUsesAlternate.toggle()
        inputDelegate?.textDidChange(self)
    }

    private func clampedRange(_ range: NSRange) -> NSRange {
        let length = documentBuffer.utf16.count
        let location = min(max(range.location, 0), length)
        let rangeLength = min(max(range.length, 0), max(length - location, 0))
        return NSRange(location: location, length: rangeLength)
    }

    private func clampedTextInputRange(_ range: NSRange) -> NSRange {
        let length = textInputDocumentLength
        let location = min(max(range.location, 0), length)
        let rangeLength = min(max(range.length, 0), max(length - location, 0))
        return NSRange(location: location, length: rangeLength)
    }

    private func clampedOffset(_ offset: Int) -> Int {
        min(max(offset, 0), textInputDocumentLength)
    }

    private func activeClampedOffset(_ offset: Int) -> Int {
        min(max(offset, 0), activeDocumentLength)
    }

    private func activeClampedOffset(_ offset: Int, adding delta: Int) -> Int {
        let addition = activeClampedOffset(offset).addingReportingOverflow(delta)
        if addition.overflow {
            return delta >= 0 ? activeDocumentLength : 0
        }
        return activeClampedOffset(addition.partialValue)
    }

    private func activeClampedOffset(_ offset: Int, subtracting delta: Int) -> Int {
        let subtraction = activeClampedOffset(offset).subtractingReportingOverflow(delta)
        if subtraction.overflow {
            return delta >= 0 ? 0 : activeDocumentLength
        }
        return activeClampedOffset(subtraction.partialValue)
    }

    private func saturatingProduct(_ value: Int, _ factor: Int) -> Int {
        let multiplication = value.multipliedReportingOverflow(by: factor)
        guard multiplication.overflow else { return multiplication.partialValue }
        return (value >= 0) == (factor >= 0) ? Int.max : Int.min
    }

    private static func makeTerminalNavigationCommands(action: Selector) -> [UIKeyCommand] {
        terminalNavigationInputs.flatMap { input in
            terminalNavigationModifierCombinations.compactMap { modifiers in
                guard TerminalSplitShortcutRouting.command(
                    for: input,
                    modifiers: modifiers.terminalSplitShortcutModifiers
                ) == nil else {
                    return nil
                }
                let command = UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
                if #available(iOS 15.0, *) {
                    command.wantsPriorityOverSystemBehavior = true
                    command.allowsAutomaticLocalization = false
                    command.allowsAutomaticMirroring = false
                }
                return command
            }
        }
    }
}

#endif
