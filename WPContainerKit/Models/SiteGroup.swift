import Foundation

/// A named, ordered grouping of sites in the sidebar (PLAN.md §2g).
///
/// Groups are purely an organizational overlay: a `Site` references its group by
/// `groupID` (nil = ungrouped). Deleting a group never deletes its sites — they
/// simply fall back to the ungrouped section.
public struct SiteGroup: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var name: String
    /// Ascending display order among groups.
    public var sortOrder: Int

    public init(id: UUID = UUID(), name: String, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
    }
}
