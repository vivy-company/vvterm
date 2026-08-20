import XCTest
@testable import VVTerm

final class WorkspaceNameGeneratorTests: XCTestCase {
    func testGenerateUniqueNameAvoidsExistingNames() {
        let existing = ["Tokyo", "Kyoto", "Osaka", "Workspace-1"]

        let generated = WorkspaceNameGenerator.generateUniqueName(excluding: existing)

        XCTAssertFalse(existing.contains(generated))
    }

    func testGenerateUniqueNameFallsBackToSequentialWorkspaceNames() {
        let existing = [
            "Tokyo", "Kyoto", "Osaka", "Yokohama", "Nagoya", "Sapporo",
            "Fukuoka", "Kobe", "Hiroshima", "Sendai", "Nara", "Kamakura",
            "Shibuya", "Akihabara", "Harajuku", "Shinjuku", "Ginza",
            "Beijing", "Shanghai", "Hangzhou", "Suzhou", "Chengdu", "Chongqing",
            "Guangzhou", "Shenzhen", "Xi'an", "Nanjing", "Wuhan", "Kunming",
            "Guilin", "Dalian", "Tianjin", "Qingdao", "Konoha", "Amestris",
            "Magnolia", "Musutafu", "Namimori", "Karakura", "Ikebukuro", "Shiganshina",
            "Mitakihara", "Morioh", "Hinamizawa", "Orario", "Academy City", "Kuoh",
            "Yukihira", "Aincrad", "Paradis", "Konohagakure", "Sunagakure", "Kirigakure",
            "Mondstadt", "Liyue", "Inazuma", "Sumeru", "Fontaine", "Midgar",
            "Zanarkand", "Radiant Garden", "Twilight Town", "Traverse Town", "Hollow Bastion",
            "Shibusen", "Death City", "Chiikawa", "Hachiware", "Usagi", "Momonga",
            "Kurimanju", "Ramen", "Pajama", "Armor", "Shisa", "Rakko",
            "Kani", "Chikuwa", "Kuri", "Momo", "Anko", "Workspace-1"
        ]

        XCTAssertEqual(WorkspaceNameGenerator.generateUniqueName(excluding: existing), "Workspace-2")
    }
}
