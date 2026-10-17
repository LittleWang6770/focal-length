import Foundation
import SwiftUI
import AppKit
import Photos

enum Phase: String, CaseIterable {
    case empty = "空状态", running = "扫描中", complete = "已完成", cancelled = "已停止", failed = "读取失败"
}
struct StatRow: Identifiable {
    let name: String
    let count: Int
    var id: String { name }
}

@MainActor final class AppModel: ObservableObject {
    @Published var notice: String?
    @Published var source = 0
    @Published var recursive = true
    @Published var selectedAlbumID = ""
    @Published var albums = [AlbumChoice(id:"",title:"所有照片")]
    @Published var chosen = false
    @Published var connecting = false
    @Published var phase = Phase.empty
    @Published var progress = 0.0
    @Published var remaining = "估算中"
    @Published var equivalent = true
    @Published var standard = true
    @Published var selectedLens: String?
    @Published var allFocals = false
    @Published var allowNetwork = true
    @Published var demo = false
    @Published var folders: [FolderSource] = []
    @Published var selectedFolderIDs = Set<UUID>()
    @Published private var demoFolders: [FolderSource] = []
    @Published var report = ScanReport()
    @Published var currentFile = ""
    @Published var completed = 0
    @Published var total = 0
    @Published var discovering = false
    @Published var errorMessage = ""
    private var task: Task<Void,Never>?
    private var clockTask: Task<Void,Never>?
    private var generation = UUID()
    private var readingStarted: Double?
    private var lastAdvance = 0.0
    private let defaults: UserDefaults

