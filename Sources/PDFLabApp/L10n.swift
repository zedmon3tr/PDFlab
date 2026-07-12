import Foundation
import PDFLabCore

/// 全部 UI 文案的集中入口。所有用户可见字符串必须经 `L10n.t(_:)` 解析,
/// 依据持久化的 "uiLanguage" 设置("system" 时跟随 `Locale.current`)返回中/英文。
enum L10n {
    /// 按 key 取当前语言文案;未知 key 原样返回(便于排查漏登记的 key)。
    static func t(_ key: String) -> String {
        guard let pair = strings[key] else { return key }
        return isChinese ? pair.zh : pair.en
    }

    /// 布局测试同时验证两套正式文案，不依赖测试机当前语言。
    static func allLocalizedValues(_ key: String) -> [String] {
        guard let pair = strings[key] else { return [key] }
        return [pair.zh, pair.en]
    }

    /// PDFLabError → 用户可读文案(带关联值上下文)。
    static func message(for error: PDFLabError) -> String {
        switch error {
        case .fileUnreadable: return t("error.fileUnreadable")
        case .notAPDF: return t("error.notAPDF")
        case .encryptedPDFWrongPassword: return t("error.encryptedPDFWrongPassword")
        case .noTextRecognized: return t("error.noTextRecognized")
        case .unsupportedLanguage(let detected): return t("error.unsupportedLanguage") + " (\(detected))"
        case .languagePackMissing: return t("error.languagePackMissing")
        case .engineInvalidKey: return t("error.engineInvalidKey")
        case .engineRateLimited: return t("error.engineRateLimited")
        case .engineUnavailable(let engineID): return t("error.engineUnavailable") + " (\(engineID))"
        case .networkError(let detail): return t("error.networkError") + " (\(detail))"
        case .exportWriteFailed(let detail): return t("error.exportWriteFailed") + " (\(detail))"
        case .cancelled: return t("error.cancelled")
        }
    }

    /// 当前 UI 是否为中文:显式 "zh"/"en" 优先,"system" 跟随系统语言。
    static var isChinese: Bool {
        switch UserDefaults.standard.string(forKey: "uiLanguage") ?? "system" {
        case "zh": return true
        case "en": return false
        default: return Locale.current.language.languageCode?.identifier == "zh"
        }
    }

