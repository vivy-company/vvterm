//
//  SFSymbolPickerView.swift
//  VivyTerm
//
//  SF Symbol picker with full system symbols from CoreGlyphs bundle
//

import SwiftUI
import Combine

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Cross-platform color helpers
private extension Color {
    static var systemBackground: Color {
        #if os(macOS)
        Color(NSColor.windowBackgroundColor)
        #else
        Color(UIColor.systemBackground)
        #endif
    }

    static var controlBackground: Color {
        #if os(macOS)
        Color(NSColor.controlBackgroundColor)
        #else
        Color(UIColor.secondarySystemBackground)
        #endif
    }
}

// MARK: - SFSymbolsProvider

class SFSymbolsProvider {
    static let shared = SFSymbolsProvider()

    private(set) var allSymbols: [String] = []
    private(set) var categories: [(key: String, icon: String, name: String)] = []
    private(set) var symbolToCategories: [String: [String]] = [:]

    private let localizedSuffixes = [".ar", ".hi", ".he", ".ja", ".ko", ".th", ".zh", ".rtl"]

    private init() {
        loadSymbols()
    }

    private func loadSymbols() {
        guard let bundle = Bundle(path: "/System/Library/CoreServices/CoreGlyphs.bundle") else {
            loadFallbackSymbols()
            return
        }

        // Load categories
        if let categoriesPath = bundle.path(forResource: "categories", ofType: "plist"),
           let categoriesData = FileManager.default.contents(atPath: categoriesPath),
           let categoriesList = try? PropertyListSerialization.propertyList(from: categoriesData, format: nil) as? [[String: String]] {
            categories = categoriesList.compactMap { dict in
                guard let key = dict["key"], let icon = dict["icon"] else { return nil }
                return (key: key, icon: icon, name: displayName(for: key))
            }
        }

        // Load symbol_categories (this has all symbol names as keys)
        if let symbolCategoriesPath = bundle.path(forResource: "symbol_categories", ofType: "plist"),
           let symbolCategoriesData = FileManager.default.contents(atPath: symbolCategoriesPath),
           let symbolCategoriesDict = try? PropertyListSerialization.propertyList(from: symbolCategoriesData, format: nil) as? [String: [String]] {
            symbolToCategories = symbolCategoriesDict

            // Filter out localized variants and collect all unique symbols
            allSymbols = symbolCategoriesDict.keys
                .filter { symbol in
                    !localizedSuffixes.contains { symbol.hasSuffix($0) }
                }
                .sorted()
        }
    }

    private func loadFallbackSymbols() {
        allSymbols = [
            "brain.head.profile", "cpu", "terminal", "command", "gearshape",
            "bolt", "star", "sparkle", "wand.and.stars", "lightbulb",
            "flame", "cloud", "server.rack", "desktopcomputer", "laptopcomputer",
            "iphone", "atom", "swift", "curlybraces",
            "text.bubble", "message", "envelope", "paperplane", "arrow.up.circle",
            "checkmark.circle", "xmark.circle", "exclamationmark.triangle", "questionmark.circle",
            "person", "person.2", "person.3", "folder", "doc.text"
        ]
        categories = [
            (key: "all", icon: "square.grid.2x2", name: String(localized: "All"))
        ]
    }

    private func displayName(for key: String) -> String {
        switch key {
        case "all": return String(localized: "All")
        case "whatsnew": return String(localized: "What's New")
        case "draw": return String(localized: "Draw")
        case "variable": return String(localized: "Variable")
        case "multicolor": return String(localized: "Multicolor")
        case "communication": return String(localized: "Communication")
        case "weather": return String(localized: "Weather")
        case "maps": return String(localized: "Maps")
        case "objectsandtools": return String(localized: "Objects & Tools")
        case "devices": return String(localized: "Devices")
        case "cameraandphotos": return String(localized: "Camera & Photos")
        case "gaming": return String(localized: "Gaming")
        case "connectivity": return String(localized: "Connectivity")
        case "transportation": return String(localized: "Transportation")
        case "automotive": return String(localized: "Automotive")
        case "accessibility": return String(localized: "Accessibility")
        case "privacyandsecurity": return String(localized: "Privacy & Security")
        case "human": return String(localized: "Human")
        case "home": return String(localized: "Home")
        case "fitness": return String(localized: "Fitness")
        case "nature": return String(localized: "Nature")
        case "editing": return String(localized: "Editing")
        case "textformatting": return String(localized: "Text Formatting")
        case "media": return String(localized: "Media")
        case "keyboard": return String(localized: "Keyboard")
        case "commerce": return String(localized: "Commerce")
        case "time": return String(localized: "Time")
        case "health": return String(localized: "Health")
        case "shapes": return String(localized: "Shapes")
        case "arrows": return String(localized: "Arrows")
        case "indices": return String(localized: "Indices")
        case "math": return String(localized: "Math")
        default: return key.capitalized
        }
    }

