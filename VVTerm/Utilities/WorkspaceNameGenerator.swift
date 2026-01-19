//
//  WorkspaceNameGenerator.swift
//  aizen
//
//  Created by Uladzislau Yakauleu on 17.10.25.
//

import Foundation

struct WorkspaceNameGenerator {
    private static let japaneseCities = [
        "Tokyo", "Kyoto", "Osaka", "Yokohama", "Nagoya", "Sapporo",
        "Fukuoka", "Kobe", "Hiroshima", "Sendai", "Nara", "Kamakura",
        "Shibuya", "Akihabara", "Harajuku", "Shinjuku", "Ginza"
    ]

    private static let chineseCities = [
        "Beijing", "Shanghai", "Hangzhou", "Suzhou", "Chengdu", "Chongqing",
        "Guangzhou", "Shenzhen", "Xi'an", "Nanjing", "Wuhan", "Kunming",
        "Guilin", "Dalian", "Tianjin", "Qingdao"
    ]

    private static let animeNames = [
        "Konoha", "Amestris", "Magnolia", "Musutafu", "Namimori",
        "Karakura", "Ikebukuro", "Shiganshina", "Mitakihara", "Morioh",
        "Hinamizawa", "Orario", "Academy City", "Kuoh", "Yukihira",
        "Aincrad", "Paradis", "Konohagakure", "Sunagakure", "Kirigakure"
    ]

    private static let fictionalPlaces = [
        "Mondstadt", "Liyue", "Inazuma", "Sumeru", "Fontaine",
        "Midgar", "Zanarkand", "Radiant Garden", "Twilight Town",
        "Traverse Town", "Hollow Bastion", "Shibusen", "Death City"
    ]

    private static let chiikawaCharacters = [
        "Chiikawa", "Hachiware", "Usagi", "Momonga", "Kurimanju",
        "Ramen", "Pajama", "Armor", "Shisa", "Rakko",
        "Kani", "Chikuwa", "Kuri", "Momo", "Anko"
    ]

    private static let allNames: [String] = japaneseCities + chineseCities + animeNames + fictionalPlaces + chiikawaCharacters

    static func generateUniqueName(excluding existingNames: [String]) -> String {
        // Filter out already used names
        let available = allNames.filter { !existingNames.contains($0) }

        // If we have available names, pick random
        if !available.isEmpty {
            return available.randomElement() ?? "Workspace-\(Date().timeIntervalSince1970)"
        }

        // If all names are used, fall back to numbered format
        var counter = 1
        while true {
            let name = "Workspace-\(counter)"
            if !existingNames.contains(name) {
                return name
            }
            counter += 1
        }
    }

    static func getRandomName() -> String {
        return allNames.randomElement() ?? "Tokyo"
    }
}
