import Foundation

/// xbs（香色闺阁加密书源）解密。
///
/// 格式：原始 JSON 字节 || 0x00 填充到 4 的倍数 || uint32 小端（原始 JSON 长度），
/// 再按 XXTEA 加密。密钥固定 16 字节，字序按小端（与 PyPI xxtea 包一致）。
/// 解密后的 JSON 直接喂给 BookSourceParser 走既有阅读/香色字段映射。
nonisolated enum XBSDecoder {
    /// 固定 16 字节密钥的 4 个小端 uint32 字。
    static let keyWords: [UInt32] = [0xE8BC87E5, 0xBBE686A4, 0x9187E9BF, 0xE5A1BAE6]

    /// 把 xbs 密文解成原始 JSON 字节。输入非法（长度不对、长度字段越界）时返回 nil。
    static func decryptJSON(xbs data: Data) -> Data? {
        guard data.count >= 8, data.count % 4 == 0 else { return nil }
        var words = wordsLE(from: data)
        xxteaDecrypt(&words)
        let decrypted = bytesLE(from: words)
        let lengthOffset = data.count - 4
        guard lengthOffset + 4 <= decrypted.count else { return nil }
        let rawLength = UInt32(decrypted[lengthOffset])
            | (UInt32(decrypted[lengthOffset + 1]) << 8)
            | (UInt32(decrypted[lengthOffset + 2]) << 16)
            | (UInt32(decrypted[lengthOffset + 3]) << 24)
        guard rawLength >= 1, rawLength <= UInt32(lengthOffset) else { return nil }
        return decrypted.prefix(Int(rawLength))
    }

    /// 把密文里的任意数据按 xbs 尝试解密，成功且是 UTF-8 JSON 时返回文本。
    static func jsonText(xbs data: Data) -> String? {
        guard let json = decryptJSON(xbs: data) else { return nil }
        let trimmed = String(data: json, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return nil }
        return trimmed
    }

    // MARK: - XXTEA

    private static func wordsLE(from data: Data) -> [UInt32] {
        data.withUnsafeBytes { raw -> [UInt32] in
            var words: [UInt32] = []
            let count = raw.count / 4
            words.reserveCapacity(count)
            var offset = 0
            while offset + 4 <= raw.count {
                words.append(
                    UInt32(raw[offset])
                        | UInt32(raw[offset + 1]) << 8
                        | UInt32(raw[offset + 2]) << 16
                        | UInt32(raw[offset + 3]) << 24
                )
                offset += 4
            }
            return words
        }
    }

    private static func bytesLE(from words: [UInt32]) -> Data {
        var data = Data()
        data.reserveCapacity(words.count * 4)
        for word in words {
            data.append(UInt8(word & 0xff))
            data.append(UInt8((word >> 8) & 0xff))
            data.append(UInt8((word >> 16) & 0xff))
            data.append(UInt8((word >> 24) & 0xff))
        }
        return data
    }

    /// 标准 XXTEA 解密，原地修改。所有运算按 2^32 回绕。
    private static func xxteaDecrypt(_ v: inout [UInt32]) {
        let n = v.count
        guard n >= 2 else { return }
        let delta: UInt32 = 0x9E3779B9
        let rounds = 6 + 52 / n
        let key = keyWords
        var sum = UInt32(rounds) &* delta
        var y = v[0]
        while sum != 0 {
            let e = (sum >> 2) & 3
            var p = n - 1
            while p > 0 {
                let z = v[p - 1]
                let mx = (((z >> 5) ^ (y << 2)) &+ ((y >> 3) ^ (z << 4)))
                    ^ ((sum ^ y) &+ (key[(p & 3) ^ Int(e)] ^ z))
                v[p] = v[p] &- mx
                y = v[p]
                p -= 1
            }
            let z = v[n - 1]
            let mx = (((z >> 5) ^ (y << 2)) &+ ((y >> 3) ^ (z << 4)))
                ^ ((sum ^ y) &+ (key[Int(e)] ^ z))
            v[0] = v[0] &- mx
            y = v[0]
            sum = sum &- delta
        }
    }
}
