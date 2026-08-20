import XCTest
@testable import VVTerm

final class StorageHealthTargetResolverTests: XCTestCase {
    private let deviceID = StorageDeviceIdentity(namespace: "test", opaqueValue: "device-1")

    func testNonPhysicalVolumesShortCircuitBeforeRemoteResolution() {
        let network = volume(source: "host:/share", fileSystem: "nfs")
        let virtual = volume(source: "tmpfs", fileSystem: "tmpfs")
        let container = volume(source: "overlay", fileSystem: "overlay")
        let physical = volume(source: "/dev/sda1", fileSystem: "ext4")

        XCTAssertEqual(StorageHealthTargetResolver.unavailableReason(for: network), .networkVolume)
        XCTAssertEqual(StorageHealthTargetResolver.unavailableReason(for: virtual), .virtualDevice)
        XCTAssertEqual(StorageHealthTargetResolver.unavailableReason(for: container), .virtualDevice)
        XCTAssertNil(StorageHealthTargetResolver.unavailableReason(for: physical))
    }

    func testLinuxResolutionFindsExactlyOneAncestorDiskAndDetectsEMMC() {
        let output = marked(#"""
        {
          "blockdevices": [
            {
              "path": "/dev/mapper/vg-root",
              "type": "lvm",
              "children": [
                {
                  "path": "/dev/mmcblk0p2",
                  "type": "part",
                  "children": [{"path": "/dev/mmcblk0", "type": "disk"}]
                }
              ]
            }
          ]
        }
        """#)

        XCTAssertEqual(
            StorageHealthTargetResolver.parseLinuxResolution(
                output,
                fallbackSource: "/dev/mapper/vg-root",
                deviceID: deviceID
            ),
            singleTarget(.linux(devicePath: "/dev/mmcblk0", isEMMC: true))
        )
    }

    func testLinuxResolutionRejectsMultiDeviceAndMalformedMappings() {
        let multiple = marked(#"""
        {"blockdevices":[
          {"path":"/dev/sda","type":"disk"},
          {"path":"/dev/sdb","type":"disk"}
        ]}
        """#)

        XCTAssertEqual(
            StorageHealthTargetResolver.parseLinuxResolution(
                multiple,
                fallbackSource: "/dev/md0",
                deviceID: deviceID
            ),
            .unavailable(.unmapped)
        )
        XCTAssertEqual(
            StorageHealthTargetResolver.parseLinuxResolution(
                marked("not json"),
                fallbackSource: "/dev/sda1",
                deviceID: deviceID
            ),
            .unavailable(.invalidResponse)
        )
    }

    func testLinuxResolutionRejectsDegradedRAIDEvenWithOneVisibleAncestorDisk() {
        let degradedRAID = marked(#"""
        {"blockdevices":[
          {
            "path":"/dev/md0",
            "type":"raid1",
            "children":[{"path":"/dev/sda","type":"disk"}]
          }
        ]}
        """#)

        XCTAssertEqual(
            StorageHealthTargetResolver.parseLinuxResolution(
                degradedRAID,
                fallbackSource: "/dev/md0",
                deviceID: deviceID
            ),
            .unavailable(.unmapped)
        )
    }

    func testLinuxToolMissingFallbackOnlyAcceptsRecognizedWholeDevices() {
        XCTAssertEqual(
            StorageHealthTargetResolver.parseLinuxResolution(
                StorageHealthTargetResolver.resolutionToolMissingMarker,
                fallbackSource: "/dev/nvme2n3",
                deviceID: deviceID
            ),
            singleTarget(.linux(devicePath: "/dev/nvme2n3", isEMMC: false))
        )
        XCTAssertEqual(
            StorageHealthTargetResolver.parseLinuxResolution(
                StorageHealthTargetResolver.resolutionToolMissingMarker,
                fallbackSource: "/dev/nvme2n3p1",
                deviceID: deviceID
            ),
            .unavailable(.toolMissing)
        )
    }

    func testLinuxResolutionCommandIsQuotedBoundedAndReadOnly() throws {
        let command = try XCTUnwrap(StorageHealthTargetResolver.linuxResolutionCommand(
            source: "/dev/disk/by-label/user's disk",
            mountPoint: "/srv/user's files"
        ))

        XCTAssertTrue(command.contains("findmnt -n -o SOURCE -T"))
        XCTAssertTrue(command.contains("lsblk -s -J -p -o PATH,TYPE"))
        XCTAssertTrue(command.contains("user"))
        XCTAssertFalse(command.contains("user's disk"))
        assertReadOnly(command)
        XCTAssertNil(StorageHealthTargetResolver.linuxResolutionCommand(
            source: "/dev/sda\nrm -rf /",
            mountPoint: "/"
        ))
    }

    func testBTRFSMirrorDiscoversEveryMemberAndDeviceErrors() throws {
        let filesystem = """
        Label: 'data'  uuid: 1234
                Total devices 2 FS bytes used 4096
                devid    1 size 100000 used 50000 path /dev/sda1
                devid    2 size 100000 used 50000 path /dev/sdb1
        """
        let stats = """
        [/dev/sda1].write_io_errs    0
        [/dev/sda1].read_io_errs     0
        [/dev/sdb1].write_io_errs    2
        [/dev/sdb1].corruption_errs  1
        """

        let discovery = try XCTUnwrap(
            LinuxStorageTopologyParser.parseBTRFS(filesystem: filesystem, deviceStats: stats)
        )

        XCTAssertEqual(discovery.kind, .btrfs)
        XCTAssertEqual(discovery.name, "data")
        XCTAssertEqual(discovery.members.map(\.path), ["/dev/sda1", "/dev/sdb1"])
        XCTAssertTrue(discovery.members[1].findings.contains {
            $0.kind == .deviceErrors(read: 0, write: 2, checksum: 1)
        })
    }

    func testBTRFSSingleAndFourDeviceFixturesPreserveEveryMember() throws {
        let single = try XCTUnwrap(LinuxStorageTopologyParser.parseBTRFS(
            filesystem: """
            Label: none  uuid: single
                    Total devices 1 FS bytes used 4096
                    devid    1 size 100000 used 50000 path /dev/sda1
            """,
            deviceStats: ""
        ))
        let multiDevice = try XCTUnwrap(LinuxStorageTopologyParser.parseBTRFS(
            filesystem: """
            Label: 'raid10-data'  uuid: multi
                    Total devices 4 FS bytes used 4096
                    devid    1 size 100000 used 50000 path /dev/sda1
                    devid    2 size 100000 used 50000 path /dev/sdb1
                    devid    3 size 100000 used 50000 path /dev/sdc1
                    devid    4 size 100000 used 50000 path /dev/sdd1
            """,
            deviceStats: ""
        ))

        XCTAssertEqual(single.members.map(\.path), ["/dev/sda1"])
        XCTAssertEqual(
            multiDevice.members.map(\.path),
            ["/dev/sda1", "/dev/sdb1", "/dev/sdc1", "/dev/sdd1"]
        )
        XCTAssertEqual(multiDevice.name, "raid10-data")
    }

    func testBTRFSDegradedFixtureKeepsMissingMemberVisible() throws {
        let filesystem = """
        Label: none  uuid: 1234
                Total devices 2 FS bytes used 4096
                devid    1 size 100000 used 50000 path /dev/sda1
                devid    2 size 100000 used 50000 path missing
        *** Some devices missing
        """

        let discovery = try XCTUnwrap(
            LinuxStorageTopologyParser.parseBTRFS(filesystem: filesystem, deviceStats: "")
        )

        XCTAssertEqual(discovery.members.count, 2)
        XCTAssertNil(discovery.members[1].path)
        XCTAssertTrue(discovery.findings.contains { $0.kind == .missingMember })
    }

    func testZFSRAIDZDiscoversRolesPoolStateAndMemberErrors() throws {
        let status = """
          pool: tank
         state: DEGRADED
        config:

                NAME              STATE     READ WRITE CKSUM
                tank              DEGRADED     0     0     0
                  raidz1-0        DEGRADED     0     0     0
                    /dev/sda      ONLINE       0     0     0
                    /dev/sdb      DEGRADED     1     0     2
                    /dev/sdc      ONLINE       0     0     0
                logs
                  /dev/nvme0n1    ONLINE       0     0     0
                cache
                  /dev/nvme1n1    ONLINE       0     0     0
                spares
                  /dev/sdd        AVAIL

        errors: No known data errors
        """

        let discovery = try XCTUnwrap(LinuxStorageTopologyParser.parseZFSStatus(status))

        XCTAssertEqual(discovery.kind, .zfs)
        XCTAssertEqual(discovery.name, "tank")
        XCTAssertEqual(discovery.members.map(\.role), [.data, .data, .data, .log, .cache, .spare])
        XCTAssertTrue(discovery.findings.contains { $0.kind == .poolState("DEGRADED") })
        XCTAssertTrue(discovery.members[1].findings.contains {
            $0.kind == .deviceErrors(read: 1, write: 0, checksum: 2)
        })
    }

    func testZFSMirrorDiscoversBothLeavesWithoutTreatingGroupAsDevice() throws {
        let status = """
          pool: mirrorpool
         state: ONLINE
        config:

                NAME              STATE     READ WRITE CKSUM
                mirrorpool        ONLINE       0     0     0
                  mirror-0        ONLINE       0     0     0
                    /dev/sda      ONLINE       0     0     0
                    /dev/sdb      ONLINE       0     0     0

        errors: No known data errors
        """

        let discovery = try XCTUnwrap(LinuxStorageTopologyParser.parseZFSStatus(status))

        XCTAssertEqual(discovery.members.map(\.path), ["/dev/sda", "/dev/sdb"])
        XCTAssertEqual(discovery.members.map(\.role), [.data, .data])
        XCTAssertTrue(discovery.findings.isEmpty)
    }

    func testArrayDiscoveryCommandsAreReadOnlyAndQuoted() throws {
        let btrfs = try XCTUnwrap(StorageHealthTargetResolver.btrfsDiscoveryCommand(
            mountPoint: "/mnt/user's mirror"
        ))
        let zfs = try XCTUnwrap(StorageHealthTargetResolver.zfsDiscoveryCommand(
            source: "tank/user's-data",
            mountPoint: "/tank/user's data"
        ))
        let mapping = try XCTUnwrap(StorageHealthTargetResolver.linuxDeviceResolutionCommand(
            devicePath: "/dev/disk/by-id/user's-disk"
        ))

        XCTAssertTrue(btrfs.contains("btrfs filesystem show --raw"))
        XCTAssertTrue(btrfs.contains("btrfs device stats"))
        XCTAssertTrue(zfs.contains("zpool status -P"))
        XCTAssertTrue(mapping.contains("lsblk -s -J"))
        for command in [btrfs, zfs, mapping] { assertReadOnly(command) }
    }

    func testDarwinParserTracksAPFSPhysicalStoresWithoutExposingOtherMetadata() throws {
        let plist: [String: Any] = [
            "DeviceIdentifier": "disk3s1s1",
            "APFSPhysicalStores": [
                ["DeviceIdentifier": "disk0s2", "SerialNumber": "SECRET"]
            ],
            "SerialNumber": "ANOTHER-SECRET"
        ]
        let info = try XCTUnwrap(StorageHealthTargetResolver.parseDarwinDiskInfo(
            marked(try plistString(plist))
        ))

        XCTAssertEqual(info.deviceIdentifier, "disk3s1s1")
        XCTAssertEqual(info.physicalStores, ["disk0s2"])
        XCTAssertNil(info.wholeDiskIdentifier)

        let physicalStoreInfo = try XCTUnwrap(StorageHealthTargetResolver.parseDarwinDiskInfo(
            marked(try plistString([
                "DeviceIdentifier": "disk0s2",
                "ParentWholeDisk": "disk0"
            ]))
        ))
        XCTAssertEqual(physicalStoreInfo.wholeDiskIdentifier, "disk0")
    }

    func testDarwinParserAcceptsOnlyExplicitWholeDiskIdentifiers() throws {
        let whole = try XCTUnwrap(StorageHealthTargetResolver.parseDarwinDiskInfo(
            marked(try plistString([
                "DeviceIdentifier": "/dev/disk12",
                "WholeDisk": true
            ]))
        ))
        let partition = try XCTUnwrap(StorageHealthTargetResolver.parseDarwinDiskInfo(
            marked(try plistString([
                "DeviceIdentifier": "disk12s1",
                "WholeDisk": true
            ]))
        ))

        XCTAssertEqual(whole.wholeDiskIdentifier, "disk12")
        XCTAssertNil(partition.wholeDiskIdentifier)
    }

    func testDarwinParserReturnsVirtualCapabilityOnlyForExplicitVirtualValues() throws {
        let virtual = try XCTUnwrap(StorageHealthTargetResolver.parseDarwinDiskInfo(
            marked(try plistString([
                "DeviceIdentifier": "disk7",
                "WholeDisk": true,
                "VirtualOrPhysical": "Virtual"
            ]))
        ))
        let diskImage = try XCTUnwrap(StorageHealthTargetResolver.parseDarwinDiskInfo(
            marked(try plistString([
                "DeviceIdentifier": "disk8",
                "WholeDisk": true,
                "MediaType": "Disk Image"
            ]))
        ))
        let unknown = try XCTUnwrap(StorageHealthTargetResolver.parseDarwinDiskInfo(
            marked(try plistString([
                "DeviceIdentifier": "disk9",
                "WholeDisk": true,
                "VirtualOrPhysical": "Unknown"
            ]))
        ))

        XCTAssertEqual(StorageHealthTargetResolver.darwinUnavailableReason(for: virtual), .virtualDevice)
        XCTAssertEqual(StorageHealthTargetResolver.darwinUnavailableReason(for: diskImage), .virtualDevice)
        XCTAssertNil(StorageHealthTargetResolver.darwinUnavailableReason(for: unknown))
    }

    func testDarwinResolutionCommandUsesPlistAndIsReadOnly() throws {
        let command = try XCTUnwrap(
            StorageHealthTargetResolver.darwinResolutionCommand(identifier: "/Volumes/User's Data")
        )
        XCTAssertTrue(command.contains("diskutil info -plist"))
        XCTAssertTrue(command.contains("User"))
        XCTAssertFalse(command.contains("User's Data"))
        assertReadOnly(command)
    }

    func testWindowsResolutionParsesOneBoundedDiskNumber() {
        XCTAssertEqual(
            StorageHealthTargetResolver.parseWindowsResolution(
                marked(#"{"DiskNumbers":[7]}"#),
                deviceID: deviceID
            ),
            singleTarget(.windows(diskNumber: 7))
        )
        XCTAssertEqual(
            StorageHealthTargetResolver.parseWindowsResolution(
                marked(#"{"DiskNumbers":[7,8]}"#),
                deviceID: deviceID
            ),
            .unavailable(.unmapped)
        )
        XCTAssertEqual(
            StorageHealthTargetResolver.parseWindowsResolution(
                marked(#"{"DiskNumbers":[4294967296]}"#),
                deviceID: deviceID
            ),
            .unavailable(.unmapped)
        )
        XCTAssertEqual(
            StorageHealthTargetResolver.parseWindowsResolution(
                marked(#"{"DiskNumbers":[true]}"#),
                deviceID: deviceID
            ),
            .unavailable(.unmapped)
        )
    }

    func testWindowsResolutionNormalizesCapabilityErrors() {
        XCTAssertEqual(
            StorageHealthTargetResolver.parseWindowsResolution(
                marked(#"{"ProbeError":"Access denied"}"#),
                deviceID: deviceID
            ),
            .unavailable(.permissionDenied)
        )
        XCTAssertEqual(
            StorageHealthTargetResolver.parseWindowsResolution(
                marked(#"{"ProbeError":"Get-Volume was not found"}"#),
                deviceID: deviceID
            ),
            .unavailable(.toolMissing)
        )
    }

    func testWindowsResolutionScriptUsesNativeReadOnlyPipelineAndEscapesPaths() throws {
        let driveScript = try XCTUnwrap(StorageHealthTargetResolver.windowsResolutionScript(
            source: "C:\\",
            mountPoint: "C:\\"
        ))
        XCTAssertTrue(driveScript.contains("Get-Volume -DriveLetter 'C'"))
        XCTAssertTrue(driveScript.contains("Get-Partition"))
        XCTAssertTrue(driveScript.contains("Get-Disk"))
        assertReadOnly(driveScript)

        let pathScript = try XCTUnwrap(StorageHealthTargetResolver.windowsResolutionScript(
            source: #"\\?\Volume{user's-volume}\"#,
            mountPoint: ""
        ))
        XCTAssertTrue(pathScript.contains("user''s-volume"))
    }

    func testBSDResolutionMapsKnownDiskNamesAndRejectsAmbiguity() {
        XCTAssertEqual(
            StorageHealthTargetResolver.parseBSDResolution(
                marked("ada0 da1"),
                platform: .freebsd,
                source: "/dev/ada0p2",
                deviceID: deviceID
            ),
            singleTarget(.freeBSD(devicePath: "/dev/ada0"))
        )
        XCTAssertEqual(
            StorageHealthTargetResolver.parseBSDResolution(
                marked("sd0:abc wd1:def"),
                platform: .openbsd,
                source: "/dev/rsd0a",
                deviceID: deviceID
            ),
            singleTarget(.openBSD(devicePath: "/dev/sd0c"))
        )
        XCTAssertEqual(
            StorageHealthTargetResolver.parseBSDResolution(
                marked("wd1"),
                platform: .netbsd,
                source: "/dev/wd1e",
                deviceID: deviceID
            ),
            singleTarget(.netBSD(devicePath: "/dev/wd1d"))
        )
        XCTAssertEqual(
            StorageHealthTargetResolver.parseBSDResolution(
                marked("ada0 ada0p2"),
                platform: .freebsd,
                source: "/dev/ada0p2",
                deviceID: deviceID
            ),
            .unavailable(.unmapped)
        )
    }

    func testBSDResolutionCommandsUseReadOnlySysctlKeys() throws {
        let freeBSD = try XCTUnwrap(StorageHealthTargetResolver.bsdResolutionCommand(platform: .freebsd))
        let openBSD = try XCTUnwrap(StorageHealthTargetResolver.bsdResolutionCommand(platform: .openbsd))
        let netBSD = try XCTUnwrap(StorageHealthTargetResolver.bsdResolutionCommand(platform: .netbsd))

        XCTAssertTrue(freeBSD.contains("sysctl -n kern.disks"))
        XCTAssertTrue(openBSD.contains("sysctl -n hw.disknames"))
        XCTAssertTrue(netBSD.contains("sysctl -n hw.disknames"))
        for command in [freeBSD, openBSD, netBSD] {
            assertReadOnly(command)
        }
        XCTAssertNil(StorageHealthTargetResolver.bsdResolutionCommand(platform: .linux))
    }

    private func volume(source: String, fileSystem: String) -> VolumeInfo {
        VolumeInfo(
            platform: .linux,
            mountPoint: "/data",
            source: source,
            fileSystem: fileSystem,
            used: 1,
            total: 2
        )
    }

    private func singleTarget(
        _ kind: StorageHealthProbeTarget.Kind
    ) -> StorageHealthTargetResolution {
        .topology(StorageHealthResolvedTopology(
            kind: .physicalDevice,
            name: nil,
            findings: [],
            members: [.target(
                role: .data,
                StorageHealthProbeTarget(deviceID: deviceID, kind: kind),
                findings: []
            )]
        ))
    }

    private func marked(_ payload: String) -> String {
        """
        \(StorageHealthTargetResolver.resolutionBeginMarker)
        \(payload)
        \(StorageHealthTargetResolver.resolutionEndMarker)
        """
    }

    private func plistString(_ value: [String: Any]) throws -> String {
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func assertReadOnly(
        _ command: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let forbidden = [
            "sudo ", " smartctl -t", "mkfs", "diskpart", "Format-Volume",
            "Set-Disk", "Remove-Partition", "Initialize-Disk"
        ]
        for token in forbidden {
            XCTAssertFalse(command.localizedCaseInsensitiveContains(token), file: file, line: line)
        }
    }
}
