import Foundation

nonisolated enum ZipError: Error {
    case damaged
    case encrypted
    case unsupported
    case tooLarge
}

/// EPUB 是 ZIP。只读取中央目录里点名的条目，存储和 deflate 两种压缩都能解。
nonisolated struct ZipArchive: Sendable {
    private let bytes: [UInt8]
    private let items: [String: Item]

    struct Item: Sendable {
        var method: Int
        var flags: Int
        var crc: UInt32
        var compressedSize: Int
        var uncompressedSize: Int
        var localOffset: Int
    }

    static func open(_ data: Data) throws -> ZipArchive {
        let bytes = [UInt8](data)
        let items = try catalog(bytes)
        return ZipArchive(bytes: bytes, items: items)
    }

    func file(_ path: String) throws -> Data? {
        let key = Self.normalize(path)
        if let item = items[key] {
            return try extract(item)
        }
        let folded = key.lowercased()
        guard let item = items.first(where: { $0.key.lowercased() == folded })?.value else {
            return nil
        }
        return try extract(item)
    }

    private func extract(_ item: Item) throws -> Data {
        if item.flags & 1 != 0 { throw ZipError.encrypted }
        guard item.uncompressedSize <= Inflate.limit, item.compressedSize <= Inflate.limit else {
            throw ZipError.tooLarge
        }
        guard item.localOffset >= 0, item.localOffset + 30 <= bytes.count else { throw ZipError.damaged }
        let nameLength = int(item.localOffset + 26, count: 2)
        let extraLength = int(item.localOffset + 28, count: 2)
        let start = item.localOffset + 30 + nameLength + extraLength
        let end = start + item.compressedSize
        guard nameLength >= 0, extraLength >= 0, start >= 0, end <= bytes.count else { throw ZipError.damaged }
        if item.uncompressedSize == 0 { return Data() }
        let compressed = Data(bytes[start..<end])
        let inflated: Data
        switch item.method {
        case 0:
            inflated = compressed
        case 8:
            inflated = try Inflate.decode(compressed, expected: item.uncompressedSize)
        default:
            throw ZipError.unsupported
        }
        guard CRC32.hash(inflated) == item.crc else { throw ZipError.damaged }
        return inflated
    }

    private static func catalog(_ bytes: [UInt8]) throws -> [String: Item] {
        guard let eocd = endOfCentralDirectory(bytes) else { throw ZipError.damaged }
        var count = int(bytes, eocd + 10, count: 2)
        var size = int(bytes, eocd + 12, count: 4)
        var offset = int(bytes, eocd + 16, count: 4)
        if count == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {
            guard let zip64 = zip64CentralDirectory(bytes, eocd: eocd) else { throw ZipError.damaged }
            count = zip64.count
            size = zip64.size
            offset = zip64.offset
        }
        guard count >= 0, size >= 0, offset >= 0, offset + size <= bytes.count else { throw ZipError.damaged }
        var cursor = offset
        let end = offset + size
        var items: [String: Item] = [:]
        for _ in 0..<count {
            guard cursor + 46 <= end, u32(bytes, cursor) == 0x02014B50 else { throw ZipError.damaged }
            let flags = int(bytes, cursor + 8, count: 2)
            let method = int(bytes, cursor + 10, count: 2)
            let crc = u32(bytes, cursor + 16)
            var compressed = int(bytes, cursor + 20, count: 4)
            var uncompressed = int(bytes, cursor + 24, count: 4)
            let nameLength = int(bytes, cursor + 28, count: 2)
            let extraLength = int(bytes, cursor + 30, count: 2)
            let commentLength = int(bytes, cursor + 32, count: 2)
            var localOffset = int(bytes, cursor + 42, count: 4)
            let nameStart = cursor + 46
            let extraStart = nameStart + nameLength
            let next = extraStart + extraLength + commentLength
            guard nameLength >= 0, extraLength >= 0, commentLength >= 0, next <= end else {
                throw ZipError.damaged
            }
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                let fields = zip64Fields(
                    bytes,
                    extraStart,
                    extraStart + extraLength,
                    compressed: compressed,
                    uncompressed: uncompressed,
                    localOffset: localOffset
                )
                compressed = fields.compressed
                uncompressed = fields.uncompressed
                localOffset = fields.localOffset
            }
            let name = decodeName(Data(bytes[nameStart..<extraStart]), flags: flags)
            if !name.isEmpty {
                items[name] = Item(
                    method: method,
                    flags: flags,
                    crc: crc,
                    compressedSize: compressed,
                    uncompressedSize: uncompressed,
                    localOffset: localOffset
                )
            }
            cursor = next
        }
        return items
    }

    private static func endOfCentralDirectory(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let lower = max(0, bytes.count - (22 + 65_535))
        var offset = bytes.count - 22
        while offset >= lower {
            if u32(bytes, offset) == 0x06054B50 {
                let comment = int(bytes, offset + 20, count: 2)
                if offset + 22 + comment == bytes.count { return offset }
            }
            if offset == 0 { break }
            offset -= 1
        }
        return nil
    }

    private static func zip64CentralDirectory(_ bytes: [UInt8], eocd: Int) -> (count: Int, size: Int, offset: Int)? {
        guard eocd >= 20, u32(bytes, eocd - 20) == 0x07064B50 else { return nil }
        let record = int(bytes, eocd - 12, count: 8)
        guard record >= 0, record + 56 <= bytes.count, u32(bytes, record) == 0x06064B50 else { return nil }
        let count = int(bytes, record + 32, count: 8)
        let size = int(bytes, record + 40, count: 8)
        let offset = int(bytes, record + 48, count: 8)
        return (count, size, offset)
    }

    private static func zip64Fields(
        _ bytes: [UInt8],
        _ start: Int,
        _ end: Int,
        compressed: Int,
        uncompressed: Int,
        localOffset: Int
    ) -> (compressed: Int, uncompressed: Int, localOffset: Int) {
        var cursor = start
        var compressed = compressed
        var uncompressed = uncompressed
        var localOffset = localOffset
        while cursor + 4 <= end {
            let identifier = int(bytes, cursor, count: 2)
            let size = int(bytes, cursor + 2, count: 2)
            let payload = cursor + 4
            guard size >= 0, payload + size <= end else { break }
            if identifier == 1 {
                var field = payload
                if uncompressed == 0xFFFF_FFFF, field + 8 <= payload + size {
                    uncompressed = int(bytes, field, count: 8)
                    field += 8
                }
                if compressed == 0xFFFF_FFFF, field + 8 <= payload + size {
                    compressed = int(bytes, field, count: 8)
                    field += 8
                }
                if localOffset == 0xFFFF_FFFF, field + 8 <= payload + size {
                    localOffset = int(bytes, field, count: 8)
                }
                break
            }
            cursor = payload + size
        }
        return (compressed, uncompressed, localOffset)
    }

    private static func decodeName(_ data: Data, flags: Int) -> String {
        let text: String
        if flags & (1 << 11) != 0, let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else if let gb = String(data: data, encoding: TextDecoding.gb18030) {
            text = gb
        } else {
            text = ""
        }
        return normalize(text)
    }

    static func normalize(_ path: String) -> String {
        let slashed = path.replacingOccurrences(of: "\\", with: "/")
        var parts: [String] = []
        for part in slashed.split(separator: "/") {
            if part == "." || part.isEmpty { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(String(part))
        }
        return parts.joined(separator: "/")
    }

    private func int(_ offset: Int, count: Int) -> Int {
        Self.int(bytes, offset, count: count)
    }

    private static func int(_ bytes: [UInt8], _ offset: Int, count: Int) -> Int {
        guard offset >= 0, count > 0, offset + count <= bytes.count, count <= 8 else { return -1 }
        var value = 0
        for shift in 0..<count {
            value |= Int(bytes[offset + shift]) << (8 * shift)
        }
        return value
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(truncatingIfNeeded: int(bytes, offset, count: 4))
    }
}

