import Testing
@testable import VVTerm

struct LocalSSHDiscoveryHostEnumerationTests {
    @Test
    func maximumNetworkAndBroadcastProduceNoHostsWithoutOverflow() {
        #expect(
            LocalSSHDiscoveryService.hosts(
                in: .max,
                broadcast: .max,
                excluding: .max
            ).isEmpty
        )
    }

    @Test
    func zeroNetworkEnumeratesOnlyAddressesBetweenNetworkAndBroadcast() {
        #expect(
            LocalSSHDiscoveryService.hosts(
                in: 0,
                broadcast: 3,
                excluding: 0
            ) == ["0.0.0.1", "0.0.0.2"]
        )
    }

    @Test
    func pointToPointAndSingleAddressRangesAreEmpty() {
        #expect(
            LocalSSHDiscoveryService.enumerateHosts(
                address: 0xC000_0200,
                netmask: 0xFFFF_FFFE
            ).isEmpty
        )
        #expect(
            LocalSSHDiscoveryService.enumerateHosts(
                address: 0xC000_0201,
                netmask: .max
            ).isEmpty
        )
    }

    @Test
    func oversizedDirectRangeIsRejectedBeforeAllocation() {
        #expect(
            LocalSSHDiscoveryService.hosts(
                in: 0,
                broadcast: .max,
                excluding: 1
            ).isEmpty
        )
    }

    @Test
    func currentAddressIsExcluded() {
        #expect(
            LocalSSHDiscoveryService.hosts(
                in: 0xC000_0200,
                broadcast: 0xC000_0204,
                excluding: 0xC000_0202
            ) == ["192.0.2.1", "192.0.2.3"]
        )
    }

    @Test
    func broadSubnetStillEnumeratesOnlyTheCurrentTwentyFourBitSlice() {
        let hosts = LocalSSHDiscoveryService.enumerateHosts(
            address: 0x0A01_0203,
            netmask: 0xFFFF_0000
        )

        #expect(hosts.count == 253)
        #expect(hosts.first == "10.1.2.1")
        #expect(hosts.last == "10.1.2.254")
        #expect(!hosts.contains("10.1.2.3"))
        #expect(!hosts.contains("10.1.3.1"))
    }

    @Test
    func maximumBroadcastEnumeratesItsTwentyFourBitHostRange() {
        let hosts = LocalSSHDiscoveryService.enumerateHosts(
            address: .max,
            netmask: 0xFFFF_FF00
        )

        #expect(hosts.count == 254)
        #expect(hosts.first == "255.255.255.1")
        #expect(hosts.last == "255.255.255.254")
    }
}
