import Foundation

/// When L1ne plays its own ringback tone.
enum RingbackRule {
    /// From the moment an outgoing call is placed until it is answered, so the person hears something while it says "Calling…" and not only once the
    /// other phone is reported as ringing. Not when the setting lets the PBX's own early media through instead.
    static func wanted(outgoing: Bool, answered: Bool, waiting: Bool, acceptEarlyMedia: Bool) -> Bool {
        outgoing && !answered && waiting && !acceptEarlyMedia
    }
}
