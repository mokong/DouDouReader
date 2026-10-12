# 豆豆阅读

豆豆阅读（DouDouReader）是一个本地小说阅读器，用 SwiftUI 写，能在 iPhone、iPad、Mac 和 Apple Vision 上打开。书架上的书来自导入的 txt 或 EPUB，也可以从书源目录按章下载。

## 功能

- 导入 txt 和 EPUB。txt 编码按 UTF-8（含 BOM）、UTF-16、GB18030 识别。EPUB 读取书名、作者和目录，按章节转成同一套阅读文本；标题不必写成「第…章」。单本上限 40MB。文件名当作书名，txt 正文前 30 行里的「作者」会记成作者。
- 内置一篇示例小说，用来直接打开阅读器。
- 按章节标题拆分正文。识别 `第…章/回/节/卷/部/集`、`序章`、`楔子`、`前言`、`引子`、`尾声`、`后记`、`番外` 和 `Chapter N`。没有标题时整本算一章。
- 主页底部是书架和发现。书架支持置顶，以及按最近阅读、加入时间、书名排序。封面和列表可以切换。右上角搜索会同时查找已启用书源和书架上的书，并记住搜索历史。加号只导入本地书籍。发现页浏览当前书源。书架上的在线书可以单本「检查更新」或一键「检查全部更新」：后台重新拉取目录，比对最新一章，有新章节时封面/列表显示橙色角标；书源失效或网络异常会给出明确反馈。
- 阅读器使用 TextKit 1 分页。翻页有仿真、左右、上下和无动画。点页面中央唤出工具栏。支持极简模式：隐藏页眉页脚和工具栏，沉浸阅读；边缘点按仍可翻页，中间点按唤出控件。
- 目录、书内搜索、书签。阅读页可拖拽选中文字并复制，右键菜单支持用选中词直接书内搜索（范围为已加载章节）。
- 排版：字号、字体、行距、段距、首行缩进、字距、对齐、边距、简繁转换、屏蔽词。
- 主题：自动、纸白、护眼、羊皮、烟灰、夜间。自动主题跟随系统外观。书架本身固定为暖纸色。
- 自动翻页、定时停止、屏幕常亮、亮度。页眉页脚可显示时间、电量、章节名和进度。
- 系统语音朗读，按页或按章，后台可继续播放。可在系统可用中文音色中选择朗读音色（默认 zh-CN），语速可调范围 0.32–0.80。
- 导入 TTF / OTF 作为阅读字体。
- 书源：内置一批目录站，支持粘贴「阅读 3.0」或香色闺阁的书源 JSON，也可以导入本地 `.xbs`（香色加密书源）/ `.json` 文件或按网络地址订阅。书源管理页可按分组浏览、启停、调整权重、搜索内置书源目录、重拉订阅同步规则。在线书先保存第一章，翻到已加载章节的最后一页时再请求下一章。同一本书再次打开会回到已下载的进度。阅读器内的「缓存」支持一键全本缓存：4 路并发、进度条显示、可随时停止、已缓存章节自动跳过（断点续下）；书架「整理 → 缓存管理」可查看各书缓存占用，按书清理或一键清理全部章节缓存。

## 环境

| 项目 | 值 |
| --- | --- |
| 显示名 | 豆豆阅读 |
| Bundle ID | `com.morganwang.DouDouReader` |
| 版本 | 1.0 |
| 语言 | Swift 5 |
| 系统 | iOS 17.6、macOS 15.6、visionOS 26.6 |
| 工程 | `DouDouReader.xcodeproj` |

用当前的 Xcode 打开工程即可。签名是自动管理。

## 运行

1. 打开 `DouDouReader.xcodeproj`。
2. Scheme 选择 `DouDouReader`。
3. 运行目标选 iPhone 模拟器、My Mac 或 visionOS 模拟器。

命令行编译 Mac 版：

```bash
xcodebuild -project DouDouReader.xcodeproj -scheme DouDouReader -destination 'platform=macOS' -configuration Debug build
```

`DouDouReader/` 使用 Xcode 的同步目录。在这个目录里新增的 Swift 文件会自动编进目标，不用改 `project.pbxproj`。

## 自检

启动参数 `-selfTest` 会跑本地逻辑检查（分章、分页、编码、简繁、书源解析、ATS 配置等），然后退出。通过时控制台打印 `LOGIC_OK`。

在 Scheme → Run → Arguments 里加上 `-selfTest`，或给已编译的 Mac 应用传这个参数。

`-openSources` 会在启动后直接进入发现页。

## 目录

```
DouDouReader-Info.plist          文档类型、后台音频、ATS
DouDouReader/
  App/                           入口、系统外观
  Library/                       书架、书目、导入、示例小说
  Text/                          解码、分章、简繁、分页
  Reader/                        阅读器、排版、主题、朗读
  BookSource/                    书源规则、目录抓取、预设站点
  Diagnostics/                   -selfTest 用的逻辑检查
  Assets.xcassets/
```

## 数据

书架、书签和书源存在 SwiftData 里。正文和导入的字体写在本应用的 Application Support 目录：

```
Application Support/DouDouReader/Books
Application Support/DouDouReader/Fonts
```

阅读进度跟着这本书保存在本机。

## 书源和网络

部分预设站点是明文 HTTP。`DouDouReader-Info.plist` 里 `NSAppTransportSecurity` 只保留 `NSAllowsArbitraryLoads`。不要再加 `NSAllowsLocalNetworking`、`NSAllowsArbitraryLoadsInWebContent` 或 `NSAllowsArbitraryLoadsForMedia`。从 iOS 10 和 macOS 10.12 起，这些键存在时系统会忽略全局放行，HTTP 书源会被 ATS 拦住。

手动填写的书源地址只接受 HTTPS，以及本机和局域网的 HTTP。预设目录的请求按站点自己的地址发出。
