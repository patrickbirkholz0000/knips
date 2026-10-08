import AppKit

#if KNIPS_DEV
let arguments = CommandLine.arguments
if arguments.count >= 2, arguments[1] == "--selftest" {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let code = onMainActor { SelfTest.run(Array(arguments.dropFirst(2))) }
    exit(code)
}
#endif

onMainActor {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
