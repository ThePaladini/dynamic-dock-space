import Foundation
import os

/// Localized UI string. Keys are the English text (development language); see Resources/*.lproj.
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

enum Log {
    static var verbose = false
    private static let logger = Logger(subsystem: "io.github.thepaladini.DynamicDockSpace", category: "engine")
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    static func info(_ message: @autoclosure () -> String) {
        let m = message()
        logger.info("\(m, privacy: .public)")
        if verbose {
            FileHandle.standardError.write(Data((fmt.string(from: Date()) + " " + m + "\n").utf8))
        }
    }
}

extension CGRect {
    var short: String { String(format: "(%.0f,%.0f %.0fx%.0f)", minX, minY, width, height) }
    func approx(_ o: CGRect, tol: CGFloat = 2) -> Bool {
        abs(minX - o.minX) <= tol && abs(minY - o.minY) <= tol && abs(width - o.width) <= tol && abs(height - o.height) <= tol
    }
}