private nonisolated enum CRC32 {
    static func hash(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask: UInt32 = (crc & 1) == 1 ? 0xEDB8_8320 : 0
                crc = (crc >> 1) ^ mask
            }
        }
        return ~crc
    }
}

/// ZIP 的 deflate 是裸 DEFLATE。哈夫曼码先读到的是高位，长度附加位先读到的是低位。
private nonisolated enum Inflate {
    static let limit = 40 * 1024 * 1024

    static func decode(_ data: Data, expected: Int) throws -> Data {
        guard expected >= 0, expected <= limit else { throw ZipError.tooLarge }
        var reader = BitReader(bytes: [UInt8](data))
        var output: [UInt8] = []
        if expected > 0 { output.reserveCapacity(expected) }
        while true {
            guard let final = reader.bit(), let type = reader.bits(2) else { throw ZipError.damaged }
            switch type {
            case 0:
                try stored(&reader, into: &output)
            case 1:
                try coded(&reader, into: &output, literal: fixedLiteral, distance: fixedDistance)
            case 2:
                try dynamic(&reader, into: &output)
            default:
                throw ZipError.damaged
            }
            if final == 1 { break }
        }
        if expected > 0, output.count != expected { throw ZipError.damaged }
        return Data(output)
    }

    private static func stored(_ reader: inout BitReader, into output: inout [UInt8]) throws {
        reader.align()
        guard let length = reader.bytesLE(2), let complement = reader.bytesLE(2), length == (complement ^ 0xFFFF) else {
            throw ZipError.damaged
        }
        guard let raw = reader.raw(length) else { throw ZipError.damaged }
        guard output.count + raw.count <= limit else { throw ZipError.tooLarge }
        output.append(contentsOf: raw)
    }

    private static func dynamic(_ reader: inout BitReader, into output: inout [UInt8]) throws {
        guard let literalBits = reader.bits(5), let distanceBits = reader.bits(5), let codeBits = reader.bits(4) else {
            throw ZipError.damaged
        }
        let literalCount = literalBits + 257
        let distanceCount = distanceBits + 1
        let codeCount = codeBits + 4
        guard literalCount <= 286, distanceCount <= 32, codeCount <= 19 else { throw ZipError.damaged }
        var codeLengths = [Int](repeating: 0, count: 19)
        for index in 0..<codeCount {
            guard let length = reader.bits(3) else { throw ZipError.damaged }
            codeLengths[Huffman.codeOrder[index]] = length
        }
        let lengthTree = try Huffman(codeLengths)
        var lengths: [Int] = []
        lengths.reserveCapacity(literalCount + distanceCount)
        while lengths.count < literalCount + distanceCount {
            guard let symbol = lengthTree.decode(&reader) else { throw ZipError.damaged }
            if symbol < 16 {
                lengths.append(symbol)
            } else if symbol == 16 {
                guard let previous = lengths.last, let extra = reader.bits(2) else { throw ZipError.damaged }
                lengths.append(contentsOf: repeatElement(previous, count: extra + 3))
            } else if symbol == 17 {
                guard let extra = reader.bits(3) else { throw ZipError.damaged }
                lengths.append(contentsOf: repeatElement(0, count: extra + 3))
            } else if symbol == 18 {
                guard let extra = reader.bits(7) else { throw ZipError.damaged }
                lengths.append(contentsOf: repeatElement(0, count: extra + 11))
            } else {
                throw ZipError.damaged
            }
            if lengths.count > literalCount + distanceCount { throw ZipError.damaged }
        }
        let literal = try Huffman(Array(lengths[..<literalCount]))
        let distance = try Huffman(Array(lengths[literalCount...]))
        try coded(&reader, into: &output, literal: literal, distance: distance)
    }

    private static func coded(
        _ reader: inout BitReader,
        into output: inout [UInt8],
        literal: Huffman,
        distance: Huffman
    ) throws {
        while true {
            guard let symbol = literal.decode(&reader) else { throw ZipError.damaged }
            if symbol < 256 {
                guard output.count < limit else { throw ZipError.tooLarge }
                output.append(UInt8(symbol))
                continue
            }
            if symbol == 256 { return }
            let lengthIndex = symbol - 257
            guard lengthIndex >= 0, lengthIndex < lengthBase.count else { throw ZipError.damaged }
            guard let lengthExtra = reader.bits(lengthExtra[lengthIndex]) else { throw ZipError.damaged }
            let length = lengthBase[lengthIndex] + lengthExtra
            guard let distanceSymbol = distance.decode(&reader) else { throw ZipError.damaged }
            guard distanceSymbol >= 0, distanceSymbol < distanceBase.count else { throw ZipError.damaged }
            guard let distanceExtra = reader.bits(distanceExtraBits[distanceSymbol]) else { throw ZipError.damaged }
            let distance = distanceBase[distanceSymbol] + distanceExtra
            guard distance >= 1, distance <= output.count else { throw ZipError.damaged }
            guard output.count + length <= limit else { throw ZipError.tooLarge }
            for _ in 0..<length {
                output.append(output[output.count - distance])
            }
        }
    }

    private static let fixedLiteral: Huffman = {
        var lengths = [Int](repeating: 0, count: 288)
        for index in 0...143 { lengths[index] = 8 }
        for index in 144...255 { lengths[index] = 9 }
        for index in 256...279 { lengths[index] = 7 }
        for index in 280...287 { lengths[index] = 8 }
        return try! Huffman(lengths)
    }()

    private static let fixedDistance = try! Huffman([Int](repeating: 5, count: 32))

    private static let lengthBase = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115,
        131, 163, 195, 227, 258,
    ]
    private static let lengthExtra = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
    ]
    private static let distanceBase = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
        2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
    ]
    private static let distanceExtraBits = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
    ]
}

