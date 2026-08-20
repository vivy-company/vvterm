import XCTest
@testable import VVTerm

@MainActor
final class ServerVolumeVisibilityTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ServerVolumeVisibilityTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testStoreLoadsAndSavesOnlyThroughInjectedPersistence() {
        let serverID = UUID()
        let data = makeVolume(mountPoint: "/data", stableIdentifier: "data")
        var initial = ServerVolumeVisibilityPreferences()
        initial.setVisibilityOverrides([data.identity: false], for: serverID)
        let persistence = ServerVolumeVisibilityPersistenceSpy(initial: initial)
        let store = ServerVolumeVisibilityStore(persistence: persistence)

        XCTAssertEqual(store.preferences, initial)

        store.setVolume(data, isVisible: true, for: serverID)

        XCTAssertEqual(persistence.savedPreferences, [store.preferences])
    }

    func testDefaultsHideContainersAndPreferencesAreIsolatedPerServer() {
        let firstServer = UUID()
        let secondServer = UUID()
        let data = makeVolume(mountPoint: "/data", stableIdentifier: "data-uuid")
        let container = makeVolume(
            mountPoint: "/var/lib/docker/overlay2/one/merged",
            source: "overlay",
            fileSystem: "overlay"
        )
        let volumes = [data, container]
        let store = makeStore()

        XCTAssertEqual(
            store.hiddenVolumeIDs(for: firstServer, volumes: volumes),
            [container.identity]
        )
        XCTAssertTrue(store.preferences.visibilityOverrides(for: firstServer).isEmpty)

        store.setVolume(data, isVisible: false, for: firstServer)

        XCTAssertEqual(
            store.hiddenVolumeIDs(for: firstServer, volumes: volumes),
            [data.identity, container.identity]
        )
        XCTAssertEqual(
            store.hiddenVolumeIDs(for: secondServer, volumes: volumes),
            [container.identity]
        )
        XCTAssertEqual(store.preferences.visibilityOverrides(for: firstServer), [data.identity: false])
        XCTAssertTrue(store.preferences.visibilityOverrides(for: secondServer).isEmpty)
    }

    func testExplicitlyShownContainerSurvivesRelaunchAndTemporaryDisappearance() {
        let serverID = UUID()
        let container = makeVolume(
            mountPoint: "/var/lib/docker/overlay2/one/merged",
            source: "overlay",
            fileSystem: "overlay",
            stableIdentifier: "container-uuid"
        )
        var store: ServerVolumeVisibilityStore? = makeStore()
        XCTAssertEqual(
            store?.hiddenVolumeIDs(for: serverID, volumes: [container]),
            [container.identity]
        )

        store?.setVolume(container, isVisible: true, for: serverID)
        XCTAssertEqual(
            store?.preferences.visibilityOverrides(for: serverID),
            [container.identity: true]
        )

        store = makeStore()

        XCTAssertTrue(store?.hiddenVolumeIDs(for: serverID, volumes: []).isEmpty == true)
        XCTAssertTrue(store?.hiddenVolumeIDs(for: serverID, volumes: [container]).isEmpty == true)
        XCTAssertEqual(
            store?.preferences.visibilityOverrides(for: serverID),
            [container.identity: true]
        )
    }

    func testReformattedOrReplacedVolumeDoesNotInheritHiddenIdentity() {
        let original = makeVolume(mountPoint: "/data", stableIdentifier: "old-uuid")
        let replacement = makeVolume(mountPoint: "/data", stableIdentifier: "new-uuid")

        XCTAssertNotEqual(original.identity, replacement.identity)
        XCTAssertEqual(
            VolumeVisibilityPolicy.visibleVolumes(
                from: [replacement],
                hiddenVolumeIDs: [original.identity]
            ),
            [replacement]
        )
    }

    func testStableFilesystemIdentitySurvivesCapacityChangesAtSameMount() {
        let before = VolumeInfo(
            platform: .linux,
            mountPoint: "/data",
            source: "/dev/sda1",
            fileSystem: "ext4",
            stableIdentifier: "DATA-UUID",
            used: 400,
            total: 1_000
        )
        let afterResize = VolumeInfo(
            platform: .linux,
            mountPoint: "/data",
            source: "/dev/mapper/data",
            fileSystem: "ext4",
            stableIdentifier: "data-uuid",
            used: 500,
            total: 2_000
        )

        XCTAssertEqual(before.identity, afterResize.identity)
    }

    func testFallbackIdentitySurvivesCapacityChangesAtSameMount() {
        let before = makeVolume(mountPoint: "/data", stableIdentifier: nil)
        let afterResize = VolumeInfo(
            platform: .linux,
            mountPoint: "/data",
            source: "/dev/disk0",
            fileSystem: "ext4",
            used: 600,
            total: 2_000
        )

        XCTAssertEqual(before.identity, afterResize.identity)
    }

    func testWindowsMountIdentityIsCaseAndSlashInsensitive() {
        let first = VolumeInfo(
            platform: .windows,
            mountPoint: "c:/",
            source: "c:/",
            fileSystem: "NTFS",
            stableIdentifier: "volume-1",
            used: 1,
            total: 2
        )
        let second = VolumeInfo(
            platform: .windows,
            mountPoint: "C:\\",
            source: "C:\\",
            fileSystem: "ntfs",
            stableIdentifier: "VOLUME-1",
            used: 1,
            total: 2
        )

        XCTAssertEqual(first.identity, second.identity)
    }

    func testNormalizationRemovesDuplicateMountRowsWithoutChangingFirstSeenOrder() {
        let root = makeVolume(mountPoint: "/", stableIdentifier: "root")
        let data = makeVolume(mountPoint: "/data", stableIdentifier: "data")
        let duplicateRoot = makeVolume(mountPoint: "/", stableIdentifier: nil)

        XCTAssertEqual(
            VolumeVisibilityPolicy.normalized([root, data, duplicateRoot]),
            [root, data]
        )
    }

    func testBulkVisibilityStoresOnlyDeviationsAndPreservesMissingVolumeOverrides() {
        let serverID = UUID()
        let missing = makeVolume(mountPoint: "/offline", stableIdentifier: "offline")
        let data = makeVolume(mountPoint: "/data", stableIdentifier: "data")
        let firstContainer = makeVolume(
            mountPoint: "/var/lib/docker/overlay2/one/merged",
            source: "overlay",
            fileSystem: "overlay"
        )
        let secondContainer = makeVolume(
            mountPoint: "/var/lib/docker/overlay2/two/merged",
            source: "overlay",
            fileSystem: "overlay"
        )
        let currentVolumes = [data, firstContainer, secondContainer]
        let store = makeStore()
        store.setVolume(missing, isVisible: false, for: serverID)

        store.setVolumes(currentVolumes, areVisible: true, for: serverID)
        XCTAssertEqual(
            store.preferences.visibilityOverrides(for: serverID),
            [
                missing.identity: false,
                firstContainer.identity: true,
                secondContainer.identity: true
            ]
        )
        XCTAssertTrue(store.hiddenVolumeIDs(for: serverID, volumes: currentVolumes).isEmpty)

        store.setVolumes(currentVolumes, areVisible: false, for: serverID)
        XCTAssertEqual(
            store.preferences.visibilityOverrides(for: serverID),
            [missing.identity: false, data.identity: false]
        )
        XCTAssertEqual(
            store.hiddenVolumeIDs(for: serverID, volumes: currentVolumes),
            Set(currentVolumes.map(\.identity))
        )
    }

    func testSchemaOneHiddenIDsMigrateWithoutLosingNonContainerChoice() throws {
        let serverID = UUID()
        let data = makeVolume(mountPoint: "/data", stableIdentifier: "data")
        let container = makeVolume(
            mountPoint: "/var/lib/docker/overlay2/one/merged",
            source: "overlay",
            fileSystem: "overlay",
            stableIdentifier: "container"
        )
        let legacyPreferences = LegacyServerVolumeVisibilityPreferences(
            hiddenVolumeIDsByServer: [
                serverID.uuidString: [data.identity, container.identity]
            ]
        )
        defaults.set(
            try JSONEncoder().encode(legacyPreferences),
            forKey: UserDefaultsServerVolumeVisibilityPersistence.storageKey
        )

        let store = makeStore()

        XCTAssertEqual(
            store.hiddenVolumeIDs(for: serverID, volumes: [data, container]),
            [data.identity, container.identity]
        )
        XCTAssertEqual(
            store.preferences.visibilityOverrides(for: serverID),
            [data.identity: false, container.identity: false]
        )
        XCTAssertFalse(store.preferences.requiresSchemaMigration)

        let migratedData = try XCTUnwrap(
            defaults.data(forKey: UserDefaultsServerVolumeVisibilityPersistence.storageKey)
        )
        let migratedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: migratedData) as? [String: Any]
        )
        XCTAssertEqual(migratedObject["schemaVersion"] as? Int, 2)
        XCTAssertNil(migratedObject["hiddenVolumeIDsByServer"])
        XCTAssertNotNil(migratedObject["visibilityOverridesByServer"])

        store.setVolume(container, isVisible: false, for: serverID)
        XCTAssertEqual(
            store.preferences.visibilityOverrides(for: serverID),
            [data.identity: false]
        )
    }

    func testMalformedPersistedPreferencesMigrateToDefaultVisibility() {
        let malformedData = Data("not-json".utf8)
        defaults.set(
            malformedData,
            forKey: UserDefaultsServerVolumeVisibilityPersistence.storageKey
        )
        let data = makeVolume(mountPoint: "/data")
        let container = makeVolume(
            mountPoint: "/var/lib/docker/overlay2/one/merged",
            source: "overlay",
            fileSystem: "overlay"
        )

        let store = makeStore()

        XCTAssertEqual(
            store.hiddenVolumeIDs(for: UUID(), volumes: [data, container]),
            [container.identity]
        )
        XCTAssertEqual(
            defaults.data(forKey: UserDefaultsServerVolumeVisibilityPersistence.storageKey),
            malformedData
        )
    }

    func testUnsupportedFutureSchemaFailsSafeWithoutOverwritingIt() throws {
        let futureData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 99,
            "visibilityOverridesByServer": [:]
        ])
        defaults.set(
            futureData,
            forKey: UserDefaultsServerVolumeVisibilityPersistence.storageKey
        )
        let data = makeVolume(mountPoint: "/data")
        let container = makeVolume(
            mountPoint: "/var/lib/docker/overlay2/one/merged",
            source: "overlay",
            fileSystem: "overlay"
        )

        let store = makeStore()

        XCTAssertEqual(
            store.hiddenVolumeIDs(for: UUID(), volumes: [data, container]),
            [container.identity]
        )

        let serverID = UUID()
        store.setVolume(data, isVisible: false, for: serverID)

        XCTAssertEqual(
            store.hiddenVolumeIDs(for: serverID, volumes: [data, container]),
            [data.identity, container.identity]
        )
        XCTAssertEqual(store.preferences.visibilityOverrides(for: serverID), [data.identity: false])
        XCTAssertEqual(
            defaults.data(forKey: UserDefaultsServerVolumeVisibilityPersistence.storageKey),
            futureData
        )
    }

    func testVolumeKindClassifiesContainerAndNetworkMounts() {
        XCTAssertEqual(
            VolumeKind.classify(source: "overlay", mountPoint: "/var/lib/docker/overlay2/x", fileSystem: "overlay"),
            .container
        )
        XCTAssertEqual(
            VolumeKind.classify(source: "nas:/exports/media", mountPoint: "/media", fileSystem: "nfs4"),
            .network
        )
    }

    func testOverlayRootDefaultsVisibleAndRemainsEligibleForIndividualControl() {
        let serverID = UUID()
        let root = makeVolume(
            mountPoint: "/",
            source: "overlay",
            fileSystem: "overlay"
        )
        let docker = makeVolume(
            mountPoint: "/var/lib/docker/overlay2/x/merged",
            source: "overlay",
            fileSystem: "overlay"
        )
        let store = makeStore()

        XCTAssertEqual(VolumeVisibilityPolicy.containerVolumeIDs(in: [root, docker]), [docker.identity])
        XCTAssertEqual(
            store.hiddenVolumeIDs(for: serverID, volumes: [root, docker]),
            [docker.identity]
        )

        store.setVolume(root, isVisible: false, for: serverID)

        XCTAssertEqual(
            store.hiddenVolumeIDs(for: serverID, volumes: [root, docker]),
            [root.identity, docker.identity]
        )
        XCTAssertEqual(store.preferences.visibilityOverrides(for: serverID), [root.identity: false])
    }

    private func makeVolume(
        mountPoint: String,
        source: String = "/dev/disk0",
        fileSystem: String = "ext4",
        stableIdentifier: String? = nil
    ) -> VolumeInfo {
        VolumeInfo(
            platform: .linux,
            mountPoint: mountPoint,
            source: source,
            fileSystem: fileSystem,
            stableIdentifier: stableIdentifier,
            used: 400,
            total: 1_000
        )
    }

    private func makeStore() -> ServerVolumeVisibilityStore {
        ServerVolumeVisibilityStore(
            persistence: UserDefaultsServerVolumeVisibilityPersistence(defaults: defaults)
        )
    }
}

@MainActor
private final class ServerVolumeVisibilityPersistenceSpy:
    ServerVolumeVisibilityPreferencesPersisting {
    private let initial: ServerVolumeVisibilityPreferences
    private(set) var savedPreferences: [ServerVolumeVisibilityPreferences] = []

    init(initial: ServerVolumeVisibilityPreferences) {
        self.initial = initial
    }

    func loadPreferences() -> ServerVolumeVisibilityPreferences {
        initial
    }

    func savePreferences(_ preferences: ServerVolumeVisibilityPreferences) {
        savedPreferences.append(preferences)
    }
}

private struct LegacyServerVolumeVisibilityPreferences: Encodable {
    let schemaVersion = 1
    let hiddenVolumeIDsByServer: [String: Set<VolumeIdentity>]
}
