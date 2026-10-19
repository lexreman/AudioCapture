import Foundation

/// The settings store. Test runs get their own domain, so a test (even one killed halfway)
/// can never change the person's folder, format, window size or in-progress recording.
let testRun = ["--clicktest", "--selftest", "--snapshots", "--settingsshots", "--silencetest", "--setupshots", "--boardshots", "--twice", "--crashtest", "--recovertest", "--dump-apps", "--quitwatch", "--arrowtest", "--quitsave", "--layouttest"]
    .contains(where: CommandLine.arguments.contains)

nonisolated(unsafe) let prefs: UserDefaults = testRun ? UserDefaults(suiteName: "io.github.lexreman.audiocapture.tests")! : .standard