private nonisolated struct BitReader {
    var bytes: [UInt8]
    var index = 0
    var bitPosition = 0

    mutating func bit() -> Int? {
        guard index < bytes.count else { return nil }
        let value = (Int(bytes[index]) >> bitPosition) & 1
        bitPosition += 1
        if bitPosition == 8 {
            bitPosition = 0
            index += 1
        }
        return value
    }

    mutating func bits(_ count: Int) -> Int? {
        var value = 0
        for shift in 0..<count {
            guard let bit = bit() else { return nil }
            value |= bit << shift
        }
        return value
    }

    mutating func align() {
        if bitPosition != 0 {
            bitPosition = 0
            index += 1
        }
    }

    mutating func bytesLE(_ count: Int) -> Int? {
        align()
        guard index + count <= bytes.count else { return nil }
        var value = 0
        for shift in 0..<count {
            value |= Int(bytes[index + shift]) << (8 * shift)
        }
        index += count
        return value
    }

    mutating func raw(_ count: Int) -> ArraySlice<UInt8>? {
        align()
        guard index + count <= bytes.count else { return nil }
        let slice = bytes[index..<(index + count)]
        index += count
        return slice
    }
}

private nonisolated struct Huffman {
    static let codeOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
    private var counts = [Int](repeating: 0, count: 16)
    private var symbols: [Int] = []
    private var firstCode = [Int](repeating: 0, count: 16)
    private var firstIndex = [Int](repeating: 0, count: 16)
    private var maxLength = 0

    init(_ lengths: [Int]) throws {
        var buckets = [[Int]](repeating: [], count: 16)
        for (symbol, length) in lengths.enumerated() where length > 0 {
            guard length < 16 else { throw ZipError.damaged }
            counts[length] += 1
            buckets[length].append(symbol)
            maxLength = max(maxLength, length)
        }
        var code = 0
        for length in 1...15 {
            firstCode[length] = code
            firstIndex[length] = symbols.count
            symbols.append(contentsOf: buckets[length])
            code = (code + counts[length]) << 1
        }
    }

    func decode(_ reader: inout BitReader) -> Int? {
        guard maxLength > 0 else { return nil }
        var code = 0
        for length in 1...maxLength {
            guard let bit = reader.bit() else { return nil }
            code = (code << 1) | bit
            let count = counts[length]
            if count == 0 { continue }
            let offset = code - firstCode[length]
            if offset >= 0, offset < count {
                return symbols[firstIndex[length] + offset]
            }
        }
        return nil
    }
}
