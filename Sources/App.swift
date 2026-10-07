import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @StateObject var model = AppModel()
    var body: some View {
        VStack(spacing:0) {
            header
            HStack(alignment:.top,spacing:20) {
                VStack(spacing:12) {
                    ScrollView {
                        VStack(spacing:16) { sourceCard; optionsCard }.padding(1)
                    }
                    actions
                }.frame(width:260)
                ScrollView {
                    if model.hasResults { dashboard.padding(1) }
                    else { emptyPanel.padding(1) }
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }.padding(.horizontal,28).padding(.bottom,20)
            progressFooter
        }
        .font(.system(size:13)).foregroundStyle(Theme.ink)
        .background(Theme.background).tint(Theme.accent).preferredColorScheme(.light)
        .frame(minWidth:980,minHeight:700)
        .alert("提示",isPresented:Binding(get:{model.notice != nil},set:{if !$0 {model.notice = nil}})) {
            Button("知道了") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }

    var header: some View {
        ZStack(alignment:.topTrailing) {
            VStack(spacing:6) {
                Image(nsImage:NSImage(named:"AppIcon") ?? NSApp.applicationIconImage)
                    .resizable().interpolation(.high).scaledToFit()
                    .frame(width:54,height:54).accessibilityLabel("焦段统计图标")
                Text("焦段统计").font(.system(size:26,weight:.semibold))
                Text("看看你常用的焦段，和陪你拍照的镜头。")
                    .font(.system(size:12)).foregroundStyle(Theme.secondary)
            }.frame(maxWidth:.infinity)
            VStack(alignment:.trailing,spacing:8) {
                Text(model.demo ? "示例预览 · 合成数据" : "只读统计 · 本机处理").font(.system(size:11)).foregroundStyle(Theme.secondary)
                Menu("示例与帮助") {
                    if model.demo { Button("退出示例，统计真实照片") { model.exitDemo() }; Divider() }
                    Menu("预览示例状态") {
                        ForEach(Phase.allCases,id:\.self) { phase in
                            Button(phase.rawValue) { model.show(phase) }
                        }
                    }
                    Divider()
                    Button("最小窗口 · 980 × 700") { resize(width:980,height:700) }
                    Button("默认窗口 · 1180 × 830") { resize(width:1180,height:830) }
                    Divider()
                    Button("关于统计口径") { model.notice = "标准焦段按比例距离归类，超出 14–600 mm 的值保留原值；精确模式按 1 mm 分组。\n\n等效焦距只采用照片中明确记录的数值。缺失时可切换实际焦距查看。\n\n占比以成功读取的照片数为分母，无 EXIF 的照片仍计入总数。Live Photo 只统计静态照片，视频不计入；文件夹中的多份导出副本分别计数。\n\nApple 相册统计当前系统照片图库及所选范围；默认允许从 iCloud 下载原件，可在照片来源中关闭。" }
                }.fixedSize().menuStyle(.borderlessButton).disabled(model.isRunning || model.connecting)
            }
        }.padding(.horizontal,30).padding(.top,16).padding(.bottom,24)
    }
    var sourceCard: some View {
        Card {
            StepHeading(number:"1",title:"照片来源")
            Picker("来源",selection:$model.source) {
                Text("本地文件夹").tag(0); Text("Apple 相册").tag(1)
            }.pickerStyle(.segmented).labelsHidden()
                .onChange(of:model.source) { _ in model.sourceChanged() }
            VStack(alignment:.leading,spacing:8) {
                Label(model.source == 0 ? model.folderName : "Apple 相册",systemImage:model.source == 0 ? "folder" : "photo.on.rectangle")
                    .font(.system(size:13,weight:.medium))
                    .lineLimit(1).truncationMode(.middle)
                if model.source == 0 {
                    Text(model.folderPath)
                        .font(.system(size:12)).foregroundStyle(Theme.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(model.folderPath)
                } else {
                    Text(model.connecting ? "正在连接照片图库…" : model.chosen ? (model.demo ? "已载入示例图库" : "已连接系统照片图库") : "首次使用时允许访问照片图库")
                        .font(.system(size:12)).foregroundStyle(Theme.secondary)
                }
            }
            Button(model.source == 0 ? (model.demo ? "选择示例文件夹…" : "选择文件夹…") : (model.demo ? "连接示例图库…" : "连接照片图库…")) { model.selectSource() }
                .buttonStyle(ActionStyle())
            if model.source == 1 && model.chosen {
                Picker("照片范围",selection:$model.selectedAlbumID) {
                    ForEach(model.albums) { Text($0.title).tag($0.id) }
                }.onChange(of:model.selectedAlbumID) { _ in model.reset() }
                if case .rating = PhotoScope(id:model.selectedAlbumID) {
                    Text("按系统星级筛选整个图库，仅统计照片。")
                        .font(.system(size:12)).foregroundStyle(Theme.secondary)
                }
            }
            if model.source == 1 {
                Toggle("允许从 iCloud 下载原件",isOn:$model.allowNetwork)
                Text(model.allowNetwork ? "云端原件会按需下载，可能需要较多时间和流量。" : "仅统计本机可读取的照片。")
                    .font(.system(size:11)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal:false,vertical:true)
            }
        }.disabled(model.isRunning || model.connecting)
    }
    var optionsCard: some View {
        Card {
            StepHeading(number:"2",title:"统计方式")
            if model.source == 0 {
                Picker("扫描范围",selection:$model.recursive) {
                    Text("当前文件夹").tag(false)
                    Text("包含所有子文件夹").tag(true)
                }.pickerStyle(.radioGroup).labelsHidden()
                    .onChange(of:model.recursive) { _ in model.scopeChanged() }
            } else {
                Text("按所选范围统计，Live Photo 计为一张。")
                    .foregroundStyle(Theme.secondary).font(.system(size:12))
            }
            Divider()
            Text("焦段分组").font(.system(size:12,weight:.medium))
            Picker("焦段分组",selection:$model.standard) {
                Text("标准焦段").tag(true); Text("精确焦距").tag(false)
            }.pickerStyle(.segmented).labelsHidden()
            Text(model.standard ? "相近焦距归为一组，如 49、51 → 50 mm。" : "按 1 mm 四舍五入，保留变焦使用细节。")
                .font(.system(size:12)).foregroundStyle(Theme.secondary).fixedSize(horizontal:false,vertical:true)
            Divider()
            Picker("焦距口径",selection:$model.equivalent) {
                Text("全画幅等效").tag(true); Text("实际焦距").tag(false)
            }
            Toggle("显示全部焦段",isOn:$model.allFocals)
            Text("JPG / JPEG · PNG · HEIC / HEIF\nLive Photo 只统计静态照片。")
                .font(.system(size:11)).foregroundStyle(Theme.secondary)
        }.disabled(model.isRunning)
    }
    var actions: some View {
        VStack(spacing:10) {
            if model.isRunning {
                Button("停止统计") { model.stop() }.buttonStyle(ActionStyle())
            } else {
                Button(model.hasResults ? "重新统计" : "开始统计") { model.start() }
                    .buttonStyle(ActionStyle(primary:true)).disabled(!model.chosen || model.connecting)
            }
            Text(model.demo ? "示例模式，不读取你的照片。" : "仅仅读取照片，不会修改原件。")
                .font(.system(size:11)).foregroundStyle(Theme.secondary)
        }
    }
    var emptyPanel: some View {
        Card {
            VStack(spacing:14) {
                Image(systemName:model.phase == .failed ? "exclamationmark.triangle" : model.phase == .running ? "chart.bar.xaxis" : "camera.metering.center.weighted")
                    .font(.system(size:42,weight:.ultraLight)).foregroundStyle(Theme.accent)
                Text(emptyTitle).font(.system(size:20,weight:.medium))
                Text(emptyDetail).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth:360)
                if model.phase == .empty && !model.chosen {
                    Button("查看示例看板") { model.show(.complete) }.buttonStyle(.link).padding(.top,6)
                }
                if model.phase == .failed {
                    Button("重新选择来源") { model.selectSource() }.buttonStyle(.link)
                    if model.source == 1 && !model.demo {
                        Button("打开照片权限设置") { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!) }.buttonStyle(.link)
                    }
                }
                HStack(spacing:32) {
                    Label("焦段分布",systemImage:"chart.bar")
                    Label("镜头占比",systemImage:"camera.aperture")
                }.font(.system(size:12)).foregroundStyle(Theme.secondary).padding(.top,28)
            }.frame(maxWidth:.infinity).frame(minHeight:450)
        }
    }
    var emptyTitle: String {
        switch model.phase {
        case .empty: return model.chosen ? "准备好看看拍摄习惯了" : "从一组照片开始"
        case .running: return "正在整理照片的拍摄信息"
        case .cancelled: return "统计已停止"
        case .failed: return "暂时无法读取这个来源"
        case .complete: return ""
        }
    }
    var emptyDetail: String {
        switch model.phase {
        case .empty: return !model.errorMessage.isEmpty ? model.errorMessage : model.chosen ? "点击「开始统计」，查看这组照片的焦段与镜头分布。" : "选择本地文件夹或 Apple 相册，\n让每一支镜头的使用情况一目了然。"
        case .running: return model.discovering ? "正在查找支持的照片，照片较多时可能需要一些时间。" : "正在读取拍摄信息。完成后会显示焦段分布和镜头使用占比。"
        case .cancelled: return "本次扫描尚未完成。可以调整来源，或重新开始统计。"
        case .failed: return model.errorMessage
        case .complete: return ""
        }
    }
    var dashboard: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                VStack(alignment:.leading,spacing:4) {
                    Text("使用概览").font(.system(size:19,weight:.semibold))
                    Text(model.sourceName + (model.source == 0 ? (model.recursive ? " / 含子文件夹" : " / 仅当前层") : ""))
                        .font(.system(size:12)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button { export() } label: { Label("导出 CSV",systemImage:"square.and.arrow.up") }
            }
            HStack(spacing:12) {
                metric("统计照片", "\(model.filtered.count)", "张")
                metric("可用焦段", "\(model.valid)", model.percent(model.valid))
                metric("识别镜头", "\(model.lensCount)", "支")
            }
            if model.report.failed + model.report.cloud + model.report.unsupported + model.report.inaccessibleDirectories > 0 {
                Card {
                    Text("另有 \(model.report.failed) 张读取失败 · \(model.report.cloud) 张 iCloud 待下载 · \(model.report.unsupported) 张格式不支持")
                        .font(.system(size:12)).fixedSize(horizontal:false,vertical:true)
                    HStack {
                        Button("查看未分析原因") { model.showIssues() }.buttonStyle(.link)
                        Spacer()
                        Button("导出诊断列表") { export(issues:true) }.buttonStyle(.link)
                    }.font(.system(size:12))
                }
            }
            if model.base.isEmpty {
                Card {
                    Text("没有可统计的照片").font(.system(size:15,weight:.semibold))
                    Text("可以更换来源、包含子文件夹，或查看未分析的原因。")
                        .font(.system(size:12)).foregroundStyle(Theme.secondary)
                }
            }
            if let lens = model.selectedLens {
                HStack {
                    Text("正在查看：\(lens)").font(.system(size:12)).lineLimit(1)
                    Spacer()
                    Button("显示全部照片") { model.selectedLens = nil }.buttonStyle(.link)
                }.padding(10).background(Theme.selected,in:RoundedRectangle(cornerRadius:7))
            }
            HStack(alignment:.top,spacing:16) {
                focalCard.frame(maxWidth:.infinity)
                lensCard.frame(maxWidth:.infinity)
            }
            Card {
                HStack(alignment:.top,spacing:14) {
                    Image(systemName:"lightbulb").font(.system(size:18,weight:.light)).foregroundStyle(Theme.accent)
                    VStack(alignment:.leading,spacing:6) {
                        Text(insight).font(.system(size:13,weight:.medium))
                        Text("点击右侧镜头，可查看这支镜头内的焦段分布。")
                            .font(.system(size:12)).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength:0)
                }
            }
            Text("占比以当前范围内的照片总数为分母；缺失信息单独列出。")
                .font(.system(size:11)).foregroundStyle(Theme.secondary)
        }
    }
    func metric(_ title:String,_ value:String,_ suffix:String) -> some View {
        Card {
            Text(title).font(.system(size:12)).foregroundStyle(Theme.secondary)
            HStack(alignment:.firstTextBaseline,spacing:7) {
                Text(value).font(.system(size:28,weight:.medium,design:.rounded)).monospacedDigit()
                Text(suffix).font(.system(size:12)).foregroundStyle(Theme.secondary)
            }
        }
    }
    var focalCard: some View {
        Card {
            HStack {
                Text("焦段分布").font(.system(size:15,weight:.semibold))
                Spacer()
                Menu(model.equivalent ? "等效焦距" : "实际焦距") {
                    Button("全画幅等效焦距") { model.equivalent = true }
                    Button("实际焦距") { model.equivalent = false }
                }.font(.system(size:11)).menuStyle(.borderlessButton).fixedSize()
            }
            Text(model.standard ? "归入标准焦段，范围外保留原值" : "按 1 mm 分组")
                .font(.system(size:11)).foregroundStyle(Theme.secondary)
            VStack(spacing:13) {
                if model.focalRows.isEmpty {
                    Text(model.equivalent ? "照片未记录可用的等效焦距。可以切换实际焦距查看。" : "这些照片没有记录实际焦距。")
                        .font(.system(size:12)).foregroundStyle(Theme.secondary).fixedSize(horizontal:false,vertical:true)
                }
                ForEach(model.visibleFocals) { row in
                    VStack(spacing:6) {
                        HStack {
                            Text(row.name).fontWeight(.medium)
                            Spacer()
                            Text("\(row.count) 张").foregroundStyle(Theme.secondary)
                            Text(model.percent(row.count)).frame(width:48,alignment:.trailing).monospacedDigit()
                        }.font(.system(size:12))
                        Bar(fraction:Double(row.count)/Double(max(model.filtered.count,1)))
                    }
                }
            }
            HStack {
                Text("缺少焦段 \(model.filtered.count-model.valid) 张")
                Spacer(minLength:2)
                if model.focalRows.count > 5 {
                    Button(model.allFocals ? "收起" : "全部 \(model.focalRows.count) 组") { model.allFocals.toggle() }.buttonStyle(.link)
                }
            }.font(.system(size:11)).foregroundStyle(Theme.secondary)
        }
    }
    var lensCard: some View {
        Card {
            Text("镜头使用").font(.system(size:15,weight:.semibold))
            Text("占来源内全部 \(model.base.count) 张照片")
                .font(.system(size:11)).foregroundStyle(Theme.secondary)
            VStack(spacing:6) {
                ForEach(model.lensRows) { row in
                    Button {
                        model.selectedLens = model.selectedLens == row.name ? nil : row.name
                    } label: {
                        VStack(alignment:.leading,spacing:7) {
                            Text(row.name).font(.system(size:12,weight:.medium)).lineLimit(2).multilineTextAlignment(.leading)
                            HStack {
                                Text("\(row.count) 张")
                                Spacer()
                                Text(model.percent(row.count,total:model.base.count)).monospacedDigit()
                            }.font(.system(size:11)).foregroundStyle(Theme.secondary)
                            Bar(fraction:Double(row.count)/Double(max(model.base.count,1)),muted:row.name == AppModel.unknown)
                        }.padding(9).contentShape(Rectangle())
                            .background(model.selectedLens == row.name ? Theme.selected : .clear,in:RoundedRectangle(cornerRadius:7))
                    }.buttonStyle(.plain).help("查看 \(row.name) 的焦段分布")
                }
            }.padding(.horizontal,-9)
        }
    }
    var insight: String {
        guard let top = model.focalRows.first else { return "这组照片缺少可用的焦段信息。" }
        return "你最常用的是 \(top.name)\(model.standard ? " 附近" : "")，占当前照片的 \(model.percent(top.count))。"
    }
    var progressFooter: some View {
        VStack(spacing:9) {
            HStack(spacing:16) {
                if model.isRunning && model.discovering {
                    ProgressView().progressViewStyle(.linear)
                } else {
                    Bar(fraction:model.progress,muted:model.phase == .cancelled || model.phase == .failed)
                }
                Text(model.isRunning ? "剩余：\(model.remaining)" : footerTitle)
                    .font(.system(size:12)).foregroundStyle(Theme.secondary).frame(width:150,alignment:.trailing)
            }
            HStack {
                Text(footerDetail).lineLimit(1).truncationMode(.middle).help(footerDetail)
                Spacer()
                Text(model.demo ? "合成数据 · 示例预览" : "本机处理 · 只读统计")
            }.font(.system(size:11)).foregroundStyle(Theme.secondary)
        }.padding(.horizontal,30).padding(.vertical,15)
            .background(.white).overlay(alignment:.top) { Rectangle().fill(Theme.border).frame(height:1) }
    }
    var footerTitle: String {
        switch model.phase {
        case .empty:return "等待开始"
        case .running:return "估算中"
        case .complete:return "统计完成"
        case .cancelled:return "已停止"
        case .failed:return "读取失败"
        }
    }
    var footerDetail: String {
        if model.isRunning { return model.discovering ? "正在查找照片 · 已发现 \(model.total) 张 · \(model.currentFile)" : "已处理 \(model.completed) / \(model.total) 张 · \(model.currentFile)" }
        if model.phase == .complete { return "已统计 \(model.base.count) 张\(model.demo ? "示例" : "")照片 · \(model.report.failed) 张读取失败 · \(model.report.cloud) 张待下载" }
        if model.phase == .cancelled { return "本次扫描未完成，未生成完整统计。" }
        if model.phase == .failed { return "访问来源失败，请重新选择。" }
        return "支持 JPG、JPEG、PNG、HEIC / HEIF 和 Live Photo"
    }
    func export(issues:Bool = false) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = issues ? "焦段统计-诊断列表.csv" : (model.demo ? "焦段统计-合成示例.csv" : "焦段统计.csv")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try (issues ? model.issuesCSV() : model.exportCSV()).write(to:url,atomically:true,encoding:.utf8) }
            catch { model.notice = "导出失败：\(error.localizedDescription)" }
        }
    }
    func resize(width:CGFloat,height:CGFloat) {
        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.contentView != nil })
        window?.setContentSize(NSSize(width:width,height:height))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification:Notification) {
        if let icon = NSImage(named:"AppIcon") { NSApp.applicationIconImage = icon }
        NSApp.setActivationPolicy(.regular)
        let content = MainView()
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:1180,height:830),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "焦段统计"
        window.contentMinSize = NSSize(width:980,height:700)
        window.contentView = NSHostingView(rootView:content)
        window.center()
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle:"退出焦段统计",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        NSApp.mainMenu = menu
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { true }
}

@main struct Launcher {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