    static let anchors: [Double] = [14,16,20,24,28,35,40,50,70,85,105,135,200,300,400,600]
    static let zoom = "FE 24–70mm F2.8 GM II"
    static let prime = "FE 35mm F1.4 GM"
    static let portrait = "FE 85mm F1.4 GM"
    static let unknown = "未识别镜头"
    init(restore:Bool = true,defaults:UserDefaults = .standard) {
        self.defaults = defaults
        guard restore else { return }
        do { folders = try FolderAccess.restore(defaults:defaults); chosen = !folders.isEmpty }
        catch { errorMessage = "上次的文件夹访问已失效，请重新选择。" }
        if let saved = defaults.object(forKey:"recursive") as? Bool { recursive = saved }
    }
    static let samples: [PhotoRecord] = {
        var values: [PhotoRecord] = []
        func add(_ lens:String?,_ eq:Double?,_ count:Int,actual:Double? = nil) {
            for _ in 0..<count { values.append(PhotoRecord(id:String(values.count),lens:lens,actual:actual ?? eq,equivalent:eq,camera:"示例相机")) }
        }
        add(zoom,24,270); add(zoom,28,100); add(zoom,33,110); add(zoom,49,140)
        add(zoom,70,90); add(zoom,nil,34); add(prime,35,300); add(portrait,85,120)
        add(nil,24,10,actual:6.86); add(nil,nil,26)
        return values
    }()
    var demoRecords: [PhotoRecord] {
        if source == 0 && !recursive { return Self.samples.enumerated().filter { $0.offset % 4 == 0 }.map(\.element) }
        if source == 1 && selectedAlbumID == "demo-album" { return Self.samples.enumerated().filter { $0.offset % 3 == 0 }.map(\.element) }
        return Self.samples
    }
    var base: [PhotoRecord] { report.records }
    var filtered: [PhotoRecord] {
        guard let selectedLens else { return base }
        return base.filter { ($0.lens ?? Self.unknown) == selectedLens }
    }
    var valid: Int { filtered.filter { (equivalent ? $0.equivalent : $0.actual) != nil }.count }
    var lensCount: Int { Set(filtered.compactMap(\.lens)).count }
    var hasResults: Bool { phase == .complete }
    var isRunning: Bool { phase == .running }
    var folderRows: [FolderSource] { demo ? demoFolders : folders }
    var folderPath: String { folderRows.map { $0.url.path }.joined(separator:"\n") }
    var folderName: String {
        if folderRows.isEmpty { return "尚未添加文件夹" }
        return folderRows.count == 1 ? folderRows[0].url.lastPathComponent : "\(folderRows.count) 个文件夹"
    }
    static var sampleFolders: [FolderSource] {
        [FolderSource(url:URL(fileURLWithPath:"/示例/本机磁盘/旅行照片")),
         FolderSource(url:URL(fileURLWithPath:"/示例/外置磁盘/人像照片"))]
    }
    var sourceName: String {
        let name = source == 0 ? folderName : (albums.first { $0.id == selectedAlbumID }?.title ?? "所有照片")
        return name + (demo ? " · 示例数据" : "")
    }
    var lensRows: [StatRow] {
        Dictionary(grouping:base,by:{ $0.lens ?? Self.unknown })
            .map { StatRow(name:$0.key,count:$0.value.count) }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }
    static func bucket(_ value:Double,standard:Bool) -> Double {
        guard standard else { return max(1,value.rounded(.toNearestOrAwayFromZero)) }
        guard value >= anchors[0], value <= anchors[anchors.count-1] else { return value }
        return anchors.min {
            let lhs = max(value/$0,$0/value), rhs = max(value/$1,$1/value)
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }!
    }
    var focalRows: [StatRow] {
        let values = filtered.compactMap { equivalent ? $0.equivalent : $0.actual }
        return Dictionary(grouping:values,by:{ Self.bucket($0,standard:standard) })
            .sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }
            .map { StatRow(name:String(format:"%g mm",$0.key),count:$0.value.count) }
    }
    var visibleFocals: [StatRow] { allFocals ? focalRows : Array(focalRows.prefix(5)) }
    func percent(_ count:Int,total:Int? = nil) -> String {
        String(format:"%.1f%%",Double(count)/Double(max(total ?? filtered.count,1))*100)
    }
    func reset() {
        generation = UUID(); task?.cancel(); task = nil; clockTask?.cancel(); clockTask = nil
        phase = .empty; progress = 0; remaining = "估算中"; selectedLens = nil
        report = ScanReport(); completed = 0; total = 0; currentFile = ""; errorMessage = ""
        discovering = false; readingStarted = nil
    }
    func sourceChanged() {
        reset()
        selectedFolderIDs = []
        if demo {
            albums = [AlbumChoice(id:"",title:"所有照片"),AlbumChoice(id:"demo-album",title:"周末散步")]
            chosen = false; return
        }
        chosen = source == 0 && !folders.isEmpty
        if source == 1 && ScanEngine.authorized { connectPhotos() }
    }
    func scopeChanged() {
        reset()
        if !demo { defaults.set(recursive,forKey:"recursive") }
    }
    func selectSource() {
        if demo { reset(); if source == 0 { demoFolders = Self.sampleFolders }; chosen = true; return }
        if source == 1 { connectPhotos(); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.title = "添加需要统计的照片文件夹"; panel.prompt = "添加文件夹"; panel.directoryURL = folders.last?.url
        panel.begin { [weak self] result in
            guard result == .OK else { return }
            self?.addFolders(panel.urls)
        }
    }
    func addFolders(_ urls:[URL],persist:Bool = true) {
        guard !urls.isEmpty, !isRunning else { return }
        reset(); demo = false; source = 0; selectedFolderIDs = []
        for url in urls {
            let added = persist ? FolderAccess.make(url) : FolderSource(url:url)
            if let index = folders.firstIndex(where:{ FolderAccess.identity($0.url) == FolderAccess.identity(url) }) {
                // Re-adding refreshes an expired permission without duplicating the row.
                folders[index] = FolderSource(url:added.url,id:folders[index].id,bookmark:added.bookmark,accessIssue:added.accessIssue)
            } else { folders.append(added) }
        }
        chosen = !folders.isEmpty
        if persist { saveFolders() }
        if folders.contains(where:{ $0.bookmark == nil && $0.accessIssue != nil }) {
            notice = "部分文件夹的权限未能保存；本次仍可统计，下次使用时请重新添加。"
        }
    }
    func removeSelectedFolders(persist:Bool = true) {
        guard !isRunning, !selectedFolderIDs.isEmpty else { return }
        reset()
        if demo { demoFolders.removeAll { selectedFolderIDs.contains($0.id) } }
        else { folders.removeAll { selectedFolderIDs.contains($0.id) }; if persist { saveFolders() } }
        selectedFolderIDs = []; chosen = !folderRows.isEmpty
    }
    private func saveFolders() {
        do { try FolderAccess.save(folders,defaults:defaults) }
        catch { notice = "文件夹列表未能保存，下次启动时请重新添加。\n\(error.localizedDescription)" }
    }
    func connectPhotos() {
        connecting = true
        Task {
            defer { connecting = false }
            var status = PHPhotoLibrary.authorizationStatus(for:.readWrite)
            if status == .notDetermined {
                status = await withCheckedContinuation { continuation in
                    PHPhotoLibrary.requestAuthorization(for:.readWrite) { continuation.resume(returning:$0) }
                }
            }
            guard source == 1, !demo else { return }
            guard status == .authorized || status == .limited else {
                chosen = false; errorMessage = ScanFailure.photoAccess.localizedDescription; phase = .failed; return
            }
            do {
                albums = try await ScanEngine.albums()
                if !albums.contains(where:{ $0.id == selectedAlbumID }) { selectedAlbumID = "" }
                chosen = true
                if phase == .failed { reset() }
            } catch { errorMessage = error.localizedDescription; phase = .failed }
        }
    }
    func show(_ newPhase:Phase) {
        reset(); demo = true
        selectedFolderIDs = []; demoFolders = newPhase == .empty ? [] : Self.sampleFolders
        albums = [AlbumChoice(id:"",title:"所有照片"),AlbumChoice(id:"demo-album",title:"周末散步")]
        chosen = newPhase != .empty
        if newPhase == .running { start(); return }
        phase = newPhase; progress = newPhase == .complete ? 1 : 0
        if newPhase == .complete { report.records = demoRecords; report.attempted = report.records.count }
        if newPhase == .failed { errorMessage = "来源可能已移动或访问权限已失效，请重新选择。（示例场景）"; progress = 0.42 }
        if newPhase == .cancelled { progress = 0.42 }
    }
    func exitDemo() { reset(); demo = false; selectedAlbumID = ""; sourceChanged() }
    func start() {
        guard chosen, !isRunning else { return }
        reset(); phase = .running; let token = generation
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds:1_000_000_000) } catch { return }
                self?.updateEstimate()
            }
        }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result: ScanReport
                if self.demo {
                    let records = self.demoRecords
                    for step in 1...40 {
                        try await Task.sleep(nanoseconds:500_000_000)
                        self.accept(ScanProgress(completed:records.count*step/40,total:records.count,name:"示例照片 DSC_\(step).JPG"),token:token)
                    }
                    result = ScanReport(records:records,attempted:records.count)
                } else if self.source == 0 {
                    self.folders = self.folders.map(FolderAccess.refresh)
                    self.saveFolders()
                    result = try await ScanEngine.folders(self.folders.map(\.url),recursive:self.recursive) { [weak self] update in await self?.accept(update,token:token) }
                } else {
                    result = try await ScanEngine.photos(albumID:self.selectedAlbumID,network:self.allowNetwork) { [weak self] update in await self?.accept(update,token:token) }
                }
                try Task.checkCancellation()
                guard generation == token else { return }
                if self.source == 0 && !self.demo {
                    for index in self.folders.indices where result.unavailableFolders.contains(self.folders[index].url.path) {
                        self.folders[index].accessIssue = "无法访问，请连接磁盘；权限失效时请重新添加。"
                    }
                }
                report = result; phase = .complete; progress = 1; remaining = "已完成"; clockTask?.cancel()
            } catch is CancellationError { /* stop/reset owns the terminal state */ }
            catch {
                guard generation == token else { return }
                errorMessage = error.localizedDescription; phase = .failed; remaining = "读取失败"; clockTask?.cancel()
            }
        }
    }
    func accept(_ update:ScanProgress,token:UUID) {
        guard token == generation, phase == .running else { return }
        let now = ProcessInfo.processInfo.systemUptime
        discovering = update.discovering
        if !discovering && readingStarted == nil { readingStarted = now; lastAdvance = now }
        if update.completed > completed { lastAdvance = now }
        completed = update.completed; total = update.total; currentFile = update.name
        progress = discovering || total == 0 ? 0 : min(0.999,Double(completed)/Double(total))
        updateEstimate()
    }
    func updateEstimate() {
        guard isRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard !discovering, let started = readingStarted, completed >= 3, now-started >= 1 else { remaining = "估算中"; return }
        guard now-lastAdvance < 8 else { remaining = "重新估算中"; return }
        let seconds = max(1,Int(ceil((now-started)/Double(completed)*Double(max(0,total-completed)))))
        remaining = seconds >= 60 ? "约 \(seconds/60) 分 \(seconds%60) 秒" : "约 \(seconds) 秒"
    }
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; clockTask?.cancel(); clockTask = nil
        phase = .cancelled; remaining = "已停止"
    }
    static func csvField(_ value:String) -> String {
        // Spreadsheet apps interpret leading formulas even in quoted fields.
        let first = value.trimmingCharacters(in:.whitespacesAndNewlines).first
        let protected = first.map { "=+-@".contains($0) } == true ? "'"+value : value
        return "\"" + protected.replacingOccurrences(of:"\"",with:"\"\"") + "\""
    }
    func exportCSV() -> String {
        var lines: [[String]] = [["数据来源",demo ? "合成示例数据" : sourceName],
            ["扫描范围",source == 0 ? (recursive ? "包含所有子文件夹" : "当前文件夹") : sourceName],
            ["镜头筛选",selectedLens ?? "全部镜头"],["分组",standard ? "标准焦段" : "1 mm 四舍五入"],
        ]
        if source == 0 { for folder in folderRows { lines.append(["来源文件夹",folder.url.path]) } }
        lines.append(["类型","名称","数量","分母","占比"])
        for row in focalRows { lines.append([equivalent ? "等效焦段" : "实际焦距",row.name,String(row.count),String(filtered.count),percent(row.count)]) }
        lines.append(["焦段","缺少焦段",String(filtered.count-valid),String(filtered.count),percent(filtered.count-valid)])
        for row in lensRows { lines.append(["镜头",row.name,String(row.count),String(base.count),percent(row.count,total:base.count)]) }
        lines.append(["未分析","读取失败",String(report.failed)])
        lines.append(["未分析","iCloud 待下载",String(report.cloud)])
        lines.append(["未分析","格式不支持",String(report.unsupported)])
        lines.append(["未分析","无法访问的目录或条目",String(report.inaccessibleDirectories)])
        return "\u{FEFF}" + lines.map { $0.map(Self.csvField).joined(separator:",") }.joined(separator:"\r\n")
    }
    func showIssues() {
        notice = "读取失败 \(report.failed) 张；iCloud 待下载 \(report.cloud) 张；格式不支持 \(report.unsupported) 张；无法访问的目录或条目 \(report.inaccessibleDirectories) 个。\n\n" + report.issues.prefix(15).map { "\($0.name)\n\($0.reason)" }.joined(separator:"\n\n") + (report.issues.count > 15 ? "\n\n更多记录请导出诊断列表。" : "")
    }
    func issuesCSV() -> String {
        let rows = [["文件或资产","原因"]] + report.issues.map { [$0.name,$0.reason] }
        return "\u{FEFF}" + rows.map { $0.map(Self.csvField).joined(separator:",") }.joined(separator:"\r\n")
    }
}
