import Foundation

public struct IncrementalLineBatch: Equatable, Sendable {
    public let lines: [Data]
    public let nextOffset: Int64
    public let discardUntilNewline: Bool
    public let reachedReadLimit: Bool

    public init(
        lines: [Data],
        nextOffset: Int64,
        discardUntilNewline: Bool = false,
        reachedReadLimit: Bool = false
    ) {
        self.lines = lines
        self.nextOffset = nextOffset
        self.discardUntilNewline = discardUntilNewline
        self.reachedReadLimit = reachedReadLimit
    }
}

public enum IncrementalLineReader {
    public static func readCompleteLines(
        path: String,
        from offset: Int64,
        discardUntilNewline: Bool = false,
        maximumBytes: Int = 8 * 1_024 * 1_024,
        maximumLineBytes: Int = SessionLineParser.maximumLineBytes
    ) throws -> IncrementalLineBatch {
        guard offset >= 0 else {
            throw AgentBoardDatabaseError.invalidData("negative file offset")
        }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))

        let startOffset = offset
        var consumed = 0
        var lastCompleteOffset = offset
        var line = Data()
        var discarding = discardUntilNewline
        var lines: [Data] = []

        while consumed < maximumBytes {
            let allowance = min(64 * 1_024, maximumBytes - consumed)
            let chunk = try handle.read(upToCount: allowance) ?? Data()
            if chunk.isEmpty { break }
            for byte in chunk {
                consumed += 1
                if byte == 0x0A {
                    if !discarding, !line.isEmpty {
                        if line.last == 0x0D {
                            line.removeLast()
                        }
                        lines.append(line)
                    }
                    line.removeAll(keepingCapacity: true)
                    discarding = false
                    lastCompleteOffset = startOffset + Int64(consumed)
                } else if !discarding {
                    line.append(byte)
                    if line.count > maximumLineBytes {
                        line.removeAll(keepingCapacity: true)
                        discarding = true
                        lastCompleteOffset = startOffset + Int64(consumed)
                    }
                }
            }
            if chunk.count < allowance { break }
        }

        if discarding, lastCompleteOffset < startOffset + Int64(consumed) {
            lastCompleteOffset = startOffset + Int64(consumed)
        }
        return IncrementalLineBatch(
            lines: lines,
            nextOffset: lastCompleteOffset,
            discardUntilNewline: discarding,
            reachedReadLimit: consumed >= maximumBytes
        )
    }

    public static func readTailCompleteLines(
        path: String,
        maximumBytes: Int = 8 * 1_024 * 1_024,
        maximumLineBytes: Int = SessionLineParser.maximumLineBytes
    ) throws -> [Data] {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > UInt64(maximumBytes)
            ? size - UInt64(maximumBytes)
            : 0
        try handle.seek(toOffset: start)
        var data = try handle.read(upToCount: maximumBytes) ?? Data()
        if start > 0 {
            guard let newline = data.firstIndex(of: 0x0A) else {
                return []
            }
            data.removeSubrange(data.startIndex...newline)
        }
        return data
            .split(separator: 0x0A, omittingEmptySubsequences: false)
            .filter { !$0.isEmpty && $0.count <= maximumLineBytes }
            .map { Data($0) }
    }
}
