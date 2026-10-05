#if os(macOS)
import AppKit

extension TerminalFontCatalog {
    @MainActor
    static func live(
        appOwnedFamilies: [TerminalFontFamily]
    ) -> TerminalFontCatalog {
        let bundledFamilies = Set(TerminalDefaults.bundledFontFamilyNames)
        let familyNames = Set(NSFontManager.shared.availableFontFamilies)

        // Mac-installed fonts belong to System, regardless of their file path.
        // Only VVTerm's imported records add Custom families during the merge.
        let families = familyNames.map { familyName in
            TerminalFontFamily(
                name: familyName,
                source: bundledFamilies.contains(familyName) ? .builtIn : .system
            )
        }

        return TerminalFontCatalog(families: families + appOwnedFamilies)
    }
}
#endif
