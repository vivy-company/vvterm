//
//  TerminalTitleSequenceParserTests.swift
//  VVTermTests
//

import Foundation
import Testing
@testable import VVTerm

struct TerminalTitleSequenceParserTests {
    @Test
    func parsesBellTerminatedWindowTitle() {
        var parser = TerminalTitleSequenceParser()

        #expect(parser.parse(data("\u{1B}]2;vim\u{7}")) == ["vim"])
    }

    @Test
    func parsesStringTerminatedWindowTitle() {
        var parser = TerminalTitleSequenceParser()

        #expect(parser.parse(data("\u{1B}]0;zsh\u{1B}\\")) == ["zsh"])
    }

    @Test
    func buffersSplitTitleSequence() {
        var parser = TerminalTitleSequenceParser()

        #expect(parser.parse(data("\u{1B}]2;vi")).isEmpty)
        #expect(parser.parse(data("m\u{7}")) == ["vim"])
    }

    @Test
    func parsesTitleBeforeLargeBulkOutput() {
        var parser = TerminalTitleSequenceParser()
        let redraw = String(repeating: "x", count: 5000)

        #expect(parser.parse(data("\u{1B}]2;top\u{7}\(redraw)")) == ["top"])
    }

    @Test
    func usesIconTitleAsFallback() {
        var parser = TerminalTitleSequenceParser()

        let titles = parser.parse(data("\u{1B}]1;icon\u{7}\u{1B}]9;ignored\u{7}"))

        #expect(titles == ["icon"])
    }

    @Test
    func prefersWindowTitleWhenIconAndWindowTitlesAreEmittedTogether() {
        var parser = TerminalTitleSequenceParser()

        let titles = parser.parse(data("\u{1B}]1;icon\u{7}\u{1B}]2;window\u{7}"))

        #expect(titles == ["icon", "window"])
    }

    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }
}
