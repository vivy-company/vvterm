import Darwin
import Testing
@testable import VVTerm

struct SSHAddressCandidatePolicyTests {
    @Test
    func candidatesAlternateAddressFamiliesWithoutDiscardingResolverOrder() {
        let ordered = SSHAddressCandidatePolicy.interleavedFamilies([
            .ipv6,
            .ipv6,
            .ipv4,
            .ipv4,
            .other,
        ])

        #expect(ordered == [.ipv6, .ipv4, .ipv6, .ipv4, .other])
    }

    @Test
    func candidateLaunchOffsetsAreBoundedAndStaggered() {
        #expect(
            SSHAddressCandidatePolicy.launchOffsets(candidateCount: 4)
                == [.zero, .milliseconds(250), .milliseconds(500), .milliseconds(750)]
        )
        #expect(SSHAddressCandidatePolicy.launchOffsets(candidateCount: 0).isEmpty)
        #expect(
            SSHAddressCandidatePolicy.launchOffsets(candidateCount: .max).count
                == SSHAddressCandidatePolicy.maximumCandidateCount
        )
    }

    @Test
    func numericAddressesBypassNameServiceResolution() {
        #expect(
            SSHAddressConnector.resolutionFlags(for: "192.0.2.1")
                == AI_NUMERICHOST | AI_NUMERICSERV
        )
        #expect(
            SSHAddressConnector.resolutionFlags(for: "2001:db8::1")
                == AI_NUMERICHOST | AI_NUMERICSERV
        )
        #expect(
            SSHAddressConnector.resolutionFlags(for: "server.example.com")
                == AI_NUMERICSERV
        )
    }
}
