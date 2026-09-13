import Foundation

struct WhoopConnectionSession: Equatable, Sendable {
    struct Token: Equatable, Sendable {
        let generation: UInt64
        let peripheralID: UUID
    }

    private(set) var generation: UInt64 = 0
    private(set) var peripheralID: UUID?

    mutating func select(_ peripheralID: UUID) -> Token {
        generation &+= 1
        self.peripheralID = peripheralID
        return Token(generation: generation, peripheralID: peripheralID)
    }

    mutating func resetKeepingPeripheral() -> Token? {
        generation &+= 1
        guard let peripheralID else { return nil }
        return Token(generation: generation, peripheralID: peripheralID)
    }

    mutating func clear() {
        generation &+= 1
        peripheralID = nil
    }

    func token() -> Token? {
        guard let peripheralID else { return nil }
        return Token(generation: generation, peripheralID: peripheralID)
    }

    func accepts(peripheralID: UUID) -> Bool {
        self.peripheralID == peripheralID
    }

    func accepts(_ token: Token) -> Bool {
        generation == token.generation && peripheralID == token.peripheralID
    }
}
