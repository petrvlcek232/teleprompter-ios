import Foundation

/// Tvar selfie okénka v PiP režimu.
enum PiPShape: String, CaseIterable, Identifiable {
    case rectangle
    case square
    case circle

    var id: String { rawValue }
}