    func symbols(for category: String) -> [String] {
        if category == "all" {
            return allSymbols
        }

        return allSymbols.filter { symbol in
            symbolToCategories[symbol]?.contains(category) ?? false
        }
    }

    func search(_ query: String) -> [String] {
        let lowercasedQuery = query.lowercased()
        let queryWords = lowercasedQuery.split(separator: " ").map(String.init)

        return allSymbols.filter { symbol in
            let symbolLower = symbol.lowercased()
            // Match all query words against symbol name
            return queryWords.allSatisfy { word in
                symbolLower.contains(word)
            }
        }
    }
}

// MARK: - Recent Symbols Manager

class RecentSymbolsManager: ObservableObject {
    static let shared = RecentSymbolsManager()

    private let key = "recentSFSymbols"
    private let maxRecent = 24

    @Published private(set) var recentSymbols: [String] = []

    private init() {
        loadRecent()
    }

    private func loadRecent() {
        recentSymbols = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func addRecent(_ symbol: String) {
        var recent = recentSymbols
        recent.removeAll { $0 == symbol }
        recent.insert(symbol, at: 0)
        if recent.count > maxRecent {
            recent = Array(recent.prefix(maxRecent))
        }
        recentSymbols = recent
        UserDefaults.standard.set(recent, forKey: key)
    }
}

// MARK: - SFSymbolPickerView

struct SFSymbolPickerView: View {
    @Binding var selectedSymbol: String
    @Binding var isPresented: Bool

    @State private var searchText = ""
    @State private var selectedCategory = "all"
    @State private var displayLimit = 200
    @StateObject private var recentManager = RecentSymbolsManager.shared

    private let provider = SFSymbolsProvider.shared
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)
    private let pageSize = 200

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            categoryTabsView
            Divider()
            symbolGridView
        }
        .frame(width: 540, height: 480)
        .background(Color.systemBackground)
        .onChange(of: searchText) { _ in
            displayLimit = pageSize
        }
        .onChange(of: selectedCategory) { _ in
            displayLimit = pageSize
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search symbols...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.controlBackground)
            .cornerRadius(8)

            Button("Done") {
                isPresented = false
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
    }

    // MARK: - Category Tabs

    private var categoryTabsView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if !recentManager.recentSymbols.isEmpty && searchText.isEmpty {
                    categoryTab(key: "recent", icon: "clock", name: String(localized: "Recent"))
                }

                ForEach(provider.categories, id: \.key) { category in
                    categoryTab(key: category.key, icon: category.icon, name: category.name)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.controlBackground.opacity(0.5))
    }

    private func categoryTab(key: String, icon: String, name: String) -> some View {
        Button {
            selectedCategory = key
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(name)
                    .font(.system(size: 11, weight: selectedCategory == key ? .semibold : .regular))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                selectedCategory == key ?
                Color.accentColor.opacity(0.15) :
                Color.clear
            )
            .foregroundColor(selectedCategory == key ? .accentColor : .secondary)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Symbol Grid

    private var allFilteredSymbols: [String] {
        if !searchText.isEmpty {
            return provider.search(searchText)
        }
        if selectedCategory == "recent" {
            return recentManager.recentSymbols
        }
        return provider.symbols(for: selectedCategory)
    }

    private var displayedSymbols: [String] {
        Array(allFilteredSymbols.prefix(displayLimit))
    }

    private var hasMore: Bool {
        allFilteredSymbols.count > displayLimit
    }

    private var symbolGridView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Count label
                HStack {
                    Text("\(allFilteredSymbols.count) symbols")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

                // Grid
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(displayedSymbols, id: \.self) { symbol in
                        symbolButton(symbol)
                    }
                }
                .padding(.horizontal, 12)

                // Load more button
                if hasMore {
                    Button {
                        displayLimit += pageSize
                    } label: {
                        Text("Load more (\(allFilteredSymbols.count - displayLimit) remaining)")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 12)
        }
        .background(Color.controlBackground)
    }

    private func symbolButton(_ symbol: String) -> some View {
        Button {
            selectedSymbol = symbol
            recentManager.addRecent(symbol)
            isPresented = false
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .frame(width: 56, height: 56)
                .foregroundColor(selectedSymbol == symbol ? .white : .primary)
                .background(
                    selectedSymbol == symbol ?
                    Color.accentColor :
                    Color.systemBackground
                )
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .help(symbol)
    }
}
