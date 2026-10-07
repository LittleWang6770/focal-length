import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

struct PhotoRecord: Identifiable, Sendable {
    let id: String
    let lens: String?
    let actual: Double?
    let equivalent: Double?
    var camera: String? = nil
}

struct ScanIssue: Sendable {
    let name: String
    let reason: String
}

struct ScanReport: Sendable {
    var records: [PhotoRecord] = []
    var attempted = 0
    var cloud = 0
    var unsupported = 0
    var failed = 0
    var inaccessibleDirectories = 0
    // Keep a bounded diagnostic sample even for a very large damaged folder.
    var issues: [ScanIssue] = []
    mutating func issue(_ name: String, _ reason: String) {
        if issues.count < 100 { issues.append(ScanIssue(name:name,reason:reason)) }
    }
}

struct ScanProgress: Sendable {
    let completed: Int
    let total: Int
    let name: String
    var discovering = false
}

enum ScanFailure: LocalizedError {
    case unreadable(String), unsupported, photoAccess, missingAlbum, tooLarge, ratingUnavailable
    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "无法读取：\(name)"
        case .unsupported: return "文件内容不是支持的照片格式"
        case .photoAccess: return "未获得照片图库访问权限，请在系统设置中允许访问。"
        case .missingAlbum: return "这个相簿已不存在，请重新选择。"
        case .tooLarge: return "单张照片资源超过 256 MB，已跳过。"
        case .ratingUnavailable: return "系统星级筛选需要 macOS 27 或更新版本。请重新选择照片范围。"
        }
    }
}

enum MetadataReader {
    static let extensions: Set<String> = ["jpg","jpeg","png","heic","heif"]
    static func supported(_ type: String) -> Bool {
        guard let uti = UTType(type), !uti.conforms(to:.rawImage) else { return false }
        return [UTType.jpeg, .png, .heic, .heif].contains { uti.conforms(to:$0) }
    }
    static func read(url: URL) throws -> PhotoRecord {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary) else {
            throw ScanFailure.unreadable(url.lastPathComponent)
        }
        return try read(source:source,id:url.path)
    }
    static func read(data: Data, id: String) throws -> PhotoRecord {
        guard let source = CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary) else {
            throw ScanFailure.unreadable(id)
        }
        return try read(source:source,id:id)
    }
    static func read(source: CGImageSource, id: String) throws -> PhotoRecord {
        guard let type = CGImageSourceGetType(source), supported(type as String) else { throw ScanFailure.unsupported }
        guard CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source,0,[kCGImageSourceShouldCache:false] as CFDictionary) as? [String:Any] else {
            throw ScanFailure.unreadable(URL(fileURLWithPath:id).lastPathComponent)
        }
        return parse(props,id:id)
    }
    static func positive(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite && value > 0 ? value : nil
    }
    static func clean(_ raw: Any?) -> String? {
        guard let string = raw as? String else { return nil }
        let result = string.split(whereSeparator: { $0.isWhitespace || $0 == "\0" }).joined(separator:" ")
        return result.isEmpty ? nil : result
    }
    static func parse(_ props: [String:Any], id: String) -> PhotoRecord {
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String:Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary as String] as? [String:Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String:Any] ?? [:]
        // No inferred sensor multiplier: physical focal length never masquerades as equivalent.
        let actual = positive(exif[kCGImagePropertyExifFocalLength as String])
        let equivalent = positive(exif[kCGImagePropertyExifFocalLenIn35mmFilm as String])
        let rawLens = clean(exif[kCGImagePropertyExifLensModel as String]) ?? clean(aux[kCGImagePropertyExifAuxLensModel as String])
        let lensMake = clean(exif[kCGImagePropertyExifLensMake as String])
        var lens = rawLens
        // Retain model/generation; qualify identical model names from different manufacturers.
        if let rawLens, let lensMake, !rawLens.localizedCaseInsensitiveContains(lensMake) {
            lens = "\(lensMake) \(rawLens)"
        }
        return PhotoRecord(id:id,lens:lens,actual:actual,equivalent:equivalent,camera:clean(tiff[kCGImagePropertyTIFFModel as String]))
    }
}

struct AlbumChoice: Identifiable, Sendable {
    let id: String
    let title: String
}

