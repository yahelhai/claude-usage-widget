import Foundation

/// Constants shared by the widget (the loopback server) and the exporter/feeder (the client).
///
/// The bridge only ever carries percentages and reset times — never a token — and writes nothing
/// to disk. It lives entirely on 127.0.0.1.
enum BridgeProtocol {
    static let host = "127.0.0.1"
    static let port: UInt16 = 47823

    /// The first line a client must send. Light hardening so a stray local process can't feed
    /// spoofed rows. The data isn't sensitive, so this is deliberately simple rather than a
    /// cryptographic control.
    static let magic = "CLAUDE-USAGE/1"
}
