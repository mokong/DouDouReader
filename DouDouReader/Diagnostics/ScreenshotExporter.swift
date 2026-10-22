import Foundation
import SwiftData
import SwiftUI
#if os(macOS)
import AppKit

@MainActor
enum ScreenshotExporter {
    static func exportIfRequested(container: ModelContainer) {
        guard ProcessInfo.processInfo.arguments.contains("-renderScreenshots") else { return }
        
        let targetDirURL = BookStorage.supportRoot.appendingPathComponent("Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: targetDirURL, withIntermediateDirectories: true)
        
        print("Rendering screenshots to \(targetDirURL.path)...")
        renderBookshelf(to: targetDirURL.appendingPathComponent("screenshot_shelf.png"))
        renderReader(to: targetDirURL.appendingPathComponent("screenshot_reader.png"))
        renderDiscover(to: targetDirURL.appendingPathComponent("screenshot_discover.png"))
        renderSources(to: targetDirURL.appendingPathComponent("screenshot_sources.png"))
        
        print("SCREENSHOTS_DONE")
        exit(0)
    }

    private static func saveImage(_ view: some View, size: CGSize, scale: CGFloat = 2.0, to url: URL) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = scale
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("Failed to render \(url.lastPathComponent)")
            return
        }
        let b64 = png.base64EncodedString()
        print("___SCREENSHOT___:\(url.lastPathComponent)")
        print(b64)
        print("___END_SCREENSHOT___:\(url.lastPathComponent)")
        do {
            try png.write(to: url)
            print("Exported \(url.lastPathComponent) (\(Int(size.width * scale))x\(Int(size.height * scale)))")
        } catch {
            print("Failed to save \(url.lastPathComponent): \(error)")
        }
    }

    // MARK: - 1. 书架截图
    private static func renderBookshelf(to url: URL) {
        let view = PhoneFrame(title: "书架") {
            VStack(spacing: 0) {
                // Shelf Bar
                HStack(spacing: 0) {
                    Text("豆豆阅读")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(ShelfInk.ink)
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 36, height: 36)
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 36, height: 36)
                    }
                    .foregroundStyle(ShelfInk.ink)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 6)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        // 接着读卡片
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(hue: 0.58, saturation: 0.45, brightness: 0.62))
                                .frame(width: 36, height: 50)
                                .overlay {
                                    Text("灯塔\n邮局")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .multilineTextAlignment(.center)
                                }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("继续阅读 · 灯塔邮局")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(ShelfInk.ink)
                                Text("第一章 雨夜的信封 · 18%")
                                    .font(.system(size: 12))
                                    .foregroundStyle(ShelfInk.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(ShelfInk.secondary)
                        }
                        .padding(12)
                        .background(ShelfInk.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(ShelfInk.line, lineWidth: 1)
                        )

                        // 书籍网格
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 16) {
                            mockBookCard(title: "灯塔邮局", author: "豆豆", hue: 0.58, pinned: true, badge: nil)
                            mockBookCard(title: "三体：全集", author: "刘慈欣", hue: 0.68, pinned: false, badge: "新 3 章")
                            mockBookCard(title: "平凡的世界", author: "路遥", hue: 0.08, pinned: false, badge: nil)
                            mockBookCard(title: "明朝那些事儿", author: "当年明月", hue: 0.12, pinned: false, badge: "有更新")
                            mockBookCard(title: "雪中悍刀行", author: "烽火戏诸侯", hue: 0.85, pinned: false, badge: nil)
                            mockBookCard(title: "剑来", author: "烽火戏诸侯", hue: 0.35, pinned: false, badge: "新 1 章")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                }

                Spacer(minLength: 0)

                // Bottom TabBar
                HStack(spacing: 0) {
                    VStack(spacing: 3) {
                        Image(systemName: "books.vertical.fill")
                            .font(.system(size: 20))
                        Text("书架")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(ShelfInk.accent)

                    VStack(spacing: 3) {
                        Image(systemName: "safari")
                            .font(.system(size: 20))
                        Text("发现")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(ShelfInk.secondary)
                }
                .padding(.top, 8)
                .padding(.bottom, 12)
                .background(ShelfInk.paper)
                .overlay(alignment: .top) {
                    Divider().background(ShelfInk.line)
                }
            }
            .background(ShelfInk.paper)
        }

        saveImage(view, size: CGSize(width: 375, height: 750), to: url)
    }

    private static func mockBookCard(title: String, author: String, hue: Double, pinned: Bool, badge: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(hue: hue, saturation: 0.45, brightness: 0.62))
                    LinearGradient(
                        colors: [.white.opacity(0.22), .clear, .black.opacity(0.22)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    
                    VStack(alignment: .leading, spacing: 4) {
                        if pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                        Spacer(minLength: 0)
                        Text(title)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(8)
                }
                .frame(height: 142)
                .shadow(color: .black.opacity(0.12), radius: 5, y: 3)

                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.92), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(5)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ShelfInk.ink)
                    .lineLimit(1)
                Text(author)
                    .font(.system(size: 11))
                    .foregroundStyle(ShelfInk.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - 2. 阅读器正文排版截图
    private static func renderReader(to url: URL) {
        let theme = ReadingThemes.paper
        let view = PhoneFrame(title: "正文") {
            VStack(spacing: 0) {
                // 页眉状态
                HStack {
                    Text("09:41")
                    Spacer()
                    Text("第一章 雨夜的信封")
                        .lineLimit(1)
                    Spacer()
                    HStack(spacing: 3) {
                        Image(systemName: "battery.75")
                        Text("75%")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(theme.secondary.color)
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 12)

                // 正文排版
                VStack(alignment: .leading, spacing: 14) {
                    Text("第一章 雨夜的信封")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(theme.text.color)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 6)
                        .padding(.bottom, 10)

                    Text("\u{3000}\u{3000}那一夜雨很大，邮船没有靠岸。林书正准备关窗，石阶上却多了一只铁盒。盒盖用红线绑着，线是干的，雨却已经下了两个时辰。她在门口站了一会儿，确认不是哪条船把邮袋扔早了。")
                    Text("\u{3000}\u{3000}她把铁盒抱进柜台。里面只有一封信，信封正面写着给还在开灯的人。没有邮票，没有落款，纸却是新的。新得不像从海里来，倒像有人刚刚在灯下写完，顺手放到了雨够不着的地方。")
                    Text("\u{3000}\u{3000}林书把信举到灯下。墨迹没有晕开。她读了第一行，又把它放回桌上，好像多看一眼就会把别人的句子看成自己的。第一行只是请她把灯再留一夜，没有解释为什么。")
                    Text("\u{3000}\u{3000}窗外的灯把雨丝照成细细的金线。她在登记簿上写下雨夜，无名信，地址未完成。写到未完成三个字的时候，笔尖顿了一下。她忽然觉得这间邮局一直都在等这样一封信，等一句还没写完的地址。")
                }
                .font(.system(size: 17, weight: .regular, design: .serif))
                .lineSpacing(7)
                .foregroundStyle(theme.text.color)
                .padding(.horizontal, 24)

                Spacer(minLength: 0)

                // 页脚进度
                HStack {
                    Text("1 / 4")
                    Spacer()
                    Text("18%")
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(theme.secondary.color)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
            .background(theme.background.color)
        }

        saveImage(view, size: CGSize(width: 375, height: 750), to: url)
    }

    // MARK: - 3. 发现与书源浏览截图
    private static func renderDiscover(to url: URL) {
        let view = PhoneFrame(title: "发现", isDark: true) {
            VStack(spacing: 0) {
                // 顶部站点选择条
                HStack(spacing: 6) {
                    Text("香书小说网")
                        .font(.system(size: 17, weight: .semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.vertical, 10)

                // 频道分类 Tab
                HStack(spacing: 22) {
                    channelTabItem("全部", active: true)
                    channelTabItem("玄幻修真", active: false)
                    channelTabItem("都市言情", active: false)
                    channelTabItem("历史军事", active: false)
                    channelTabItem("科幻游戏", active: false)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

                // 二级属性筛选胶囊
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        filterPill("全部状态", active: true)
                        filterPill("连载中", active: false)
                        filterPill("已完结", active: false)
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        filterPill("综合排序", active: true)
                        filterPill("最新更新", active: false)
                        filterPill("总点击榜", active: false)
                        filterPill("高分好评", active: false)
                        Spacer()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

                Divider().background(Color.white.opacity(0.15))

                // 书籍列表流
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        discoverBookRow(title: "剑来", author: "烽火戏诸侯", intro: "大千世界，无奇不有。我陈平安，唯有一剑，可搬山，倒海，降妖，镇魔，敕神，摘星，断江，摧城，开天！", latest: "第一千二百一十四章 远游归来", tag: "连载 · 480万字", hue: 0.35)
                        discoverBookRow(title: "宿命之环", author: "爱潜水的乌贼", intro: "诡秘世界第二部。潮湿阴暗的旅馆房间里，卢米安从睡梦中惊醒，胸口隐隐作痛……", latest: "第八百九十二章 宿命的交错", tag: "连载 · 230万字", hue: 0.72)
                        discoverBookRow(title: "道诡异仙", author: "狐尾的笔", intro: "诡异的天道，异常的仙佛，到底是精神病还是真实的世界？李火旺分不清，他真的分不清……", latest: "完本感言与番外", tag: "完结 · 215万字", hue: 0.02)
                    }
                    .padding(16)
                }

                Spacer(minLength: 0)

                // 底部栏
                HStack(spacing: 0) {
                    VStack(spacing: 3) {
                        Image(systemName: "books.vertical")
                            .font(.system(size: 20))
                        Text("书架")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(Color.white.opacity(0.55))

                    VStack(spacing: 3) {
                        Image(systemName: "safari.fill")
                            .font(.system(size: 20))
                        Text("发现")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(ShelfInk.accent)
                }
                .padding(.top, 8)
                .padding(.bottom, 12)
                .background(Color.black)
                .overlay(alignment: .top) {
                    Divider().background(Color.white.opacity(0.12))
                }
            }
            .background(Color.black)
        }

        saveImage(view, size: CGSize(width: 375, height: 750), to: url)
    }

    private static func channelTabItem(_ title: String, active: Bool) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 14, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color.white : Color.white.opacity(0.55))
            Circle()
                .fill(active ? ShelfInk.accent : Color.clear)
                .frame(width: 4, height: 4)
        }
    }

    private static func filterPill(_ title: String, active: Bool) -> some View {
        Text(title)
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(active ? Color(red: 0.2, green: 0.6, blue: 1.0).opacity(0.25) : Color.white.opacity(0.08), in: Capsule())
            .foregroundStyle(active ? Color(red: 0.4, green: 0.75, blue: 1.0) : Color.white.opacity(0.7))
    }

    private static func discoverBookRow(title: String, author: String, intro: String, latest: String, tag: String, hue: Double) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(hue: hue, saturation: 0.45, brightness: 0.62))
                .frame(width: 58, height: 78)
                .overlay {
                    Text(title)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .multilineTextAlignment(.center)
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(tag)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
                Text(author)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.65))
                Text(intro)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(2)
                Text("最新：" + latest)
                    .font(.system(size: 11))
                    .foregroundStyle(ShelfInk.accent)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 4. 书源管理与换源列表截图
    private static func renderSources(to url: URL) {
        let view = PhoneFrame(title: "书源管理", isDark: true) {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("书源管理")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    HStack(spacing: 8) {
                        Text("已启用 5 / 8")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

                // Search Bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.white.opacity(0.4))
                    Text("搜索内置书源或添加新源…")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.white.opacity(0.4))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .padding(.bottom, 14)

                // Source List
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        sourceCardRow(name: "69书吧", url: "https://www.69shu.cx", weight: 10, ping: "115ms", type: "目录站 · 正文极速", enabled: true)
                        sourceCardRow(name: "笔趣阁", url: "https://www.bqg.org", weight: 9, ping: "152ms", type: "规则站 · 全本覆盖", enabled: true)
                        sourceCardRow(name: "顶点小说", url: "https://www.23dd.cc", weight: 8, ping: "188ms", type: "目录站 · 连载稳定", enabled: true)
                        sourceCardRow(name: "飘天文学", url: "https://www.piaotian.com", weight: 7, ping: "210ms", type: "备选源 · 章节完备", enabled: true)
                        sourceCardRow(name: "香色闺阁精选", url: "本地订阅 (24条规则)", weight: 6, ping: "离线", type: "XBS加密源 · 智能解析", enabled: true)
                        sourceCardRow(name: "测试站 (备用)", url: "https://read.backup.org", weight: 3, ping: "超时", type: "备选源", enabled: false)
                    }
                    .padding(.horizontal, 16)
                }

                Spacer(minLength: 0)

                // Bottom Action
                HStack(spacing: 12) {
                    Button(action: {}) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                            Text("新建书源")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }

                    Button(action: {}) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.doc.fill")
                            Text("导入规则 (JSON/XBS)")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ShelfInk.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(ShelfInk.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(16)
            }
            .background(Color(red: 0.1, green: 0.1, blue: 0.12))
        }

        saveImage(view, size: CGSize(width: 375, height: 750), to: url)
    }

    private static func sourceCardRow(name: String, url: String, weight: Int, ping: String, type: String, enabled: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("权重 \(weight)")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.1), in: Capsule())
                        .foregroundStyle(Color.white.opacity(0.7))
                    Text(ping)
                        .font(.system(size: 10))
                        .foregroundStyle(enabled ? Color.green : Color.red)
                }
                Text(url)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)
                Text(type)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.35))
            }

            Spacer()

            Toggle("", isOn: .constant(enabled))
                .toggleStyle(SwitchToggleStyle(tint: ShelfInk.accent))
                .labelsHidden()
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 模拟精致手机外壳
private struct PhoneFrame<Content: View>: View {
    var title: String
    var isDark: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            Color.clear
            VStack(spacing: 0) {
                // Status bar
                HStack {
                    Text("09:41")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    // Dynamic Island pill
                    Capsule()
                        .fill(isDark ? Color.black : Color.black.opacity(0.9))
                        .frame(width: 96, height: 26)
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "cellularbars")
                        Image(systemName: "wifi")
                        Image(systemName: "battery.100")
                    }
                    .font(.system(size: 12))
                }
                .foregroundStyle(isDark ? .white : .black)
                .padding(.horizontal, 22)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .background(isDark ? Color.black : ShelfInk.paper)

                content()

                // Home indicator
                ZStack {
                    (isDark ? Color.black : ShelfInk.paper)
                    Capsule()
                        .fill((isDark ? Color.white : Color.black).opacity(0.35))
                        .frame(width: 120, height: 4)
                        .padding(.vertical, 6)
                }
                .frame(height: 18)
            }
            .clipShape(RoundedRectangle(cornerRadius: 38, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 38, style: .continuous)
                    .stroke(isDark ? Color.white.opacity(0.18) : Color.black.opacity(0.12), lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            .padding(14)
        }
    }
}
#endif
