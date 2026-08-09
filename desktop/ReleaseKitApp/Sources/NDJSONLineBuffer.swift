import Foundation

/// Splits an NDJSON byte stream into whole lines.
///
/// The buffer deliberately works on bytes rather than characters. A pipe read ends
/// wherever the kernel happens to stop, which can be halfway through a multi-byte
/// UTF-8 character; decoding each read on its own turns that character into two
/// U+FFFD replacements that no later append can undo. Holding the raw bytes until a
/// newline (0x0A) terminates the line, and only then decoding, keeps the character
/// whole. A line whose bytes really are invalid UTF-8 still decodes lossily, which is
/// the same outcome the caller had before and keeps the text visible.
struct NDJSONLineBuffer {
    private var remainder = Data()

    /// Appends `data` and returns every line that it completed, in order. The trailing
    /// bytes after the last newline stay buffered for the next `feed` or for `flush`.
    mutating func feed(_ data: Data) -> [String] {
        remainder.append(data)
        guard remainder.contains(0x0A) else { return [] }

        var lines: [String] = []
        var start = remainder.startIndex
        while let newline = remainder[start...].firstIndex(of: 0x0A) {
            lines.append(String(decoding: remainder[start..<newline], as: UTF8.self))
            start = remainder.index(after: newline)
        }
        remainder = start == remainder.endIndex ? Data() : Data(remainder[start...])
        return lines
    }

    /// Returns the buffered bytes that never got a terminating newline, and empties the
    /// buffer. `nil` when nothing is pending, so the caller cannot emit a blank line.
    mutating func flush() -> String? {
        guard !remainder.isEmpty else { return nil }
        let line = String(decoding: remainder, as: UTF8.self)
        remainder = Data()
        return line
    }
}
