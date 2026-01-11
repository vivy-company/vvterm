import SwiftUI
import Combine

// MARK: - onChange compat (macOS 13 / iOS 16)

private struct OnChangeCompatModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let action: (Value) -> Void
    @State private var previous: Value

    init(value: Value, action: @escaping (Value) -> Void) {
        self.value = value
        self.action = action
        _previous = State(initialValue: value)
    }

    func body(content: Content) -> some View {
        content.onReceive(Just(value)) { newValue in
            guard newValue != previous else { return }
            previous = newValue
            action(newValue)
        }
    }
}

extension View {
    func onChangeCompat<Value: Equatable>(of value: Value, perform action: @escaping (Value) -> Void) -> some View {
        modifier(OnChangeCompatModifier(value: value, action: action))
    }
}
