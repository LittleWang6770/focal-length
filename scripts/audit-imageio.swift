import Foundation

// Read-only diagnostic using exactly the scanner shipped in the app.
@main struct ImageIOAudit {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            FileHandle.standardError.write(Data("Usage: audit-imageio ROOT OUTPUT.json\n".utf8))
            return
        }
        let report = try await ScanEngine.folder(URL(fileURLWithPath:CommandLine.arguments[1]),recursive:true) { _ in }
        let rows: [[String:Any]] = report.records.map {
            ["path":$0.id,"lens":$0.lens as Any? ?? NSNull(),"actual":$0.actual as Any? ?? NSNull(),
             "equivalent":$0.equivalent as Any? ?? NSNull(),"camera":$0.camera as Any? ?? NSNull()]
        }
        let payload: [String:Any] = ["records":rows,"attempted":report.attempted,"failed":report.failed,
                                   "inaccessible":report.inaccessibleDirectories,
                                   "issues":report.issues.map { ["path":$0.name,"reason":$0.reason] }]
        let data = try JSONSerialization.data(withJSONObject:payload,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:URL(fileURLWithPath:CommandLine.arguments[2]),options:.atomic)
        print("ImageIO: \(rows.count) readable photos; \(report.failed) failures; \(report.inaccessibleDirectories) inaccessible entries")
    }
}
