import OSLog

enum AppLog {
    static let subsystem = "com.byrdal.Spectrum"

    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let dsp = Logger(subsystem: subsystem, category: "dsp")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let driver = Logger(subsystem: subsystem, category: "driver")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
}
