import Foundation

enum FolderAccess {
    static let key = "photoFolderBookmark.v1"
    static func save(_ url:URL, defaults:UserDefaults = .standard) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options:[.withSecurityScope,.securityScopeAllowOnlyReadAccess],includingResourceValuesForKeys:nil,relativeTo:nil)
        defaults.set(data,forKey:key)
    }
    static func restore(defaults:UserDefaults = .standard) throws -> URL? {
        guard let data = defaults.data(forKey:key) else { return nil }
        var stale = false
        let url = try URL(resolvingBookmarkData:data,options:[.withSecurityScope,.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale)
        if stale { try save(url,defaults:defaults) }
        return url
    }
}
