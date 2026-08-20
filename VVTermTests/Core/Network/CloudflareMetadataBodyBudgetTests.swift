import Testing
@testable import VVTerm

struct CloudflareMetadataBodyBudgetTests {
    @Test
    func declaredContentLengthMustFitTheBodyLimit() throws {
        let budget = CloudflareMetadataBodyBudget(maximumBytes: 32)

        try budget.validateExpectedContentLength(32)
        #expect(throws: CloudflareMetadataRequestError.self) {
            try budget.validateExpectedContentLength(33)
        }
    }

    @Test
    func streamedChunksCannotExceedTheCumulativeLimit() throws {
        var budget = CloudflareMetadataBodyBudget(maximumBytes: 8)

        try budget.record(byteCount: 3)
        try budget.record(byteCount: 5)
        #expect(budget.receivedBytes == 8)
        #expect(throws: CloudflareMetadataRequestError.self) {
            try budget.record(byteCount: 1)
        }
    }

    @Test
    func unknownContentLengthIsCheckedWhileStreaming() throws {
        var budget = CloudflareMetadataBodyBudget(maximumBytes: 4)

        try budget.validateExpectedContentLength(-1)
        #expect(throws: CloudflareMetadataRequestError.self) {
            try budget.record(byteCount: Int.max)
        }
    }
}
