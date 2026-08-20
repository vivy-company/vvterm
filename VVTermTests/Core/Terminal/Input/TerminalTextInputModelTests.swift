import Foundation
import Testing
@testable import VVTerm

struct TerminalTextInputModelTests {
    @Test
    func setMarkedTextStoresCompositionInLocalBuffer() {
        var model = TerminalTextInputModel(committedTextBeforeCursor: "", cursorIndex: 0)

        let effects = model.handleSetMarkedText("nihon", selectedRangeLocation: 3, selectedRangeLength: 1)

        #expect(effects == [.willTextChange, .willSelectionChange, .syncPreedit("nihon"), .didTextChange, .didSelectionChange])
        #expect(model.text == "nihon")
        #expect(model.markedText == "nihon")
        #expect(model.markedTextStartIndex == 0)
        #expect(model.markedSelectionLocation == 3)
        #expect(model.markedSelectionLength == 1)
        #expect(model.selectedRange == .init(location: 3, length: 1))
        #expect(model.committedTextBeforeCursor.isEmpty)
    }

    @Test
    func insertTextCommitsMarkedTextWithoutSyntheticReplacementPath() {
        var model = TerminalTextInputModel()

        _ = model.handleSetMarkedText("하", selectedRangeLocation: 1)
        let effects = model.handleInsert(.text("하"))

        #expect(effects == [.willTextChange, .willSelectionChange, .syncPreedit(nil), .sendText("하"), .didTextChange, .didSelectionChange])
        #expect(model.markedRange == nil)
        #expect(model.text == "하")
        #expect(model.committedTextBeforeCursor == "하")
    }

    @Test
    func exactCommittedReplacementUsesCharacterCountsAndKeepsSuffix() {
        var model = TerminalTextInputModel(committedTextBeforeCursor: "a👍b", cursorIndex: 4)

        let effects = model.handleReplace(rangeStart: 1, rangeEnd: 3, text: "x")

        #expect(effects == [.willTextChange, .moveCursor(-1), .sendBackspaces(1), .sendText("x"), .didTextChange])
        #expect(model.text == "axb")
        #expect(model.committedTextBeforeCursor == "ax")
    }

    @Test
    func deleteBackwardInsideMarkedTextOnlyUpdatesPreedit() {
        var model = TerminalTextInputModel()

        _ = model.handleSetMarkedText("한", selectedRangeLocation: 1)
        let effects = model.handleDeleteBackward()

        #expect(effects == [.willTextChange, .willSelectionChange, .syncPreedit(nil), .didTextChange, .didSelectionChange])
        #expect(model.markedRange == nil)
        #expect(model.text.isEmpty)
    }

    @Test
    func deleteBackwardInsideLongMarkedTextKeepsCompositionActive() {
        var model = TerminalTextInputModel()

        _ = model.handleSetMarkedText("nihon", selectedRangeLocation: 5)
        let effects = model.handleDeleteBackward()

        #expect(effects == [.willTextChange, .willSelectionChange, .syncPreedit("niho"), .didTextChange, .didSelectionChange])
        #expect(model.hasActiveIMEComposition)
        #expect(model.markedText == "niho")
        #expect(model.text == "niho")
        #expect(model.selectedRange == .init(location: 4, length: 0))
    }

    @Test
    func unmarkCommitsLatestMarkedTextIntoCommittedBuffer() {
        var model = TerminalTextInputModel(committedTextBeforeCursor: "日本", cursorIndex: 2)

        _ = model.handleSetMarkedText("語", selectedRangeLocation: 1)
        let effects = model.handleUnmarkText()

        #expect(effects == [.willTextChange, .willSelectionChange, .syncPreedit(nil), .sendText("語"), .didTextChange])
        #expect(model.markedRange == nil)
        #expect(model.text == "日本語")
        #expect(model.committedTextBeforeCursor == "日本語")
    }

    @Test
    func textContextIncludesMarkedText() {
        var model = TerminalTextInputModel(committedTextBeforeCursor: "日本", cursorIndex: 2)

        _ = model.handleSetMarkedText("ご", selectedRangeLocation: 1)

        let context = model.textInputActualContextRange()

        #expect(context?.start == 0)
        #expect(context?.text == "日本ご")
        #expect(model.committedContextSubstring(rangeStart: 0, rangeEnd: 2) == "日本")
        #expect(model.committedContextSubstring(rangeStart: 2, rangeEnd: 3) == nil)
    }

