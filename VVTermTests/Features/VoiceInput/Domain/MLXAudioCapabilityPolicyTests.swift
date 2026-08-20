import Testing
@testable import VVTerm

struct MLXAudioCapabilityPolicyTests {
    @Test
    func a10EraMobileGPURejectsMLXBeforeModelLoading() {
        let isSupported = MLXAudioCapabilityPolicy.isSupported(
            platform: .appleMobile,
            supportsNonuniformThreadgroups: false
        )

        #expect(!isSupported)
    }

    @Test
    func apple4OrNewerMobileGPUAllowsMLX() {
        let isSupported = MLXAudioCapabilityPolicy.isSupported(
            platform: .appleMobile,
            supportsNonuniformThreadgroups: true
        )

        #expect(isSupported)
    }

    @Test
    func missingMetalDeviceRejectsMLX() {
        let isSupported = MLXAudioCapabilityPolicy.isSupported(
            platform: .appleMobile,
            supportsNonuniformThreadgroups: nil
        )

        #expect(!isSupported)
    }

    @Test
    func unsupportedParakeetRequestFallsBackToAppleSpeech() {
        let provider = TranscriptionProviderResolutionPolicy.resolve(
            requested: .mlxParakeet,
            mlxSupported: false,
            requestedModelAvailable: true
        )

        #expect(provider == .system)
    }

    @Test
    func supportedDownloadedParakeetRemainsSelected() {
        let provider = TranscriptionProviderResolutionPolicy.resolve(
            requested: .mlxParakeet,
            mlxSupported: true,
            requestedModelAvailable: true
        )

        #expect(provider == .mlxParakeet)
    }

    @Test
    func missingParakeetModelFallsBackToAppleSpeech() {
        let provider = TranscriptionProviderResolutionPolicy.resolve(
            requested: .mlxParakeet,
            mlxSupported: true,
            requestedModelAvailable: false
        )

        #expect(provider == .system)
    }
}