// App-owned scopes are distinct from PhotoKit collection identifiers and titles.
// An album named ★★★★★ remains an album; it is never interpreted as a rating.
enum PhotoScope: Equatable {
    case all, rating(Int), album(String)
    static let ratingPrefix = "focal-statistics:rating:"
    init(id:String) {
        if id.isEmpty { self = .all }
        else if id.hasPrefix(Self.ratingPrefix), let rating = Int(id.dropFirst(Self.ratingPrefix.count)), (0...5).contains(rating) {
            self = .rating(rating)
        } else { self = .album(id) }
    }
    var id: String {
        switch self {
        case .all: return ""
        case .rating(let value): return Self.ratingPrefix + String(value)
        case .album(let id): return id
        }
    }
    static var supportsRatings: Bool {
        if #available(macOS 27, *) { return true }
        return false
    }
    static func ratingChoices(supported:Bool) -> [AlbumChoice] {
        guard supported else { return [] }
        return ([5,4,3,2,1,0]).map { value in
            AlbumChoice(id:PhotoScope.rating(value).id,title:value == 0 ? "未评级照片 · 整个图库" : "\(value) 星照片 · 整个图库")
        }
    }
    func includes(rating:Int) -> Bool {
        if case .rating(let selected) = self { return rating == selected }
        return true
    }
}

enum ScanEngine {
    typealias Update = @Sendable (ScanProgress) async -> Void

    static func folder(_ root: URL, recursive: Bool, update: @escaping Update) async throws -> ScanReport {
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let rootValues = try root.resourceValues(forKeys:[.isDirectoryKey,.isReadableKey])
        guard rootValues.isDirectory == true, rootValues.isReadable != false else { throw ScanFailure.unreadable(root.path) }
        // Force an access check; an empty successful enumeration is different from a denied root.
        _ = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil,options:[.skipsHiddenFiles])
        var report = ScanReport()
        let keys: [URLResourceKey] = [.isRegularFileKey,.isSymbolicLinkKey,.isDirectoryKey,.isPackageKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles,.skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let enumerator = FileManager.default.enumerator(at:root,includingPropertiesForKeys:keys,options:options,errorHandler:{ url,error in
            report.inaccessibleDirectories += 1
            report.issue(url.path,error.localizedDescription)
            return true
        }) else { throw ScanFailure.unreadable(root.path) }
        var files: [URL] = []
        var visited = 0
        await update(ScanProgress(completed:0,total:0,name:root.lastPathComponent,discovering:true))
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            visited += 1
            do {
                let values = try url.resourceValues(forKeys:Set(keys))
                if values.isSymbolicLink == true || values.isPackage == true { enumerator.skipDescendants(); continue }
                if values.isRegularFile == true && MetadataReader.extensions.contains(url.pathExtension.lowercased()) { files.append(url) }
            } catch {
                report.inaccessibleDirectories += 1
                report.issue(url.path,error.localizedDescription)
            }
            if visited % 256 == 0 { await update(ScanProgress(completed:0,total:files.count,name:url.lastPathComponent,discovering:true)) }
        }
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        await update(ScanProgress(completed:0,total:files.count,name:"读取照片信息"))
        var lastUpdate = ProcessInfo.processInfo.systemUptime
        for (index,url) in files.enumerated() {
            try Task.checkCancellation()
            do {
                let record = try autoreleasepool { try MetadataReader.read(url:url) }
                report.records.append(record)
            } catch {
                report.failed += 1; report.issue(url.path,error.localizedDescription)
            }
            report.attempted += 1
            let now = ProcessInfo.processInfo.systemUptime
            if now-lastUpdate > 0.1 || index == files.count-1 {
                await update(ScanProgress(completed:index+1,total:files.count,name:url.lastPathComponent))
                lastUpdate = now
            }
        }
        try Task.checkCancellation()
        return report
    }

    static func albums() async throws -> [AlbumChoice] {
        guard authorized else { throw ScanFailure.photoAccess }
        var result: [AlbumChoice] = []
        let albums = PHAssetCollection.fetchAssetCollections(with:.album,subtype:.any,options:nil)
        albums.enumerateObjects { album,_,_ in
            result.append(AlbumChoice(id:album.localIdentifier,title:album.localizedTitle ?? "未命名相簿"))
        }
        return [AlbumChoice(id:"",title:"所有照片")]
            + PhotoScope.ratingChoices(supported:PhotoScope.supportsRatings)
            + result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    static var authorized: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for:.readWrite)
        return status == .authorized || status == .limited
    }
    static func photoAssets(albumID:String, update:@escaping Update) async throws -> [PHAsset] {
        guard authorized else { throw ScanFailure.photoAccess }
        let scope = PhotoScope(id:albumID)
        if case .rating = scope, !PhotoScope.supportsRatings { throw ScanFailure.ratingUnavailable }
        await update(ScanProgress(completed:0,total:0,name:"正在筛选照片",discovering:true))
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format:"mediaType == %d",PHAssetMediaType.image.rawValue)
        let assets: PHFetchResult<PHAsset>
        switch scope {
        case .all, .rating: assets = PHAsset.fetchAssets(with:options)
        case .album(let id):
            guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers:[id],options:nil).firstObject else { throw ScanFailure.missingAlbum }
            assets = PHAsset.fetchAssets(in:album,options:options)
        }
        var selected: [PHAsset] = []
        var seen = Set<String>()
        for index in 0..<assets.count {
            try Task.checkCancellation()
            let asset = assets.object(at:index)
            guard seen.insert(asset.localIdentifier).inserted else { continue }
            if case .rating = scope {
                // Read the public library rating, not EXIF/XMP or favorites. Filtering
                // the property avoids relying on unsupported fetch predicate keys.
                if #available(macOS 27, *) {
                    guard scope.includes(rating:asset.rating.rawValue) else { continue }
                } else { throw ScanFailure.ratingUnavailable }
            }
            selected.append(asset)
        }
        try Task.checkCancellation()
        return selected
    }
    static func photos(albumID: String, network: Bool, update: @escaping Update) async throws -> ScanReport {
        let assets = try await photoAssets(albumID:albumID,update:update)
        var report = ScanReport()
        await update(ScanProgress(completed:0,total:assets.count,name:"读取照片信息"))
        for (index,asset) in assets.enumerated() {
            try Task.checkCancellation()
            report.attempted += 1
            let resources = PHAssetResource.assetResources(for:asset)
            // A Live Photo's pairedVideo is never read. Prefer original static resources.
            let resource = [.photo,.alternatePhoto,.fullSizePhoto].lazy.compactMap { (kind:PHAssetResourceType) in
                resources.first { $0.type == kind && MetadataReader.supported($0.uniformTypeIdentifier) }
            }.first
            if let resource {
                do {
                    let request = PhotoDataRequest()
                    let data = try await request.load(resource:resource,network:network)
                    try Task.checkCancellation()
                    let record = try autoreleasepool { try MetadataReader.read(data:data,id:asset.localIdentifier) }
                    report.records.append(record)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    let error = error as NSError
                    if error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.Code.networkAccessRequired.rawValue {
                        report.cloud += 1; report.issue(resource.originalFilename,"原件在 iCloud，尚未下载")
                    } else {
                        report.failed += 1; report.issue(resource.originalFilename,error.localizedDescription)
                    }
                }
            } else {
                report.unsupported += 1
                report.issue(resources.first?.originalFilename ?? "照片","没有支持的 JPG、PNG 或 HEIC 静态资源")
            }
            await update(ScanProgress(completed:index+1,total:assets.count,name:resource?.originalFilename ?? "照片"))
        }
        try Task.checkCancellation()
        return report
    }
}

