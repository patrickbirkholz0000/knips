// Schickt einen Befehl an eine Knips-Instanz in der Test-Sandbox (KNIPS_TEST_DIR).
// Aufruf: swift scripts/test-command.swift menu
import Foundation
let command = CommandLine.arguments.dropFirst().first ?? "menu"
DistributedNotificationCenter.default().postNotificationName(Notification.Name("de.birkgroup.knips.test"), object: command, userInfo: nil, deliverImmediately: true)
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
