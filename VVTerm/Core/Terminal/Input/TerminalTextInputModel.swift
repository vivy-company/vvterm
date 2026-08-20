import Foundation

nonisolated struct TerminalTextInputModel: Sendable {
    nonisolated enum SpecialKey: Equatable, Sendable {
        case enter
        case tab
        case backspace
    }

    nonisolated enum InsertOperation: Equatable, Sendable {
        case text(String)
        case specialKey(SpecialKey)
    }

    nonisolated enum Effect: Equatable, Sendable {
        case willTextChange
        case willSelectionChange
        case didTextChange
        case didSelectionChange
        case syncPreedit(String?)
        case sendText(String)
        case sendBackspaces(Int)
        case moveCursor(Int)
        case sendSpecialKey(SpecialKey)
    }

    nonisolated struct Range: Equatable, Sendable {
        var location: Int
        var length: Int

        var end: Int { location + length }
        var isEmpty: Bool { length == 0 }

        init(location: Int, length: Int) {
            self.location = max(location, 0)
            self.length = max(length, 0)
        }
    }

    nonisolated private struct Projection: Equatable, Sendable {
        var text: String
        var cursorCharacterIndex: Int
    }

    private(set) var text: String
    private(set) var selectedRange: Range
    private(set) var markedRange: Range?

    init(
        text: String = "",
        selectedRange: Range = Range(location: 0, length: 0),
        markedRange: Range? = nil
    ) {
        self.text = text.precomposedStringWithCanonicalMapping
        self.selectedRange = selectedRange
        self.markedRange = markedRange
        clampState()
    }

    init(committedTextBeforeCursor: String = "", cursorIndex: Int = 0) {
        let normalized = committedTextBeforeCursor.precomposedStringWithCanonicalMapping
        let clampedCursor = min(max(cursorIndex, 0), (normalized as NSString).length)
        self.init(
            text: normalized,
            selectedRange: Range(location: clampedCursor, length: 0),
            markedRange: nil
        )
    }

    var documentLength: Int {
        (text as NSString).length
    }

    var cursorIndex: Int {
        selectedRange.end
    }

    var hasActiveIMEComposition: Bool {
        markedRange != nil
    }

    var markedTextStartIndex: Int? {
        markedRange?.location
    }

    var markedText: String {
        guard let markedRange else { return "" }
        return substring(in: markedRange) ?? ""
    }

    var markedSelectionLocation: Int {
        guard let markedRange else { return 0 }
        return max(selectedRange.location - markedRange.location, 0)
    }

    var markedSelectionLength: Int {
        guard markedRange != nil else { return 0 }
        return selectedRange.length
    }

    var committedTextBeforeCursor: String {
        let projection = committedProjection()
        let chars = Array(projection.text)
        let end = min(max(projection.cursorCharacterIndex, 0), chars.count)
        return String(chars.prefix(end))
    }

    var committedCursorCharacterIndex: Int {
        committedProjection().cursorCharacterIndex
    }

    static func insertOperation(for text: String, fromIMEComposition _: Bool) -> InsertOperation {
        if text == "\n" || text == "\r" {
            return .specialKey(.enter)
        }
        if text == "\t" {
            return .specialKey(.tab)
        }

        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.contains("\n") {
            return .text(normalized.replacingOccurrences(of: "\n", with: "\r"))
        }

        return .text(text)
    }

    mutating func handleSetSelection(location: Int, length: Int = 0) -> [Effect] {
        let oldProjection = committedProjection()
        let oldRange = selectedRange
        let newRange = clamp(range: Range(location: location, length: length))
        guard newRange != oldRange else { return [] }

        selectedRange = newRange
        clampState()

        var effects: [Effect] = [.willSelectionChange]
        effects.append(contentsOf: transitionEffects(from: oldProjection, to: committedProjection()))
        effects.append(.didSelectionChange)
        return compactEffects(effects)
    }

    mutating func handleExternalState(text: String, selectedRange: Range, markedRange: Range?) -> [Effect] {
        let oldText = self.text
        let oldSelection = self.selectedRange
        let oldMarkedRange = self.markedRange
        let oldMarkedText = self.markedText
        let oldProjection = committedProjection()

        self.text = text.precomposedStringWithCanonicalMapping
        self.selectedRange = selectedRange
        self.markedRange = markedRange
        clampState()

        let newMarkedText = self.markedText
        let newProjection = committedProjection()
        let textChanged = oldText != self.text || oldMarkedRange != self.markedRange || oldMarkedText != newMarkedText
        let selectionChanged = oldSelection != self.selectedRange

        guard textChanged || selectionChanged || oldProjection != newProjection else {
            return []
        }

        var effects: [Effect] = []
        if textChanged {
            effects.append(.willTextChange)
        }
        if selectionChanged {
            effects.append(.willSelectionChange)
        }
        if oldMarkedText != newMarkedText || oldMarkedRange != self.markedRange {
            effects.append(.syncPreedit(newMarkedText.isEmpty ? nil : newMarkedText))
        }
        effects.append(contentsOf: transitionEffects(from: oldProjection, to: newProjection))
        if textChanged {
            effects.append(.didTextChange)
        }
        if selectionChanged {
            effects.append(.didSelectionChange)
        }
        return compactEffects(effects)
    }

    mutating func handleMoveCursorLeft() -> [Effect] {
        let targetLocation: Int
        if !selectedRange.isEmpty {
            targetLocation = selectedRange.location
        } else if let previousCharacterRange = characterRange(beforeUTF16Offset: selectedRange.location) {
            targetLocation = previousCharacterRange.location
        } else {
            targetLocation = 0
        }
        return handleSetSelection(location: targetLocation, length: 0)
    }

    mutating func handleMoveCursorRight() -> [Effect] {
        let targetLocation: Int
        if !selectedRange.isEmpty {
            targetLocation = selectedRange.end
        } else if let nextCharacterRange = characterRange(afterUTF16Offset: selectedRange.location) {
            targetLocation = nextCharacterRange.end
        } else {
            targetLocation = documentLength
        }
        return handleSetSelection(location: targetLocation, length: 0)
    }

    mutating func handleMoveCursorToStart() -> [Effect] {
        handleSetSelection(location: 0, length: 0)
    }

    mutating func handleMoveCursorToEnd() -> [Effect] {
        handleSetSelection(location: documentLength, length: 0)
    }

    mutating func invalidateSession() -> [Effect] {
        guard !text.isEmpty || markedRange != nil || !selectedRange.isEmpty || selectedRange.location != 0 else {
            return []
        }

        let hadMarkedText = markedRange != nil
        text = ""
        selectedRange = Range(location: 0, length: 0)
        markedRange = nil

        var effects: [Effect] = [.willTextChange, .willSelectionChange]
        if hadMarkedText {
            effects.append(.syncPreedit(nil))
        }
        effects.append(.didTextChange)
        effects.append(.didSelectionChange)
        return compactEffects(effects)
    }

    func textInputActualContextRange() -> (start: Int, text: String)? {
        guard !text.isEmpty else { return nil }
        return (start: 0, text: text)
    }

    func substring(rangeStart: Int, rangeEnd: Int) -> String? {
        substring(in: clamp(range: Range(location: min(rangeStart, rangeEnd), length: abs(rangeEnd - rangeStart))))
    }

    func committedContextSubstring(rangeStart: Int, rangeEnd: Int) -> String? {
        let query = clamp(range: Range(location: min(rangeStart, rangeEnd), length: abs(rangeEnd - rangeStart)))
        if let markedRange, rangesOverlap(query, markedRange) {
            return nil
        }
        return substring(in: query)
    }

    mutating func handleInsert(_ operation: InsertOperation) -> [Effect] {
        switch operation {
        case let .specialKey(key):
            return handleSpecialInsert(key: key)
        case let .text(insertedText):
            let oldProjection = committedProjection()
            let oldHadMarked = hasActiveIMEComposition
            let replacementRange = markedRange ?? selectedRange

            replaceStorage(in: replacementRange, with: insertedText.precomposedStringWithCanonicalMapping)
            markedRange = nil
            selectedRange = Range(location: replacementRange.location + insertedText.utf16.count, length: 0)
            clampState()

            var effects: [Effect] = [.willTextChange]
            if oldHadMarked {
                effects.append(.willSelectionChange)
                effects.append(.syncPreedit(nil))
            }
            effects.append(contentsOf: transitionEffects(from: oldProjection, to: committedProjection()))
            effects.append(.didTextChange)
            if oldHadMarked {
                effects.append(.didSelectionChange)
            }
            return compactEffects(effects)
        }
    }

    mutating func handleDeleteBackward() -> [Effect] {
        let oldProjection = committedProjection()
        if let markedRange {
            let deletionRange: Range
            if !selectedRange.isEmpty {
                deletionRange = clamp(range: selectedRange)
            } else if let previousCharacterRange = characterRange(beforeUTF16Offset: selectedRange.location) {
                deletionRange = clampToMarked(previousCharacterRange, markedRange: markedRange)
            } else {
                deletionRange = Range(location: markedRange.location, length: 0)
            }

            guard deletionRange.length > 0 else {
                return [.syncPreedit(markedText.isEmpty ? nil : markedText)]
            }

            replaceStorage(in: deletionRange, with: "")
            let updatedLength = max(markedRange.length - deletionRange.length, 0)
            if updatedLength == 0 {
                self.markedRange = nil
                selectedRange = Range(location: deletionRange.location, length: 0)
            } else {
                self.markedRange = Range(location: markedRange.location, length: updatedLength)
                selectedRange = Range(location: deletionRange.location, length: 0)
            }
            clampState()

            var effects: [Effect] = [.willTextChange, .willSelectionChange]
            effects.append(.syncPreedit(self.markedRange == nil ? nil : markedText))
            effects.append(contentsOf: transitionEffects(from: oldProjection, to: committedProjection()))
            effects.append(.didTextChange)
            effects.append(.didSelectionChange)
            return compactEffects(effects)
        }

        let deletionRange: Range
        if !selectedRange.isEmpty {
            deletionRange = clamp(range: selectedRange)
        } else if let previousCharacterRange = characterRange(beforeUTF16Offset: selectedRange.location) {
            deletionRange = previousCharacterRange
        } else {
            return [.sendSpecialKey(.backspace)]
        }

        replaceStorage(in: deletionRange, with: "")
        selectedRange = Range(location: deletionRange.location, length: 0)
        clampState()

        var effects: [Effect] = [.willTextChange]
        effects.append(contentsOf: transitionEffects(from: oldProjection, to: committedProjection()))
        effects.append(.didTextChange)
        return compactEffects(effects)
    }

    mutating func handleReplace(rangeStart: Int?, rangeEnd: Int? = nil, text replacementText: String) -> [Effect] {
        let replacementRange: Range
        if let rangeStart {
            let end = rangeEnd ?? rangeStart
            replacementRange = clamp(range: Range(location: min(rangeStart, end), length: abs(end - rangeStart)))
        } else {
            replacementRange = markedRange ?? selectedRange
        }

        let oldProjection = committedProjection()
        let oldHadMarked = hasActiveIMEComposition
        replaceStorage(in: replacementRange, with: replacementText.precomposedStringWithCanonicalMapping)
        markedRange = nil
        selectedRange = Range(location: replacementRange.location + replacementText.utf16.count, length: 0)
        clampState()

        var effects: [Effect] = [.willTextChange]
        if oldHadMarked {
            effects.append(.willSelectionChange)
            effects.append(.syncPreedit(nil))
        }
        effects.append(contentsOf: transitionEffects(from: oldProjection, to: committedProjection()))
        effects.append(.didTextChange)
        if oldHadMarked {
            effects.append(.didSelectionChange)
        }
        return compactEffects(effects)
    }

    mutating func handleSetMarkedText(_ text: String?, selectedRangeLocation: Int, selectedRangeLength: Int = 0) -> [Effect] {
        let oldProjection = committedProjection()
        let oldMarkedText = markedText
        let oldSelection = selectedRange
        let replacementRange = markedRange ?? selectedRange
        let replacementLocation = replacementRange.location
        let normalized = text?.precomposedStringWithCanonicalMapping ?? ""

        replaceStorage(in: replacementRange, with: normalized)

        if normalized.isEmpty {
            markedRange = nil
            selectedRange = Range(location: replacementLocation, length: 0)
        } else {
            let newMarkedRange = Range(location: replacementLocation, length: normalized.utf16.count)
            markedRange = newMarkedRange
            let clampedSelectionLocation = min(max(selectedRangeLocation, 0), newMarkedRange.length)
            let clampedSelectionLength = min(
                max(selectedRangeLength, 0),
                max(newMarkedRange.length - clampedSelectionLocation, 0)
            )
            selectedRange = Range(
                location: newMarkedRange.location + clampedSelectionLocation,
                length: clampedSelectionLength
            )
        }
        clampState()

        var effects: [Effect] = [.willTextChange, .willSelectionChange]
        if oldMarkedText != normalized || !normalized.isEmpty || !oldMarkedText.isEmpty {
            effects.append(.syncPreedit(normalized.isEmpty ? nil : normalized))
        }
        effects.append(contentsOf: transitionEffects(from: oldProjection, to: committedProjection()))
        effects.append(.didTextChange)
        if oldSelection != selectedRange {
            effects.append(.didSelectionChange)
        }
        return compactEffects(effects)
    }

    mutating func handleUnmarkText() -> [Effect] {
        guard markedRange != nil else {
            return [.syncPreedit(nil)]
        }

        let oldProjection = committedProjection()
        let oldSelection = selectedRange
        let markedEnd = markedRange?.end ?? selectedRange.end
        markedRange = nil
        selectedRange = Range(location: markedEnd, length: 0)
        clampState()

        var effects: [Effect] = [.willTextChange, .willSelectionChange]
        effects.append(.syncPreedit(nil))
        effects.append(contentsOf: transitionEffects(from: oldProjection, to: committedProjection()))
        effects.append(.didTextChange)
        if oldSelection != selectedRange {
            effects.append(.didSelectionChange)
        }
        return compactEffects(effects)
    }

    func committedCharacterIndex(forDocumentOffset offset: Int) -> Int {
        let clampedOffset = min(max(offset, 0), documentLength)
        if let markedRange {
            if clampedOffset <= markedRange.location {
                return characterIndex(forUTF16Offset: clampedOffset, in: text)
            }
            if clampedOffset <= markedRange.end {
                return characterIndex(forUTF16Offset: markedRange.location, in: text)
            }
            return characterIndex(forUTF16Offset: clampedOffset - markedRange.length, in: committedProjection().text)
        }
        return characterIndex(forUTF16Offset: clampedOffset, in: text)
    }

    private mutating func handleSpecialInsert(key: SpecialKey) -> [Effect] {
        switch key {
        case .backspace:
            return handleDeleteBackward()
        case .enter, .tab:
            var effects: [Effect] = []
            if hasActiveIMEComposition {
                effects.append(.syncPreedit(nil))
            }
            _ = invalidateSession()
            effects.append(.sendSpecialKey(key))
            return compactEffects(effects)
        }
    }

    private func committedProjection() -> Projection {
        let currentText = text
        let currentSelection = clamp(range: selectedRange)
        guard let markedRange else {
            return Projection(
                text: currentText,
                cursorCharacterIndex: characterIndex(forUTF16Offset: currentSelection.end, in: currentText)
            )
        }

        let prefix = substring(in: Range(location: 0, length: markedRange.location)) ?? ""
        let suffix = substring(in: Range(location: markedRange.end, length: max(documentLength - markedRange.end, 0))) ?? ""
        let committedText = prefix + suffix
        let committedCursorUTF16: Int
        if currentSelection.end <= markedRange.location {
            committedCursorUTF16 = currentSelection.end
        } else if currentSelection.end <= markedRange.end {
            committedCursorUTF16 = markedRange.location
        } else {
            committedCursorUTF16 = currentSelection.end - markedRange.length
        }

        return Projection(
            text: committedText,
            cursorCharacterIndex: characterIndex(forUTF16Offset: committedCursorUTF16, in: committedText)
        )
    }

    private func transitionEffects(from oldProjection: Projection, to newProjection: Projection) -> [Effect] {
        if oldProjection == newProjection {
            return []
        }

        if oldProjection.text == newProjection.text {
            return cursorMoveEffects(delta: newProjection.cursorCharacterIndex - oldProjection.cursorCharacterIndex)
        }

        let oldChars = Array(oldProjection.text)
        let newChars = Array(newProjection.text)

        var prefixLength = 0
        while prefixLength < min(oldChars.count, newChars.count), oldChars[prefixLength] == newChars[prefixLength] {
            prefixLength += 1
        }

        var oldSuffixLength = 0
        while oldSuffixLength < (oldChars.count - prefixLength),
              oldSuffixLength < (newChars.count - prefixLength),
              oldChars[oldChars.count - 1 - oldSuffixLength] == newChars[newChars.count - 1 - oldSuffixLength] {
            oldSuffixLength += 1
        }

        let oldRemovedStart = prefixLength
        let oldRemovedEnd = oldChars.count - oldSuffixLength
        let newInsertedEnd = newChars.count - oldSuffixLength
        let removedCount = max(oldRemovedEnd - oldRemovedStart, 0)
        let inserted = String(newChars[oldRemovedStart..<newInsertedEnd])

        var effects: [Effect] = []
        effects.append(contentsOf: cursorMoveEffects(delta: oldRemovedEnd - oldProjection.cursorCharacterIndex))
        if removedCount > 0 {
            effects.append(.sendBackspaces(removedCount))
        }
        if !inserted.isEmpty {
            effects.append(.sendText(inserted))
        }
        let cursorAfterEdit = prefixLength + Array(inserted).count
        effects.append(contentsOf: cursorMoveEffects(delta: newProjection.cursorCharacterIndex - cursorAfterEdit))
        return compactEffects(effects)
    }

    private func cursorMoveEffects(delta: Int) -> [Effect] {
        guard delta != 0 else { return [] }
        return [.moveCursor(delta)]
    }

    private mutating func replaceStorage(in range: Range, with replacement: String) {
        let clampedRange = clamp(range: range)
        let nsText = text as NSString
        text = nsText
            .replacingCharacters(
                in: NSRange(location: clampedRange.location, length: clampedRange.length),
                with: replacement
            )
            .precomposedStringWithCanonicalMapping
    }

    private mutating func clampState() {
        selectedRange = clamp(range: selectedRange)
        if let markedRange {
            let clampedMarkedRange = clamp(range: markedRange)
            self.markedRange = clampedMarkedRange.isEmpty ? nil : clampedMarkedRange
            if !clampedMarkedRange.isEmpty, !rangeContains(clampedMarkedRange, selectedRange) {
                selectedRange = Range(location: clampedMarkedRange.end, length: 0)
            }
        }
    }

    private func clamp(range: Range) -> Range {
        let length = documentLength
        let clampedLocation = min(max(range.location, 0), length)
        let clampedLength = min(max(range.length, 0), max(length - clampedLocation, 0))
        return Range(location: clampedLocation, length: clampedLength)
    }

    private func clampToMarked(_ range: Range, markedRange: Range) -> Range {
        let lower = max(range.location, markedRange.location)
        let upper = min(range.end, markedRange.end)
        return Range(location: lower, length: max(upper - lower, 0))
    }

    private func rangeContains(_ outer: Range, _ inner: Range) -> Bool {
        outer.location <= inner.location && outer.end >= inner.end
    }

    private func rangesOverlap(_ lhs: Range, _ rhs: Range) -> Bool {
        lhs.location < rhs.end && rhs.location < lhs.end
    }

    private func substring(in range: Range) -> String? {
        let clampedRange = clamp(range: range)
        let nsText = text as NSString
        guard clampedRange.location + clampedRange.length <= nsText.length else { return nil }
        return nsText.substring(with: NSRange(location: clampedRange.location, length: clampedRange.length))
    }

    private func characterRange(beforeUTF16Offset offset: Int) -> Range? {
        guard offset > 0 else { return nil }
        guard let endIndex = stringIndex(utf16Offset: offset, in: text) else { return nil }
        let startIndex = text.index(before: endIndex)
        return Range(
            location: startIndex.utf16Offset(in: text),
            length: endIndex.utf16Offset(in: text) - startIndex.utf16Offset(in: text)
        )
    }

    private func characterRange(afterUTF16Offset offset: Int) -> Range? {
        guard offset < documentLength else { return nil }
        guard let startIndex = stringIndex(utf16Offset: offset, in: text) else { return nil }
        guard startIndex < text.endIndex else { return nil }
        let endIndex = text.index(after: startIndex)
        return Range(
            location: startIndex.utf16Offset(in: text),
            length: endIndex.utf16Offset(in: text) - startIndex.utf16Offset(in: text)
        )
    }

    private func stringIndex(utf16Offset: Int, in source: String) -> String.Index? {
        let utf16 = source.utf16
        guard utf16Offset >= 0, utf16Offset <= utf16.count else { return nil }
        let index = utf16.index(utf16.startIndex, offsetBy: utf16Offset)
        return String.Index(index, within: source)
    }

    private func characterIndex(forUTF16Offset offset: Int, in source: String) -> Int {
        guard let stringIndex = stringIndex(utf16Offset: offset, in: source) else {
            return Array(source).count
        }
        return source.distance(from: source.startIndex, to: stringIndex)
    }

    private func compactEffects(_ effects: [Effect]) -> [Effect] {
        var compacted: [Effect] = []
        for effect in effects where compacted.last != effect {
            compacted.append(effect)
        }
        return compacted
    }
}
