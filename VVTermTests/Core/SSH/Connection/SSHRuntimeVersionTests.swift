import Testing
@testable import VVTerm

struct SSHRuntimeVersionTests {
    @Test
    func vendoredLibSSH2IncludesNonblockingTransportFix() {
        // libssh2 1.11.1 fixes cross-caller packet resumption that can corrupt
        // nonblocking connections during overlapping channel operations.
        #expect(LibSSH2Runtime.supports(requiredVersion: 0x010B01))
    }
}
