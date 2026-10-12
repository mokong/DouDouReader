import Foundation

/// 轻量级纯 Swift HTML DOM 节点
nonisolated final class HTMLNode: @unchecked Sendable {
    var tag: String
    var attributes: [String: String]
    var text: String
    var children: [HTMLNode]
    weak var parent: HTMLNode?

    init(tag: String, attributes: [String: String] = [:], text: String = "") {
        self.tag = tag.lowercased()
        self.attributes = attributes
        self.text = text
        self.children = []
    }

    /// 提取该节点及其所有子节点的合并文本内容。`<br>` 是换行，不然正文会连成一段。
    var allText: String {
        var result = text
        for child in children {
            if child.tag == "br" {
                if !result.hasSuffix("\n") {
                    result += "\n"
                }
                continue
            }
            let childText = child.allText
            if !childText.isEmpty {
                if !result.isEmpty && !result.hasSuffix("\n") && !result.hasSuffix(" ") {
                    result += " "
                }
                result += childText
            }
        }
        return HTMLMiniParser.decodeHTMLEntities(result).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 获取自身属性或文本
    func get(attr: String) -> String? {
        let key = attr.lowercased()
        if key == "text" || key == "text()" {
            return allText
        }
        if let val = attributes[key] {
            return HTMLMiniParser.decodeHTMLEntities(val).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// 书卡经常把链接写在外层 `<a>` 上，列表节点本身没有 href。
    func nearestHref(preferred: String?) -> String? {
        if let preferred, !preferred.isEmpty {
            return preferred
        }
        if let href = get(attr: "href"), !href.isEmpty {
            return href
        }
        var current = parent
        while let node = current {
            if let href = node.get(attr: "href"), !href.isEmpty {
                return href
            }
            current = node.parent
        }
        return nil
    }
}

/// 纯 Swift 极简 HTML 解析器与选择器提取引擎
nonisolated enum HTMLMiniParser {
    // MARK: - HTML 解析为 DOM 树

    static func parse(_ html: String) -> HTMLNode {
        let root = HTMLNode(tag: "root")
        var current = root

        let length = html.utf16.count
        guard length > 0 else { return root }

        var index = html.startIndex
        let end = html.endIndex

        var textBuffer = ""

        while index < end {
            if html[index] == "<" {
                // 将前面累积的普通文本保存到当前节点
                if !textBuffer.isEmpty {
                    let cleaned = decodeHTMLEntities(textBuffer)
                    if !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let textNode = HTMLNode(tag: "#text", text: cleaned)
                        textNode.parent = current
                        current.children.append(textNode)
                    }
                    textBuffer.removeAll(keepingCapacity: true)
                }

                // 检查是否为注释 <!DOCTYPE 或 <!--
                let remaining = html[index...]
                if remaining.hasPrefix("<!--") {
                    if let commentEnd = html.range(of: "-->", range: index..<end) {
                        index = commentEnd.upperBound
                        continue
                    } else {
                        break
                    }
                } else if remaining.hasPrefix("<!") {
                    if let closeBracket = html.range(of: ">", range: index..<end) {
                        index = closeBracket.upperBound
                        continue
                    } else {
                        break
                    }
                }

                // 寻找标签闭合 >
                guard let tagEnd = html.range(of: ">", range: index..<end) else {
                    break
                }

                let tagContent = String(html[html.index(after: index)..<tagEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                index = tagEnd.upperBound

                if tagContent.isEmpty { continue }

                // 闭合标签 </tag>
                if tagContent.hasPrefix("/") {
                    let closingTag = String(tagContent.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    // 向上回溯到匹配的父标签
                    var p: HTMLNode? = current
                    while let ancestor = p, ancestor !== root {
                        if ancestor.tag == closingTag {
                            current = ancestor.parent ?? root
                            break
                        }
                        p = ancestor.parent
                    }
                    continue
                }

                // 自闭合标签检测
                let isSelfClosing = tagContent.hasSuffix("/")
                let rawTag = isSelfClosing ? String(tagContent.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) : tagContent

                let (tag, attrs) = parseTagAndAttributes(rawTag)
                let node = HTMLNode(tag: tag, attributes: attrs)
                node.parent = current
                current.children.append(node)

                // 处理 <script> 或 <style> 内容直接跳过，避免将 js/css 代码当做正文
                if tag == "script" || tag == "style" {
                    let closeMarker = "</\(tag)>"
                    if let closeRange = html.range(of: closeMarker, options: .caseInsensitive, range: index..<end) {
                        index = closeRange.upperBound
                    }
                    continue
                }

                // 处理 HTML 中常见的单闭合标签
                let voidTags: Set<String> = ["meta", "link", "br", "hr", "img", "input", "source", "wbr", "area", "col"]
                if !isSelfClosing && !voidTags.contains(tag) {
                    current = node
                }
            } else {
                textBuffer.append(html[index])
                index = html.index(after: index)
            }
        }

        if !textBuffer.isEmpty {
            let cleaned = decodeHTMLEntities(textBuffer)
            if !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let textNode = HTMLNode(tag: "#text", text: cleaned)
                textNode.parent = current
                current.children.append(textNode)
            }
        }

        return root
    }

    private static func parseTagAndAttributes(_ raw: String) -> (String, [String: String]) {
        var scanner = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var tag = ""
        var attrs: [String: String] = [:]

        // 获取标签名
        if let spaceIndex = scanner.firstIndex(where: { $0.isWhitespace }) {
            tag = String(scanner[..<spaceIndex]).lowercased()
            scanner = String(scanner[spaceIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return (scanner.lowercased(), [:])
        }

        // 解析属性 key="val" 或 key='val' 或 key=val
        let pattern = #"([a-zA-Z0-9_\-:]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (tag, attrs)
        }

        let nsString = scanner as NSString
        let matches = regex.matches(in: scanner, range: NSRange(location: 0, length: nsString.length))
        for match in matches {
            guard match.numberOfRanges >= 2, match.range(at: 1).location != NSNotFound else { continue }
            let key = nsString.substring(with: match.range(at: 1)).lowercased()
            var value = ""
            if match.numberOfRanges > 2 && match.range(at: 2).location != NSNotFound {
                value = nsString.substring(with: match.range(at: 2))
            } else if match.numberOfRanges > 3 && match.range(at: 3).location != NSNotFound {
                value = nsString.substring(with: match.range(at: 3))
            } else if match.numberOfRanges > 4 && match.range(at: 4).location != NSNotFound {
                value = nsString.substring(with: match.range(at: 4))
            }
            attrs[key] = value
        }

        return (tag, attrs)
    }

    // MARK: - HTML 实体转义

    static func decodeHTMLEntities(_ raw: String) -> String {
        var str = raw
        if !str.contains("&") { return str }

        let standardEntities: [String: String] = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&apos;": "'",
            "&ensp;": " ",
            "&emsp;": "　",
            "&copy;": "©",
            "&reg;": "®"
        ]

        for (entity, char) in standardEntities {
            str = str.replacingOccurrences(of: entity, with: char)
        }

        // 匹配 &#1234; 或 &#x1234;
        let regex = try? NSRegularExpression(pattern: #"&#(x?[0-9a-fA-F]+);"#)
        if let regex {
            let nsStr = str as NSString
            let matches = regex.matches(in: str, range: NSRange(location: 0, length: nsStr.length))
            for match in matches.reversed() {
                let codeStr = nsStr.substring(with: match.range(at: 1))
                let codePoint: UInt32?
                if codeStr.hasPrefix("x") || codeStr.hasPrefix("X") {
                    codePoint = UInt32(codeStr.dropFirst(), radix: 16)
                } else {
                    codePoint = UInt32(codeStr, radix: 10)
                }
                if let cp = codePoint, let scalar = UnicodeScalar(cp) {
                    let replacement = String(Character(scalar))
                    str = (str as NSString).replacingCharacters(in: match.range, with: replacement)
                }
            }
        }

        return str
    }

    // MARK: - 规则选择器评估提取

    /// 从 HTML 根节点执行单条规则，返回提取到的所有文本或属性字符串。
    /// 逗号和 `||` 表示多条候选规则，按书写顺序合并。
    static func queryStrings(root: HTMLNode, rule: String) -> [String] {
        let alternatives = splitRuleAlternatives(rule)
        if alternatives.count > 1 {
            var merged: [String] = []
            for alternative in alternatives {
                merged.append(contentsOf: queryStrings(root: root, rule: alternative))
            }
            return merged
        }

        let (cleanRule, targetAttr, regexReplace, literal) = parseRuleSyntax(rule)
        // 整条规则就是 @js: 表达式时，返回从中提取出的字面量（URL 或 return 'xxx'）。
        if let literal {
            return applyRegex(regexReplace, to: [literal])
        }
        let nodes = selectNodes(root: root, selector: cleanRule)

        var results: [String] = []
        for node in nodes {
            if let targetAttr {
                if let val = node.get(attr: targetAttr) {
                    results.append(val)
                }
            } else {
                let val = node.allText
                if !val.isEmpty {
                    results.append(val)
                }
            }
        }

        if let (pattern, replacement) = regexReplace {
            results = applyRegex((pattern, replacement), to: results)
        }

        return results.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// 统一执行 ##正则##替换。
    private static func applyRegex(_ pair: (String, String)?, to input: [String]) -> [String] {
        guard let (pattern, replacement) = pair,
              let regex = try? NSRegularExpression(pattern: pattern) else {
            return input
        }
        return input.map { str in
            regex.stringByReplacingMatches(
                in: str,
                range: NSRange(location: 0, length: (str as NSString).length),
                withTemplate: replacement
            )
        }
    }

    /// 从 HTML 节点执行规则，返回匹配到的所有 HTMLNode 节点（常用于列表规则，如 bookList / chapterList）
    static func queryNodes(root: HTMLNode, rule: String) -> [HTMLNode] {
        let alternatives = splitRuleAlternatives(rule)
        if alternatives.count > 1 {
            var merged: [HTMLNode] = []
            var seen = Set<ObjectIdentifier>()
            for alternative in alternatives {
                for node in queryNodes(root: root, rule: alternative) {
                    let identity = ObjectIdentifier(node)
                    if seen.insert(identity).inserted {
                        merged.append(node)
                    }
                }
            }
            return merged
        }

        let (cleanRule, _, _, literal) = parseRuleSyntax(rule)
        // 纯 @js: 列表规则无法映射成 DOM 节点，直接返回空，避免退化成整棵树。
        if literal != nil {
            return []
        }
        return selectNodes(root: root, selector: cleanRule)
    }

    /// 拆开「甲, 乙」和「甲||乙」。括号、引号和 `##正则##` 里的逗号保持原样。
    private static func splitRuleAlternatives(_ rule: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var brackets = 0
        var parens = 0
        var quote: Character?
        var insideRegex = false
        let chars = Array(rule)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if let activeQuote = quote {
                current.append(char)
                if char == activeQuote {
                    quote = nil
                }
                index += 1
                continue
            }
            if char == "'" || char == "\"" {
                quote = char
                current.append(char)
                index += 1
                continue
            }
            if char == "#", index + 1 < chars.count, chars[index + 1] == "#" {
                insideRegex.toggle()
                current.append("##")
                index += 2
                continue
            }
            if !insideRegex {
                if char == "[" { brackets += 1 }
                else if char == "]" { brackets = max(0, brackets - 1) }
                else if char == "(" { parens += 1 }
                else if char == ")" { parens = max(0, parens - 1) }
                else if brackets == 0 && parens == 0 && char == "," {
                    appendAlternative(current, to: &parts)
                    current = ""
                    index += 1
                    continue
                } else if brackets == 0 && parens == 0 && char == "|", index + 1 < chars.count, chars[index + 1] == "|" {
                    appendAlternative(current, to: &parts)
                    current = ""
                    index += 2
                    continue
                }
            }
            current.append(char)
            index += 1
        }
        appendAlternative(current, to: &parts)
        return parts.isEmpty ? [rule] : parts
    }

    private static func appendAlternative(_ raw: String, to parts: inout [String]) {
        let piece = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !piece.isEmpty {
            parts.append(piece)
        }
    }

    /// 解析规则中的属性抽取符号（如 @text, @href, /text(), /@href, Jsoup @）及正则替换（##regex##replace）
    static func parseRuleSyntax(_ raw: String) -> (cleanSelector: String, targetAttr: String?, regexReplace: (String, String)?, literal: String?) {
        var working = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. 检查是否存在 ##regex##replace
        var regexReplace: (String, String)? = nil
        if let regexStart = working.range(of: "##") {
            let selectorPart = String(working[..<regexStart.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = String(working[regexStart.upperBound...])
            let parts = rest.components(separatedBy: "##")
            if parts.count >= 2 {
                regexReplace = (parts[0], parts[1])
            } else if parts.count == 1 {
                regexReplace = (parts[0], "")
            }
            working = selectorPart
        }

        // 2. 检查是否有 @js: 或 || @js: 规则（去掉后缀代码，保留主体选择器）
        var jsLiteral: String? = nil
        if let jsRange = working.range(of: "@js:") {
            let jsBody = String(working[jsRange.upperBound...])
            working = String(working[..<jsRange.lowerBound])
            if working.hasSuffix("||") {
                working = String(working.dropLast(2))
            }
            working = working.trimmingCharacters(in: .whitespacesAndNewlines)
            // 整条规则就是 @js: 表达式时，提取字面 URL 或 return 'xxx' 字面量，避免整条规则失效。
            if working.isEmpty {
                jsLiteral = extractJSLiteral(jsBody)
            }
        }

        // 3. 提取末尾的属性选择器，如 @href, @text, /@href, /text(), ::text
        var targetAttr: String? = nil

        if working.hasSuffix("/text()") || working.hasSuffix("/text") {
            targetAttr = "text"
            if working.hasSuffix("/text()") {
                working = String(working.dropLast(7))
            } else {
                working = String(working.dropLast(5))
            }
        } else if working.hasSuffix("::text") {
            targetAttr = "text"
            working = String(working.dropLast(6))
        } else if let atRange = working.range(of: "/@", options: .backwards) {
            targetAttr = String(working[atRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            working = String(working[..<atRange.lowerBound])
        } else if let atRange = working.range(of: "@", options: .backwards) {
            let possibleAttr = String(working[atRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            // 确保不是属性选择器如 [@class='xxx']
            if !possibleAttr.contains("]") && !possibleAttr.contains("=") && !possibleAttr.isEmpty {
                targetAttr = possibleAttr
                working = String(working[..<atRange.lowerBound])
            }
        }

        // 如果规则直接就是 "text" 或 "href" 等简短属性
        if working.isEmpty && targetAttr != nil {
            return ("", targetAttr, regexReplace, jsLiteral)
        }
        if working.lowercased() == "text" || working.lowercased() == "text()" {
            return ("", "text", regexReplace, jsLiteral)
        }
        if working.lowercased() == "href" || working.lowercased() == "src" {
            return ("", working.lowercased(), regexReplace, jsLiteral)
        }

        return (working.trimmingCharacters(in: .whitespacesAndNewlines), targetAttr, regexReplace, jsLiteral)
    }

    /// 从 @js: 代码体中提取高频字面量：return 'xxx' / return "xxx"，或第一个字面 URL。
    private static func extractJSLiteral(_ js: String) -> String? {
        let returnPattern = #"return\s*['"]([^'"]*)['"]"#
        if let regex = try? NSRegularExpression(pattern: returnPattern),
           let match = regex.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)) {
            let value = (js as NSString).substring(with: match.range(at: 1))
            if !value.isEmpty {
                return value
            }
        }
        if let urlRange = js.range(of: #"https?://[^\s'"<>\\]+"#, options: .regularExpression) {
            return String(js[urlRange])
        }
        return nil
    }

    /// 执行通用路径选择（支持 XPath 路径、CSS 路径与 Jsoup 路径）
    static func selectNodes(root: HTMLNode, selector: String) -> [HTMLNode] {
        var sel = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        if sel.isEmpty { return [root] }

        // 去掉开头的 @css: 或 @XPath: 前缀
        if sel.hasPrefix("@css:") {
            sel = String(sel.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if sel.hasPrefix("@xpath:") || sel.hasPrefix("@XPath:") {
            sel = String(sel.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 统一处理 Jsoup 风格，例如 class.result.0@tag.a.0 -> 将 @ 换为 空格
        if sel.contains(".") && (sel.contains("class.") || sel.contains("tag.")) {
            return selectJsoupNodes(root: root, selector: sel)
        }

        // 拆分路径步骤（支持 // 与 / 以及 空格）
        let steps = parseSelectorSteps(sel)
        var currentNodes: [HTMLNode] = [root]

        for step in steps {
            var nextNodes: [HTMLNode] = []
            for node in currentNodes {
                let matches = matchStep(node: node, step: step)
                nextNodes.append(contentsOf: matches)
            }
            if nextNodes.isEmpty {
                return []
            }
            currentNodes = nextNodes
        }

        return currentNodes
    }

    /// XPath 函数谓词，如 [contains(@class,'x')]、[starts-with(@href,'/book')]、[text()='甲']、[last()]
    private enum StepPredicateKind: Equatable {
        case contains(attr: String, value: String)
        case startsWith(attr: String, value: String)
        case textEquals(value: String)
        case isLast
    }

    private struct StepPredicate {
        var kind: StepPredicateKind
    }

    private struct SelectorStep {
        var isDeep: Bool          // 是否递归查找后代 (// 或 CSS 空格)
        var tag: String?          // 标签名
        var id: String?           // ID
        var className: String?    // 类名
        var attrKey: String?      // 属性名
        var attrValue: String?    // 属性值
        var index: Int?           // 索引 [0]
        var predicates: [StepPredicate] = []
    }

    private static func parseSelectorSteps(_ selector: String) -> [SelectorStep] {
        var steps: [SelectorStep] = []
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)

        // 纯 CSS 空格选择器（不含 /）
        if !trimmed.contains("/") {
            let tokens = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            var pendingDirectChild = false
            for token in tokens {
                // CSS 子选择器 >：其后的步骤只匹配直接子节点。
                if token == ">" {
                    pendingDirectChild = true
                    continue
                }
                steps.append(parseSingleStep(token, isDeep: !pendingDirectChild))
                pendingDirectChild = false
            }
            return steps
        }

        // 解析 XPath 路径或混合路径
        var cursor = trimmed.startIndex
        let end = trimmed.endIndex

        while cursor < end {
            while cursor < end && trimmed[cursor].isWhitespace {
                cursor = trimmed.index(after: cursor)
            }
            if cursor >= end { break }

            var isDeep = true
            if trimmed[cursor...].hasPrefix("//") {
                isDeep = true
                cursor = trimmed.index(cursor, offsetBy: 2)
            } else if trimmed[cursor...].hasPrefix("/") {
                isDeep = false
                cursor = trimmed.index(cursor, offsetBy: 1)
            }

            var token = ""
            var inBracket = false
            while cursor < end {
                let ch = trimmed[cursor]
                if ch == "[" { inBracket = true }
                else if ch == "]" { inBracket = false }

                if !inBracket && (ch == "/" || ch.isWhitespace) {
                    break
                }
                token.append(ch)
                cursor = trimmed.index(after: cursor)
            }

            let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanToken.isEmpty {
                steps.append(parseSingleStep(cleanToken, isDeep: isDeep))
            }
        }

        return steps
    }

    private static func parseSingleStep(_ partInput: String, isDeep: Bool) -> SelectorStep {
        var part = partInput
        var step = SelectorStep(isDeep: isDeep)

        // 解析 CSS 伪类 :first / :last / :nth-child(n)，转成索引语义。
        if let pseudoRange = part.range(of: #":(first-child|first|last-child|last|nth-child\(\d+\))"#, options: .regularExpression) {
            let pseudo = String(part[pseudoRange])
            part.removeSubrange(pseudoRange)
            if pseudo == ":first" || pseudo == ":first-child" {
                step.index = 0
            } else if pseudo == ":last" || pseudo == ":last-child" {
                step.predicates.append(StepPredicate(kind: .isLast))
            } else if pseudo.hasPrefix(":nth-child") {
                let num = pseudo.dropFirst(":nth-child(".count).dropLast(1)
                if let n = Int(num), n >= 1 { step.index = n - 1 }
            }
        }

        // 解析索引 [0]
        if let indexRange = part.range(of: #"\[\d+\]"#, options: .regularExpression) {
            let indexStr = String(part[indexRange]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            step.index = Int(indexStr)
            part.removeSubrange(indexRange)
        }

        // 解析 XPath 函数谓词 [contains(@a,'v')]、[starts-with(@a,'v')]、[text()='x']、[last()]
        var scanned = ""
        var cursor = part.startIndex
        while cursor < part.endIndex {
            if part[cursor] == "[" {
                // 收集匹配的整段方括号（支持 contains(...) 这类嵌套括号）
                var depth = 0
                var content = ""
                var j = cursor
                var closed = false
                while j < part.endIndex {
                    let cj = part[j]
                    if cj == "[" {
                        depth += 1
                        if depth > 1 { content.append(cj) }
                    } else if cj == "]" {
                        depth -= 1
                        if depth == 0 { closed = true; break } else { content.append(cj) }
                    } else {
                        content.append(cj)
                    }
                    j = part.index(after: j)
                }
                if let fn = parseFunctionPredicate(content) {
                    step.predicates.append(fn)
                } else {
                    scanned += "[\(content)]"
                }
                cursor = closed ? part.index(j, offsetBy: 1) : part.endIndex
            } else {
                scanned.append(part[cursor])
                cursor = part.index(after: cursor)
            }
        }
        part = scanned

        // 解析 XPath 属性判断 [@class='xxx'] 或 [@id='xxx'] 或 [@attr='xxx']
        if let attrRange = part.range(of: #"\[@([a-zA-Z0-9_\-]+)\s*=\s*['"]?([^'"]+)['"]?\]"#, options: .regularExpression) {
            let matched = String(part[attrRange])
            let inner = matched.trimmingCharacters(in: CharacterSet(charactersIn: "[]@"))
            let pair = inner.components(separatedBy: "=")
            if pair.count == 2 {
                let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let val = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "'\" \t"))
                if key == "class" {
                    step.className = val
                } else if key == "id" {
                    step.id = val
                } else {
                    step.attrKey = key
                    step.attrValue = val
                }
            }
            part.removeSubrange(attrRange)
        }

        // 解析 CSS 语法：#id 与 .class
        if part.contains("#") {
            let components = part.components(separatedBy: "#")
            if !components[0].isEmpty { step.tag = components[0].lowercased() }
            if components.count > 1 {
                let rest = components[1]
                if let dotIndex = rest.firstIndex(of: ".") {
                    step.id = String(rest[..<dotIndex])
                    step.className = String(rest[dotIndex...].dropFirst())
                } else {
                    step.id = rest
                }
            }
        } else if part.contains(".") {
            let components = part.components(separatedBy: ".")
            if !components[0].isEmpty { step.tag = components[0].lowercased() }
            if components.count > 1 {
                step.className = components[1]
            }
        } else if !part.isEmpty && part != "*" {
            step.tag = part.lowercased()
        }

        return step
    }

    /// 解析方括号内的函数谓词内容；不认识时返回 nil（保留给既有属性/索引逻辑）。
    private static func parseFunctionPredicate(_ innerRaw: String) -> StepPredicate? {
        let inner = innerRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        if inner == "last()" || inner == "position()=last()" {
            return StepPredicate(kind: .isLast)
        }
        func capture(_ pattern: String, _ transform: (String, String) -> StepPredicateKind) -> StepPredicate? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: inner, range: NSRange(inner.startIndex..., in: inner)),
                  m.numberOfRanges >= 3 else { return nil }
            let attr = (inner as NSString).substring(with: m.range(at: 1))
            let val = (inner as NSString).substring(with: m.range(at: 2))
            return StepPredicate(kind: transform(attr, val))
        }
        if let p = capture(#"contains\(\s*@([a-zA-Z0-9_\-]+)\s*,\s*['"]([^'"]*)['"]\s*\)"#, { .contains(attr: $0, value: $1) }) {
            return p
        }
        if let p = capture(#"starts-with\(\s*@([a-zA-Z0-9_\-]+)\s*,\s*['"]([^'"]*)['"]\s*\)"#, { .startsWith(attr: $0, value: $1) }) {
            return p
        }
        if let regex = try? NSRegularExpression(pattern: #"text\(\)\s*=\s*['"]([^'"]*)['"]"#),
           let m = regex.firstMatch(in: inner, range: NSRange(inner.startIndex..., in: inner)) {
            let val = (inner as NSString).substring(with: m.range(at: 1))
            return StepPredicate(kind: .textEquals(value: val))
        }
        return nil
    }

    /// 谓词求值。attr 为 text/text() 时取节点文本，否则取属性值。
    private static func predicateMatches(_ kind: StepPredicateKind, _ candidate: HTMLNode) -> Bool {
        func rawValue(_ attr: String) -> String? {
            let key = attr.lowercased()
            if key == "text" || key == "text()" {
                return candidate.allText
            }
            return candidate.get(attr: key)
        }
        switch kind {
        case .contains(let attr, let value):
            guard let raw = rawValue(attr) else { return false }
            return raw.contains(value)
        case .startsWith(let attr, let value):
            guard let raw = rawValue(attr) else { return false }
            return raw.hasPrefix(value)
        case .textEquals(let value):
            return candidate.allText == value
        case .isLast:
            return true // 由 matchStep 统一取最后一个
        }
    }

    private static func matchStep(node: HTMLNode, step: SelectorStep) -> [HTMLNode] {
        var pool: [HTMLNode] = []
        if step.isDeep {
            collectAllDescendants(of: node, into: &pool)
        } else {
            pool = node.children
        }

        var matched = pool.filter { candidate in
            if candidate.tag == "#text" { return false }
            if let tag = step.tag, tag != candidate.tag {
                return false
            }
            if let id = step.id, candidate.attributes["id"] != id {
                return false
            }
            if let cls = step.className {
                guard let candidateClasses = candidate.attributes["class"]?.components(separatedBy: .whitespaces) else {
                    return false
                }
                if !candidateClasses.contains(cls) {
                    return false
                }
            }
            if let key = step.attrKey, let val = step.attrValue {
                guard let actual = candidate.attributes[key], actual == val else {
                    return false
                }
            }
            for predicate in step.predicates where predicate.kind != .isLast {
                if !predicateMatches(predicate.kind, candidate) { return false }
            }
            return true
        }

        // [last()] 只保留最后一个命中节点。
        if step.predicates.contains(where: { $0.kind == .isLast }) {
            guard let last = matched.last else { return [] }
            matched = [last]
        }

        if let index = step.index {
            if index >= 0 && index < matched.count {
                return [matched[index]]
            } else {
                return []
            }
        }

        return matched
    }

    private static func collectAllDescendants(of node: HTMLNode, into pool: inout [HTMLNode]) {
        for child in node.children {
            pool.append(child)
            collectAllDescendants(of: child, into: &pool)
        }
    }

    // MARK: - Jsoup 规则支持 (class.item.0@tag.a.0)

    private static func selectJsoupNodes(root: HTMLNode, selector: String) -> [HTMLNode] {
        let segments = selector.components(separatedBy: "@")
        var currentNodes = [root]

        for segment in segments {
            let parts = segment.components(separatedBy: ".")
            guard parts.count >= 2 else { continue }
            let kind = parts[0]   // "class" 或 "tag"
            let value = parts[1]  // 类名或标签名
            let index = parts.count > 2 ? Int(parts[2]) : nil

            var nextNodes: [HTMLNode] = []
            for node in currentNodes {
                var descendants: [HTMLNode] = []
                collectAllDescendants(of: node, into: &descendants)
                let matched = descendants.filter { cand in
                    if kind == "class" {
                        return cand.attributes["class"]?.contains(value) == true
                    } else if kind == "tag" {
                        return cand.tag == value.lowercased()
                    }
                    return false
                }
                if let index, index >= 0 && index < matched.count {
                    nextNodes.append(matched[index])
                } else if index == nil {
                    nextNodes.append(contentsOf: matched)
                }
            }
            currentNodes = nextNodes
        }

        return currentNodes
    }
}
