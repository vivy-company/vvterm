import Foundation

nonisolated struct TerminalHardwareKeyRepeatState<Payload> {
    nonisolated struct Active {
        let token: UUID
        let keyCode: UInt16
        var payload: Payload
    }

    nonisolated enum Phase {
        case idle
        case repeating(Active)
    }

    nonisolated enum Registration {
        case started(Active)
        case updated(Active)
    }

    private(set) var phase: Phase = .idle

    @discardableResult
    mutating func register(
        keyCode: UInt16,
        payload: Payload
    ) -> Registration {
        if case .repeating(var active) = phase,
           active.keyCode == keyCode {
            active.payload = payload
            phase = .repeating(active)
            return .updated(active)
        }

        let active = Active(
            token: UUID(),
            keyCode: keyCode,
            payload: payload
        )
        phase = .repeating(active)
        return .started(active)
    }

    func active(for token: UUID) -> Active? {
        guard case .repeating(let active) = phase,
              active.token == token else {
            return nil
        }
        return active
    }

    @discardableResult
    mutating func end(keyCode: UInt16) -> Active? {
        guard case .repeating(let active) = phase,
              active.keyCode == keyCode else {
            return nil
        }
        phase = .idle
        return active
    }

    @discardableResult
    mutating func cancel() -> Active? {
        guard case .repeating(let active) = phase else {
            return nil
        }
        phase = .idle
        return active
    }
}
