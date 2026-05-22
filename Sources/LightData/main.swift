import AppKit

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--dump" {
    do {
        let url = URL(fileURLWithPath: CommandLine.arguments[2])
        let document = try TableDocument.load(url: url)
        print("\(document.format.displayName): \(document.rowCount) rows, \(document.columnCount) columns")
        print("Info: \(document.openInfo.displaySummary)")
        print(document.headers.joined(separator: "\t"))
        for row in document.rows.prefix(5) {
            print(row.joined(separator: "\t"))
        }
        exit(0)
    } catch {
        fputs("LightData: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
