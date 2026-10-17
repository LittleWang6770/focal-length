import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

@main struct Verification {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message:String) throws {
        if try condition() == false { throw NSError(domain:"Verification",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    }
    static func photo(_ url:URL, type:UTType = .jpeg, focal:Double? = nil, equivalent:Int? = nil, lens:String? = nil) throws {
        let context = CGContext(data:nil,width:64,height:64,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red:0.35,green:0.50,blue:0.60,alpha:1)); context.fill(CGRect(x:0,y:0,width:64,height:64))
        let image = context.makeImage()!
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,type.identifier as CFString,1,nil) else { throw ScanFailure.unreadable(url.path) }
        var exif: [String:Any] = [:]
        if let focal { exif[kCGImagePropertyExifFocalLength as String] = focal }
        if let equivalent { exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] = equivalent }
        if let lens { exif[kCGImagePropertyExifLensModel as String] = lens; exif[kCGImagePropertyExifLensMake as String] = "SONY" }
        let props: [String:Any] = [kCGImagePropertyExifDictionary as String:exif,
            kCGImagePropertyTIFFDictionary as String:[kCGImagePropertyTIFFModel as String:"Synthetic test camera"]]
        CGImageDestinationAddImage(destination,image,props as CFDictionary)
        try check(CGImageDestinationFinalize(destination),"Fixture encoding failed: \(url.lastPathComponent)")
    }
    @MainActor static func main() async throws {
        // Star ratings are library properties, not album names or EXIF values.
        let fiveStars = PhotoScope(id:PhotoScope.rating(5).id)
        let ratingFixture = [0,1,2,3,4,5,5,0]
        try check(ratingFixture.filter { fiveStars.includes(rating:$0) } == [5,5],"Five stars must exclude unrated and lower-rated assets")
        try check(ratingFixture.filter { PhotoScope.rating(0).includes(rating:$0) } == [0,0],"Unrated is an explicit scope, not all photos")
        try check(ratingFixture.filter { PhotoScope(id:"").includes(rating:$0) } == ratingFixture,"All photos must retain every rating")
        try check(PhotoScope(id:"★★★★★") == .album("★★★★★"),"Star-named albums must not be reinterpreted")
        for stars in 1...5 {
            let title = String(repeating:"★",count:stars)
            try check(PhotoScope.albumTitle(title,hasPhotos:false,systemRatings:true) == nil,"Empty legacy star albums must not duplicate system rating entries")
            try check(PhotoScope.albumTitle(title,hasPhotos:true,systemRatings:true) == "普通相簿 · \(title)","Populated legacy albums must remain accessible with a distinct label")
            try check(PhotoScope.albumTitle(title,hasPhotos:false,systemRatings:false) != nil,"Old systems must retain legacy albums")
        }
        try check(PhotoScope.albumTitle(" ★ ★ ★ ★ ★ ",hasPhotos:false,systemRatings:true) == nil,"Whitespace must not leave ambiguous star entries")
        try check(PhotoScope.albumTitle("旅行★★★★★",hasPhotos:false,systemRatings:true) == "旅行★★★★★","Do not hide ordinary named albums")
        try check(PhotoScope.albumTitle("旅行",hasPhotos:false,systemRatings:true) == "旅行","Keep unrelated empty albums")
        try check(PhotoScope(id:"album-local-id") == .album("album-local-id"),"Existing album identifiers remain unchanged")
        try check(PhotoScope.ratingChoices(supported:false).isEmpty,"Old systems must not offer unsupported star scopes")
        let ratingChoices = PhotoScope.ratingChoices(supported:true)
        try check(Set(ratingChoices.map(\.id)).count == 6 && ratingChoices.first?.id == fiveStars.id,"Rating scopes have stable unique identities")
        try check(PhotoScope(id:"focal-statistics:rating:99") == .album("focal-statistics:rating:99"),"Invalid scope must not silently fetch the whole library")
        let base = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/fixtures")
        let root = base.appendingPathComponent(UUID().uuidString)
        let nested = root.appendingPathComponent("nested")
        let package = root.appendingPathComponent("test.photoslibrary")
        try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:package,withIntermediateDirectories:true)
        try photo(root.appendingPathComponent("zoom-24.JPG"),focal:24,equivalent:24,lens:"FE 24-70mm F2.8 GM II")
        try photo(root.appendingPathComponent("zoom-49.jpeg"),focal:49,equivalent:49,lens:"FE 24-70mm F2.8 GM II")
        try photo(root.appendingPathComponent("prime-35.jpg"),focal:35,equivalent:35,lens:"FE 35mm F1.4 GM")
        try photo(root.appendingPathComponent("actual-only.jpg"),focal:23,lens:"23mm F2")
        try photo(root.appendingPathComponent("plain.png"),type:.png)
        try photo(root.appendingPathComponent("LIVE.HEIC"),type:.heic,focal:6.86,equivalent:24)
        try photo(nested.appendingPathComponent("zoom-51.jpg"),focal:51,equivalent:51,lens:"FE 24-70mm F2.8 GM II")
        try photo(root.appendingPathComponent(".hidden.jpg"),focal:100,equivalent:100)
        try photo(package.appendingPathComponent("inside.jpg"),focal:200,equivalent:200)
        try Data("corrupt fixture".utf8).write(to:root.appendingPathComponent("bad.JPG"))
        try Data("paired video placeholder".utf8).write(to:root.appendingPathComponent("LIVE.MOV"))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("link.jpg"),withDestinationURL:root.appendingPathComponent("zoom-24.JPG"))
        try FileManager.default.createSymbolicLink(at:nested.appendingPathComponent("loop"),withDestinationURL:root)
        try root.path.write(to:base.appendingPathComponent("latest.txt"),atomically:true,encoding:.utf8)

        let shallow = try await ScanEngine.folder(root,recursive:false) { _ in }
        try check(shallow.records.count == 6,"Current directory expected 6 readable photos, got \(shallow.records.count)")
        try check(shallow.attempted == 7 && shallow.failed == 1,"Corrupt JPEG must be reported without stopping scan")
        let recursive = try await ScanEngine.folder(root,recursive:true) { _ in }
        try check(recursive.records.count == 7,"Recursive scan must include one nested image and exclude symlinks/packages: \(recursive.records.count)")
        try check(recursive.failed == 1 && recursive.attempted == 8,"Recursive counts")
        let second = base.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:second,withIntermediateDirectories:true)
        try photo(second.appendingPathComponent("second-85.jpg"),focal:85,equivalent:85,lens:"85mm F1.8")
        let missing = base.appendingPathComponent("offline-disk-\(UUID().uuidString)")
        let combined = try await ScanEngine.folders([root,nested,second,root],recursive:true) { _ in }
        try check(combined.records.count == 8 && combined.attempted == 9 && combined.failed == 1,"Overlapping and repeated roots must count each photo/corrupt file once")
        try check(Set(combined.records.map(\.id)).count == 8,"Merged records must have unique paths")
        let combinedShallow = try await ScanEngine.folders([root,nested,second],recursive:false) { _ in }
        try check(combinedShallow.records.count == 8,"Current-level mode must apply to every selected root")
        let partial = try await ScanEngine.folders([missing,root,second],recursive:true) { _ in }
        try check(partial.records.count == 8 && partial.unavailableFolders == [missing.path] && partial.inaccessibleDirectories == 1,"An offline root must not discard other sources")
        do { _ = try await ScanEngine.folders([missing],recursive:true) { _ in }; throw ScanFailure.unreadable("All-offline scan unexpectedly succeeded") }
        catch { try check(!(error is ScanFailure),"All-offline scan must fail instead of reporting a successful zero") }
        do { _ = try await ScanEngine.folders([],recursive:true) { _ in }; throw CancellationError() }
        catch { try check(error is ScanFailure,"Empty source list must fail explicitly") }

        let suite = "FocalLengthVerification.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName:suite)!
        defer { preferences.removePersistentDomain(forName:suite) }
        let savedSources = [FolderAccess.make(root),FolderAccess.make(second)]
        try check(savedSources.allSatisfy { $0.bookmark != nil },"Both roots must receive independent read-only bookmarks")
        try FolderAccess.save(savedSources,defaults:preferences)
        let restored = try FolderAccess.restore(defaults:preferences)
        try check(restored.map(\.id) == savedSources.map(\.id) && restored.map { $0.url.path } == savedSources.map { $0.url.path },"Folder list, order and stable identifiers must survive restoration")
        let relaunched = AppModel(defaults:preferences)
        try check(relaunched.chosen && relaunched.folders.map(\.id) == savedSources.map(\.id),"Relaunch must restore every root and enable scanning")
        let invalid = FolderSource(url:missing,bookmark:Data("invalid bookmark".utf8))
        try FolderAccess.save([savedSources[0],invalid],defaults:preferences)
        let degraded = try FolderAccess.restore(defaults:preferences)
        try check(degraded.count == 2 && degraded[0].accessIssue == nil && degraded[1].url.path == missing.path && degraded[1].accessIssue != nil,"One broken/offline bookmark must retain its path and not lose other sources")
        try FolderAccess.save([],defaults:preferences)
        try check(try FolderAccess.restore(defaults:preferences).isEmpty,"Removing all roots must persist an empty list")
        preferences.removeObject(forKey:FolderAccess.listKey)
        preferences.set(try FolderAccess.bookmark(root),forKey:FolderAccess.key)
        let migrated = try FolderAccess.restore(defaults:preferences)
        try check(migrated.count == 1 && migrated[0].url.path == root.path && preferences.data(forKey:FolderAccess.listKey) != nil && preferences.data(forKey:FolderAccess.key) == nil,"Migrate the previous single-folder bookmark")
        let folderModel = AppModel(restore:false,defaults:preferences)
        folderModel.addFolders([root,second,root],persist:false)
        try check(folderModel.folders.count == 2 && folderModel.chosen,"Adding multiple folders is additive and deduplicates paths")
        folderModel.report = combined; folderModel.phase = .complete
        try check(folderModel.exportCSV().contains(root.path) && folderModel.exportCSV().contains(second.path),"CSV must identify every selected root")
        let originalFiles = Set(try FileManager.default.contentsOfDirectory(atPath:root.path))
        folderModel.selectedFolderIDs = Set(folderModel.folders.map(\.id))
        folderModel.removeSelectedFolders(persist:true)
        try check(folderModel.folders.isEmpty && !folderModel.chosen && folderModel.base.isEmpty,"Batch removal clears stale results and disables scanning")
        try check(Set(try FileManager.default.contentsOfDirectory(atPath:root.path)) == originalFiles,"Removing sources must never modify source files")
        try check(try FolderAccess.restore(defaults:preferences).isEmpty,"Removed paths must not return on relaunch")
        folderModel.addFolders([root,second],persist:false)
        folderModel.selectedFolderIDs = [folderModel.folders[0].id]
        folderModel.removeSelectedFolders(persist:false)
        try check(folderModel.folders.count == 1 && folderModel.folders[0].url == second,"Removing a single source keeps the others")
        try check(recursive.records.filter { $0.equivalent != nil }.count == 5,"Equivalent focal coverage must exclude missing EXIF and actual-only image")
        try check(recursive.records.filter { $0.actual != nil }.count == 6,"Actual focal coverage")
        try check(recursive.records.first { $0.id.hasSuffix("actual-only.jpg") }?.equivalent == nil,"Never infer equivalent from physical focal")
        try check(recursive.records.first { $0.id.hasSuffix("LIVE.HEIC") }?.equivalent == 24,"HEIC equivalent EXIF")
        let dataRecord = try MetadataReader.read(data:Data(contentsOf:root.appendingPathComponent("prime-35.jpg")),id:"photo-asset")
        try check(dataRecord.lens == "SONY FE 35mm F1.4 GM" && dataRecord.equivalent == 35,"PhotoKit data path metadata parsing")

        let model = AppModel(restore:false,defaults:preferences)
        try check(model.allowNetwork,"iCloud download must default to enabled")
        model.allowNetwork = false; model.source = 1; model.sourceChanged()
        try check(!model.allowNetwork,"Keep an explicit opt-out when switching source")
        model.source = 0; model.sourceChanged()
        model.report = recursive
        try check(model.lensRows.reduce(0) { $0+$1.count } == 7,"Lens totals reconcile including unknown")
        try check(model.focalRows.first?.name == "24 mm" && model.focalRows.first?.count == 2,"Standard grouping and ties")
        model.selectedLens = "SONY FE 24-70mm F2.8 GM II"
        try check(model.filtered.count == 3 && model.valid == 3,"Zoom lens filter")
        try check(model.focalRows.first?.name == "50 mm" && model.focalRows.first?.count == 2,"49/51 group within zoom lens")
        try check(model.percent(2) == "66.7%","Filtered denominator")
        try check(model.lensRows.reduce(0) { $0+$1.count } == 7,"Lens overview denominator stays global")
        model.selectedLens = "SONY FE 35mm F1.4 GM"
        try check(model.filtered.count == 1 && model.focalRows.first?.name == "35 mm","35 GM remains independent of zoom shots")
        for focal in [49.0,50.0,51.0] { try check(AppModel.bucket(focal,standard:true) == 50,"Proportional grouping") }
        try check(AppModel.bucket(35.5,standard:false) == 36,"Half-up exact grouping")
        try check(AppModel.bucket(6.86,standard:true) == 6.86,"Out-of-range physical focal retained")
        try check(MetadataReader.positive(Double.nan) == nil && MetadataReader.positive(-1) == nil && MetadataReader.positive(true) == nil,"Invalid metadata rejected")
        try check(AppModel.csvField("=cmd,\"test\"") == "\"'=cmd,\"\"test\"\"\"","CSV escaping and formula protection")
        try check(model.exportCSV().contains("镜头筛选"),"CSV filter context")
        model.source = 1; model.albums = ratingChoices; model.selectedAlbumID = fiveStars.id
        try check(model.sourceName == "5 星照片 · 整个图库","Dashboard must identify star scope")
        try check(model.exportCSV().contains("5 星照片 · 整个图库"),"CSV must preserve selected star scope")
        model.reset()
        try check(model.selectedAlbumID == fiveStars.id && model.base.isEmpty,"Reset results without losing the star selection")
        model.source = 0; model.selectedAlbumID = ""

        let empty = base.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at:empty,withIntermediateDirectories:true)
        let emptyReport = try await ScanEngine.folder(empty,recursive:true) { _ in }
        try check(emptyReport.records.isEmpty && emptyReport.failed == 0,"Empty directory success")
        do { _ = try await ScanEngine.folder(base.appendingPathComponent("missing"),recursive:true) { _ in }; throw ScanFailure.unreadable("Missing directory unexpectedly succeeded") }
        catch { try check(!(error is ScanFailure),"Nonexistent source must fail with filesystem error") }
        let cancelled = Task { try await ScanEngine.folders([root,second],recursive:true) { _ in } }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw ScanFailure.unreadable("Cancellation ignored") }
        catch { try check(error is CancellationError,"Cancelled scan must not return a completed report") }

        model.show(.complete)
        try check(model.demo && model.base.count == 1200 && model.valid == 1140,"Independent demo dataset")
        model.show(.running); model.stop()
        try check(!model.hasResults && !model.isRunning && model.progress < 1,"Stop terminal state")
        model.show(.failed)
        try check(!model.hasResults && model.progress < 1,"Failure must not claim success")
        model.exitDemo()
        try check(!model.demo && model.base.isEmpty,"No synthetic records leak into real results")
        print("PASS: multiple roots, overlap deduplication, offline roots, bookmark restoration/migration, additive selection, batch removal, source CSV, ratings, JPEG/PNG/HEIC, metadata, current/recursive, symlinks/packages, Live Photo file pair, failures, counts, grouping, cancellation, demo isolation")
        print("Synthetic fixture folder: \(root.path)")
    }
}
