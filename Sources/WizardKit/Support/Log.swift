import Foundation
import os

/// Subsystem-wide loggers. One category per subsystem so `log stream
/// --predicate 'subsystem == "com.bricken.wizard"'` stays readable.
public enum Log {
    private static let subsystem = "com.bricken.wizard"

    public static let asr = Logger(subsystem: subsystem, category: "asr")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let trigger = Logger(subsystem: subsystem, category: "trigger")
    public static let session = Logger(subsystem: subsystem, category: "session")
    public static let paste = Logger(subsystem: subsystem, category: "paste")
    public static let model = Logger(subsystem: subsystem, category: "model")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    public static let history = Logger(subsystem: subsystem, category: "history")
}
