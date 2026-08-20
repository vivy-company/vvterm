import Darwin
import Testing
@testable import VVTerm

@Suite(.serialized)
struct AtomicSocketTests {
    @Test
    func installMakesSocketUsableAndCloseIsIdempotentAfterDescriptorReuse() throws {
        let pair = try makeSocketPair()
        let socket = AtomicSocket()
        var replacementDescriptor: Int32?
        defer {
            socket.close()
            if let replacementDescriptor {
                Darwin.close(replacementDescriptor)
            }
            Darwin.close(pair.peerDescriptor)
        }

        #expect(!socket.isUsable)

        socket.install(pair.managedDescriptor)

        #expect(socket.isUsable)

        socket.close()

        #expect(!socket.isUsable)

        let duplicatedDescriptor = Darwin.dup2(
            pair.peerDescriptor,
            pair.managedDescriptor
        )
        guard duplicatedDescriptor == pair.managedDescriptor else {
            throw AtomicSocketTestError.systemCallFailed("dup2", errno)
        }
        replacementDescriptor = duplicatedDescriptor

        socket.close()

        #expect(Darwin.fcntl(duplicatedDescriptor, F_GETFD, 0) >= 0)
    }

    @Test
    func interruptWakesPeerWithoutClosingUntilClose() throws {
        let pair = try makeSocketPair()
        let socket = AtomicSocket()
        defer {
            socket.close()
            Darwin.close(pair.peerDescriptor)
        }
        socket.install(pair.managedDescriptor)

        socket.interrupt()

        #expect(!socket.isUsable)
        #expect(Darwin.fcntl(pair.managedDescriptor, F_GETFD, 0) >= 0)

        let wakeEvents = Int16(POLLIN | POLLHUP)
        var peerPoll = pollfd(
            fd: pair.peerDescriptor,
            events: wakeEvents,
            revents: 0
        )
        let pollResult = Darwin.poll(&peerPoll, 1, 1_000)

        #expect(pollResult == 1)
        guard pollResult == 1 else {
            throw AtomicSocketTestError.peerDidNotWake(
                pollResult: pollResult,
                events: peerPoll.revents
            )
        }
        #expect(peerPoll.revents & wakeEvents != 0)
        guard peerPoll.revents & wakeEvents != 0 else {
            throw AtomicSocketTestError.peerDidNotWake(
                pollResult: pollResult,
                events: peerPoll.revents
            )
        }

        var byte: UInt8 = 0
        #expect(Darwin.read(pair.peerDescriptor, &byte, 1) == 0)

        socket.close()

        let descriptorStatus = Darwin.fcntl(pair.managedDescriptor, F_GETFD, 0)
        let descriptorError = errno
        #expect(descriptorStatus == -1)
        #expect(descriptorError == EBADF)
    }

    private func makeSocketPair() throws -> (
        managedDescriptor: Int32,
        peerDescriptor: Int32
    ) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw AtomicSocketTestError.systemCallFailed("socketpair", errno)
        }
        return (descriptors[0], descriptors[1])
    }
}

private enum AtomicSocketTestError: Error {
    case systemCallFailed(String, Int32)
    case peerDidNotWake(pollResult: Int32, events: Int16)
}
