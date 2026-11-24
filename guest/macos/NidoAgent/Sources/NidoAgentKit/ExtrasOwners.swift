// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A process whose menu bar extras read stopped part way: the items read before it. The walk
/// keeps them and says `truncated`.
public struct PartialList<Node>: Error, @unchecked Sendable {
    public let items: [Node]
    public init(items: [Node]) { self.items = items }
}

/// Which processes the walk asks for menu bar extras.
public enum ExtrasOwners {
    /// The running apps that may show extras: every one that is not background-only (`prohibited`
    /// activation policy), in the given order, without the menu-bar owner, which comes last (and
    /// is always there, background-only or not). Nothing for the owner when there is none.
    public static func pids(apps: [(pid: Int32, backgroundOnly: Bool)], menuBarOwner: Int32?) -> [Int32] {
        apps.filter { !$0.backgroundOnly && $0.pid != menuBarOwner }.map(\.pid) + (menuBarOwner.map { [$0] } ?? [])
    }
}
