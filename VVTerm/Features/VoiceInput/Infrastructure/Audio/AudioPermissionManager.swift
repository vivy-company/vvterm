import Foundation
import Combine
import AVFoundation
import Speech

@MainActor
class AudioPermissionManager: ObservableObject {
    @Published var permissionStatus: PermissionStatus = .notDetermined

    enum PermissionStatus {
        case notDetermined
        case authorized
        case denied
    }

    // MARK: - Permission Requests

    func requestPermissions(includeSpeech: Bool = true) async -> Bool {
        let granted = await Self.requestPermissionSequence(
            includeSpeech: includeSpeech,
            requestMicrophone: { [weak self] in
                await self?.requestMicrophonePermission() ?? false
            },
            requestSpeech: { [weak self] in
                await self?.requestSpeechPermission() ?? false
            }
        )
        guard !Task.isCancelled else { return false }
        permissionStatus = granted ? .authorized : .denied
        return granted
    }

    static func requestPermissionSequence(
        includeSpeech: Bool,
        requestMicrophone: @escaping @MainActor () async -> Bool,
        requestSpeech: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let microphoneGranted = await requestMicrophone()
        guard !Task.isCancelled else { return false }
        let speechGranted = includeSpeech ? await requestSpeech() : true
        guard !Task.isCancelled else { return false }
        return microphoneGranted && speechGranted
    }

    func checkPermissions(includeSpeech: Bool = true) -> Bool {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let speechStatus = includeSpeech ? SFSpeechRecognizer.authorizationStatus() : .authorized

        let granted = micStatus == .authorized && speechStatus == .authorized
        let notDetermined = micStatus == .notDetermined || (includeSpeech && speechStatus == .notDetermined)
        permissionStatus = granted ? .authorized : (notDetermined ? .notDetermined : .denied)
        return granted
    }

    // MARK: - Microphone Permission

    private func requestMicrophonePermission() async -> Bool {
        let currentStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        switch currentStatus {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Speech Permission

    private func requestSpeechPermission() async -> Bool {
        let currentStatus = SFSpeechRecognizer.authorizationStatus()

        if currentStatus == .authorized {
            return true
        }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