// Cancellation and completion race through one lock, so the continuation resumes exactly once.
final class PhotoDataRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data,Error>?
    private var requestID: PHAssetResourceDataRequestID?
    private var done = false
    private var buffer = Data()
    private let manager = PHAssetResourceManager.default()

    func load(resource:PHAssetResource,network:Bool) async throws -> Data {
        try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if done { lock.unlock(); continuation.resume(throwing:CancellationError()); return }
                self.continuation = continuation
                lock.unlock()
                let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = network
                let identifier = manager.requestData(for:resource,options:options,dataReceivedHandler:{ [self] chunk in
                    lock.lock()
                    guard !done else { lock.unlock(); return }
                    if buffer.count + chunk.count > 256*1024*1024 {
                        lock.unlock(); finish(error:ScanFailure.tooLarge,cancelRequest:true); return
                    }
                    buffer.append(chunk); lock.unlock()
                },completionHandler:{ [self] error in finish(error:error,cancelRequest:false) })
                lock.lock(); requestID = identifier; let wasDone = done; lock.unlock()
                if wasDone { manager.cancelDataRequest(identifier) }
            }
        },onCancel:{ self.finish(error:CancellationError(),cancelRequest:true) })
    }
    private func finish(error:Error?,cancelRequest:Bool) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let continuation = self.continuation; self.continuation = nil
        let data = buffer; buffer = Data(); let identifier = requestID
        lock.unlock()
        if cancelRequest, let identifier { manager.cancelDataRequest(identifier) }
        if let error { continuation?.resume(throwing:error) } else { continuation?.resume(returning:data) }
    }
}
