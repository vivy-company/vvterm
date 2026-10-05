#if os(macOS)
import AppKit
import CoreText
import Testing
@testable import VVTerm

@MainActor
struct TerminalFontCatalogMacOSTests {
    @Test
    func bundledFontsAreActivatedAtAppLaunch() throws {
        let fontPath = try #require(Bundle.main.object(forInfoDictionaryKey: "ATSApplicationFontsPath") as? String)
        let resources = try #require(Bundle.main.resourceURL)
        let fontDirectory = resources.appendingPathComponent(fontPath, isDirectory: true)
        let fontURLs = try FileManager.default.contentsOfDirectory(
            at: fontDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "ttf" }
        let bundledFamilies = Set(fontURLs.flatMap { url in
            (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []).compactMap {
                CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String
            }
        })
        let availableFamilies = Set(try #require(CTFontManagerCopyAvailableFontFamilyNames() as? [String]))
        let catalog = TerminalFontCatalog.live(appOwnedFamilies: [])

        for family in TerminalDefaults.bundledFontFamilyNames {
            #expect(bundledFamilies.contains(family), "Missing bundled font: \(family)")
            #expect(availableFamilies.contains(family), "Inactive bundled font: \(family)")
            #expect(catalog.family(named: family)?.source == .builtIn)
            let font = CTFontCreateWithName(family as CFString, 15, nil)
            #expect(CTFontCopyFamilyName(font) as String == family,
                    "CoreText substituted another font for \(family)")
        }
    }

    @Test
    func installedFontsAreSystemUnlessBundledWithVVTerm() {
        let catalog = TerminalFontCatalog.live(appOwnedFamilies: [])
        let bundled = Set(TerminalDefaults.bundledFontFamilyNames)

        for family in catalog.families {
            #expect(family.source == (bundled.contains(family.name) ? .builtIn : .system),
                    "Unexpected source for \(family.name)")
        }
        #expect(Set(NSFontManager.shared.availableFontFamilies).isSubset(of: Set(catalog.families.map(\.name))))
    }

    @Test
    func onlyImportedFamiliesAppearInCustomGroup() throws {
        let installedName = try #require(NSFontManager.shared.availableFontFamilies.first {
            !TerminalDefaults.bundledFontFamilyNames.contains($0)
        })
        let imports = [
            TerminalFontFamily(name: installedName, source: .custom),
            TerminalFontFamily(name: "VVTerm Imported Test Family", source: .custom)
        ]
        let catalog = TerminalFontCatalog.live(appOwnedFamilies: imports)

        #expect(Set(catalog.families.filter { $0.source == .custom }.map(\.name)) == Set(imports.map(\.name)))
        #expect(catalog.families.filter { $0.name == installedName }.count == 1)
    }
}
#endif
