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
        let micPermission = await requestMicrophonePermission()
        let speechPermission = includeSpeech ? await requestSpeechPermission() : true

        let granted = micPermission && speechPermission
        permissionStatus = granted ? .authorized : .denied
        return granted
    }

    func checkPermissions(includeSpeech: Bool = true) async -> Bool {
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