    @Test
    func candidateReplacementUsesExactMarkedRange() {
        var model = TerminalTextInputModel()

        _ = model.handleSetMarkedText("nihon", selectedRangeLocation: 5)
        let markedStart = model.markedTextStartIndex
        let markedEnd = markedStart.map { $0 + model.markedText.utf16.count }
        let effects = model.handleReplace(rangeStart: markedStart, rangeEnd: markedEnd, text: "日本")

        #expect(effects == [.willTextChange, .willSelectionChange, .syncPreedit(nil), .sendText("日本"), .didTextChange, .didSelectionChange])
        #expect(model.markedRange == nil)
        #expect(model.text == "日本")
        #expect(model.committedTextBeforeCursor == "日本")
    }

    @Test
    func directAsciiInsertUsesTextPath() {
        var model = TerminalTextInputModel()

        let operation = TerminalTextInputModel.insertOperation(for: "a", fromIMEComposition: false)
        let effects = model.handleInsert(operation)

        #expect(operation == .text("a"))
        #expect(effects == [.willTextChange, .sendText("a"), .didTextChange])
        #expect(model.text == "a")
    }

    @Test
    func selectionChangesMoveCommittedCursorInsideLocalSession() {
        var model = TerminalTextInputModel(committedTextBeforeCursor: "hello", cursorIndex: 5)

        let effects = model.handleSetSelection(location: 2, length: 0)

        #expect(effects == [.willSelectionChange, .moveCursor(-3), .didSelectionChange])
        #expect(model.selectedRange == .init(location: 2, length: 0))
        #expect(model.committedTextBeforeCursor == "he")
    }

    @Test
    func moveCursorLeftAndDeleteRemovesCharacterBeforeCaret() {
        var model = TerminalTextInputModel(committedTextBeforeCursor: "dk", cursorIndex: 2)

        let moveEffects = model.handleMoveCursorLeft()
        let deleteEffects = model.handleDeleteBackward()

        #expect(moveEffects == [.willSelectionChange, .moveCursor(-1), .didSelectionChange])
        #expect(deleteEffects == [.willTextChange, .sendBackspaces(1), .didTextChange])
        #expect(model.text == "k")
        #expect(model.selectedRange == .init(location: 0, length: 0))
    }

    @Test
    func proxySelectionOfLastCharacterDoesNotMoveTerminalCursor() {
        var model = TerminalTextInputModel()

        _ = model.handleExternalState(
            text: "d",
            selectedRange: .init(location: 1, length: 0),
            markedRange: nil
        )
        let effects = model.handleExternalState(
            text: "d",
            selectedRange: .init(location: 0, length: 1),
            markedRange: nil
        )

        #expect(effects == [.willSelectionChange, .didSelectionChange])
        #expect(model.text == "d")
        #expect(model.committedTextBeforeCursor == "d")
    }

    @Test
    func proxyKoreanRewriteSequenceCommitsSingleSyllable() {
        var model = TerminalTextInputModel()

        let first = model.handleExternalState(
            text: "ㅇ",
            selectedRange: .init(location: 0, length: 1),
            markedRange: nil
        )
        let second = model.handleExternalState(
            text: "",
            selectedRange: .init(location: 0, length: 0),
            markedRange: nil
        )
        let third = model.handleExternalState(
            text: "아",
            selectedRange: .init(location: 1, length: 0),
            markedRange: nil
        )
        let fourth = model.handleExternalState(
            text: "안",
            selectedRange: .init(location: 1, length: 0),
            markedRange: nil
        )

        #expect(first == [.willTextChange, .willSelectionChange, .sendText("ㅇ"), .didTextChange, .didSelectionChange])
        #expect(second == [.willTextChange, .willSelectionChange, .sendBackspaces(1), .didTextChange, .didSelectionChange])
        #expect(third == [.willTextChange, .willSelectionChange, .sendText("아"), .didTextChange, .didSelectionChange])
        #expect(fourth == [.willTextChange, .sendBackspaces(1), .sendText("안"), .didTextChange])
        #expect(model.text == "안")
        #expect(model.committedTextBeforeCursor == "안")
        #expect(model.selectedRange == .init(location: 1, length: 0))
    }

    @Test
    func invalidatingSessionClearsLocalBufferWithoutTerminalDiff() {
        var model = TerminalTextInputModel(text: "nihon", selectedRange: .init(location: 5, length: 0), markedRange: .init(location: 0, length: 5))

        let effects = model.invalidateSession()

        #expect(effects == [.willTextChange, .willSelectionChange, .syncPreedit(nil), .didTextChange, .didSelectionChange])
        #expect(model.text.isEmpty)
        #expect(model.selectedRange == .init(location: 0, length: 0))
        #expect(model.markedRange == nil)
    }
}
