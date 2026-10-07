import AppKit

let arguments = CommandLine.arguments
if arguments.count >= 2, arguments[1] == "--selftest" {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let code = MainActor.assumeIsolated { SelfTest.run(Array(arguments.dropFirst(2))) }
    exit(code)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