    private static let strings: [String: (zh: String, en: String)] = [
        // 主界面
        "app.name": ("PDFlab", "PDFlab"),
        "main.view": ("查看", "View"),
        "main.view.subtitle": ("打开 PDF,本地中英对照阅读", "Open a PDF for parallel reading"),
        "main.translate": ("翻译", "Translate"),
        "main.translate.subtitle": ("翻译整份 PDF 并导出", "Translate a whole PDF and export"),
        "main.convert": ("转换", "Convert"),
        "main.convert.subtitle": ("PDF、Markdown、Word 格式转换", "Convert PDF, Markdown, Word"),
        "main.convert.disabled": ("功能规划中", "Coming soon"),

        // 查看模块
        "viewer.addTab": ("再打开一个文档", "Open another document"),
        "viewer.closeTab": ("关闭", "Close"),
        "viewer.tabsFull": ("最多同时打开 2 个文档", "Up to 2 documents can be open at once"),
        "viewer.sideBySide": ("对照浏览", "Compare"),
        "viewer.sideBySide.disabled": ("打开两个 PDF 后可使用对照浏览", "Open two PDFs to compare"),
        "viewer.viewMode": ("视图模式", "View Mode"),
        "viewer.modeSingle": ("单看", "Single"),
        "viewer.modeSideBySide": ("对照浏览", "Compare"),
        "viewer.leftRatio": ("左侧", "Left"),
        "viewer.rightRatio": ("右侧", "Right"),
        "viewer.ratio.help": ("调节该侧滚动比例(50%–200%)", "Adjust this pane's scroll ratio (50%–200%)"),
        "viewer.resetRatio": ("重置两侧滚动比例为 100%", "Reset both scroll ratios to 100%"),
        "viewer.divider.resize": ("拖动调整宽度", "Resize"),
        "viewer.pageLayout": ("页面布局", "Page Layout"),
        "viewer.layoutTwoPage": ("双页并排查看", "Two-Page Continuous"),
        "viewer.layoutContinuous": ("滚动查看", "Continuous"),
        "viewer.zoom": ("缩放", "Zoom"),
        "viewer.zoomOut": ("缩小", "Zoom Out"),
        "viewer.zoomIn": ("放大", "Zoom In"),
        "viewer.zoomActualSize": ("实际大小", "Actual Size"),
        "viewer.zoomFitPage": ("适应页面", "Fit Page"),
        "viewer.zoomFitWidth": ("适应宽度", "Fit Width"),
        "viewer.zoomFitHeight": ("适应高度", "Fit Height"),
        "viewer.unsupported": ("暂不支持该文件格式", "This file format is not supported"),
        "viewer.openFailed": ("打开失败", "Failed to open"),
        "viewer.noDocument": ("等待打开文档", "Waiting for a document"),
        "viewer.password.title": ("PDF 密码", "PDF Password"),
        "viewer.password.prompt": ("输入密码", "Enter password"),
        "viewer.password.open": ("打开", "Open"),

        // 翻译模块
        "translate.title": ("翻译", "Translate"),
        "translate.chooseFile": ("选择 PDF", "Choose PDF"),
        "translate.idle.title": ("选择或拖入 PDF", "Choose or drop a PDF"),
        "translate.openFailed": ("无法打开文件", "Could not open file"),
        "translate.password.title": ("PDF 密码", "PDF Password"),
        "translate.softLimit.title": ("预计耗时较长", "This may take a while"),
        "translate.softLimit.message": ("文档超过建议上限,是否继续?", "The document exceeds the suggested limit. Continue?"),
        "translate.pages": ("页数", "Pages"),
        "translate.size": ("大小", "Size"),
        "translate.unsupportedLanguage.title": ("仅支持中英文档", "Only Chinese and English documents are supported"),
        "translate.unsupportedLanguage.message": ("请选择源文语言后重试", "Choose the source language and retry"),
        "translate.direction.english": ("英文", "English"),
        "translate.direction.chinese": ("中文", "Chinese"),
        "translate.content": ("内容", "Content"),
        "translate.content.bilingual": ("双文", "Bilingual"),
        "translate.content.translationOnly": ("仅译文", "Translation Only"),
        "translate.content.extractionOnly": ("仅提取", "Extraction Only"),
        "translate.settings.title": ("基础设置", "Basic Settings"),
        "translate.ocrLanguage": ("识别语言", "OCR Language"),
        "translate.ocrLanguage.help": ("识别语言会影响扫描版 PDF 的文字提取效果。", "OCR language affects text extraction for scanned PDFs."),
        "translate.ocrLanguage.autoFormat": ("%@（自动）", "%@ (Auto)"),
        "translate.ocrLanguage.automatic": ("自动", "Auto"),
        "translate.ocrLanguage.english": ("英文", "English"),
        "translate.ocrLanguage.simplifiedChinese": ("中文", "Chinese"),
        "translate.ocrLanguage.traditionalChinese": ("繁体中文", "Traditional Chinese"),
        "translate.ocrLanguage.japanese": ("日文", "Japanese"),
        "translate.ocrLanguage.korean": ("韩文", "Korean"),
        "translate.targetLanguage": ("翻译成", "Translate To"),
        "translate.targetLanguage.simplifiedChinese": ("简体中文", "Simplified Chinese"),
        "translate.targetLanguage.english": ("英文", "English"),
        "translate.format": ("格式", "Format"),
        "translate.pageMode": ("分页", "Page Mode"),
        "translate.pageMode.pageAligned": ("按页", "Page Aligned"),
        "translate.pageMode.continuous": ("连续", "Continuous"),
        "translate.start": ("开始翻译", "Start"),
        "translate.running": ("正在准备", "Preparing"),
        "translate.cancelRun": ("取消", "Cancel"),
        "translate.stage.parsing": ("解析", "Parsing"),
        "translate.stage.ocr": ("OCR", "OCR"),
        "translate.stage.translating": ("翻译", "Translating"),
        "translate.stage.composing": ("组装", "Composing"),
        "translate.page.prefix": ("第", "Page"),
        "translate.remaining.estimating": ("正在估算剩余时间", "Estimating time remaining"),
        "translate.remaining.lessThanMinute": ("剩余不足 1 分钟", "Less than 1 min remaining"),
        "translate.remaining.seconds": ("剩余约 %d 秒", "About %d sec remaining"),
        "translate.remaining.minutes": ("剩余约 %d 分钟", "About %d min remaining"),
        "translate.remaining.hours": ("剩余约 %d 小时", "About %d hr remaining"),
        "translate.remaining.hoursMinutes": ("剩余约 %d 小时 %d 分钟", "About %d hr %d min remaining"),
        "translate.save": ("保存", "Save"),
        "translate.backToOptions": ("返回选项", "Back to Options"),
        "translate.saved.title": ("已保存", "Saved"),
        "translate.openInViewer": ("对照浏览", "Compare"),
        "translate.saveAgain": ("重新保存", "Save Again"),
        "translate.newFile": ("新文件", "New File"),
        "translate.failed": ("翻译失败", "Translation Failed"),
        "translate.saveFailed": ("保存失败", "Save Failed"),
        "translate.preview.previousPage": ("上一页", "Previous Page"),
        "translate.preview.nextPage": ("下一页", "Next Page"),
        "translate.engineSuggestion": ("建议切换本地翻译或其他引擎。", "Try switching to on-device translation or another engine."),
        "translate.lowQualityPages": ("识别质量低的页:", "Low quality OCR pages:"),
        "translate.preview.page": ("第", "Page"),

        // 历史记录
        "history.title": ("最近打开", "Recent Files"),
        "history.empty": ("暂无最近打开的文件", "No recent files"),
        "history.clear": ("清空历史", "Clear History"),
        "history.sizeUnknown": ("大小未知", "Unknown size"),
        "history.remove": ("从列表中移除", "Remove from List"),
        "history.missing": ("文件已被移动或删除", "The file has been moved or deleted"),
        "history.missing.remove": ("移除记录", "Remove Entry"),

        // 通用
        "common.cancel": ("取消", "Cancel"),
        "common.confirm": ("确认", "Confirm"),
        "common.done": ("完成", "Done"),

        // 设置 - 分区
        "settings.title": ("设置", "Settings"),
        "settings.menu": ("设置…", "Settings…"),
        "settings.open.help": ("打开设置", "Open Settings"),
        "settings.tab.general": ("设置", "Settings"),
        "settings.tab.services": ("服务", "Services"),
        "settings.tab.about": ("关于", "About"),
        "settings.appearance": ("外观", "Appearance"),
        "settings.appearance.system": ("跟随系统", "System"),
        "settings.appearance.light": ("浅色", "Light"),
        "settings.appearance.dark": ("深色", "Dark"),
        "settings.language": ("界面语言", "Interface Language"),
        "settings.language.system": ("跟随系统", "System"),
        "settings.language.zh": ("中文", "中文"),
        "settings.language.en": ("English", "English"),
        "settings.engine": ("翻译引擎", "Translation Engine"),
        "settings.data": ("数据管理", "Data Management"),
        "settings.service.listTitle": ("翻译服务", "Translation Services"),
        "settings.service.enabled": ("已启用", "Enabled"),
        "settings.service.noConfiguration": ("%@ 没有可供配置的选项", "%@ has no configurable options"),

        // 设置 - 引擎名
        "engine.apple": ("本地翻译", "On-Device Translation"),
        "engine.llm": ("LLM 接口", "LLM API"),
        "engine.google": ("Google", "Google"),
        "engine.deepl": ("DeepL", "DeepL"),
        "engine.youdao": ("有道", "Youdao"),
        "engine.unofficialBadge": ("非官方接口,可能不稳定", "Unofficial API, may be unstable"),

        // 设置 - 凭据字段
        "settings.llm.baseURL": ("接口地址 (baseURL)", "Base URL"),
        "settings.llm.model": ("模型", "Model"),
        "settings.llm.apiKey": ("API Key", "API Key"),
        "settings.testConnection": ("测试连接", "Test Connection"),
        "settings.testConnection.testing": ("正在测试…", "Testing…"),
        "settings.testConnection.success": ("连接成功", "Connection succeeded"),
        "settings.testConnection.failure": ("连接失败", "Connection failed"),

        // 关于
        "about.version": ("版本", "Version"),
        "about.blurb": (
            "本地 PDF 对照查看与中英互译导出工具:查看模块左右对照阅读,翻译模块 OCR/提取并导出 PDF、Word、Markdown。",
            "A local tool for side-by-side PDF reading and Chinese–English translation: view documents in dual panes, or OCR/extract and export to PDF, Word, and Markdown."
        ),

        // 检查更新
        "update.check": ("检测更新", "Check for Updates"),
        "update.checking": ("正在检测…", "Checking…"),
        "update.autoCheck": ("启动时自动检测更新", "Automatically check for updates at launch"),
        "update.upToDate": ("当前已是最新版本", "You're up to date"),
        "update.available": ("发现新版本", "New version available:"),
        "update.download": ("下载更新", "Download Update"),
        "update.skip": ("跳过此版本", "Skip This Version"),
        "update.downloading": ("正在下载更新…", "Downloading update…"),
        "update.downloaded": ("安装包已打开,请将 PDFlab 拖入 Applications 完成更新",
                              "Installer opened — drag PDFlab into Applications to finish updating"),
        "update.alert.title": ("发现新版本", "New Version Available"),
        "update.alert.view": ("前往查看", "View Details"),
        "update.alert.close": ("关闭", "Close"),

        // 隐私提示
        "privacy.cloudNotice": (
            "文档内容将发送至第三方翻译服务,请确认文档不含敏感信息后继续。",
            "Document content will be sent to a third-party translation service. Please confirm the document contains no sensitive information before continuing."
        ),
        "privacy.cloudNotice.title": ("云端翻译提示", "Cloud Translation Notice"),

        // 错误(与 PDFLabError 各 case 一一对应)
        "error.fileUnreadable": ("无法读取文件", "The file could not be read"),
        "error.notAPDF": ("所选文件不是 PDF", "The selected file is not a PDF"),
        "error.encryptedPDFWrongPassword": ("PDF 已加密或密码错误", "The PDF is encrypted or the password is incorrect"),
        "error.noTextRecognized": ("未能识别出任何文字", "No text could be recognized"),
        "error.unsupportedLanguage": ("暂不支持该文档语言", "The document language is not supported"),
        "error.languagePackMissing": ("本地翻译语言包缺失,请在系统设置中下载", "The on-device language pack is missing; download it in System Settings"),
        "error.engineInvalidKey": ("密钥无效,请检查凭据", "Invalid credentials; please check your keys"),
        "error.engineRateLimited": ("请求过于频繁,请稍后重试", "Rate limited; please try again later"),
        "error.engineUnavailable": ("翻译引擎暂不可用", "The translation engine is unavailable"),
        "error.networkError": ("网络错误", "Network error"),
        "error.exportWriteFailed": ("导出写入失败", "Failed to write the exported file"),
        "error.cancelled": ("已取消", "Cancelled"),
        "error.updateUnavailable": ("更新服务暂不可用,请稍后重试", "Update service is unavailable. Please try again later."),
    ]
}
