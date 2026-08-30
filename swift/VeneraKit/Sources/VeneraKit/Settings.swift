import Foundation

/// 设置项默认值。与 Flutter 版 `Settings._data`（appdata.dart L338-518）
/// 逐键对齐：键名、默认值与值类型必须保持一致，否则 syncdata.json 与
/// `.venera` 备份的跨版本互通会被破坏。
public enum Settings {
    /// 用户自定义图片处理脚本默认实现（原样保留 JS 源码）。
    public static let defaultCustomImageProcessing = """
    /**
     * Process an image
     * @param image {ArrayBuffer} - The image to process
     * @param cid {string} - The comic ID
     * @param eid {string} - The episode ID
     * @param page {number} - The page number
     * @param sourceKey {string} - The source key
     * @returns {Promise<ArrayBuffer> | {image: Promise<ArrayBuffer>, onCancel: () => void}} - The processed image
     */
    async function processImage(image, cid, eid, page, sourceKey) {
        let futureImage = new Promise((resolve, reject) => {
            resolve(image);
        });
        return futureImage;
    }
    """

    public static let defaults: [String: JSON] = [
        // 显示 / 主题
        "comicDisplayMode": .string("detailed"), // detailed, brief
        "comicTileScale": .double(1.00), // 0.75-1.25
        "color": .string("system"), // red, pink, purple, green, orange, blue, system
        "theme_mode": .string("system"), // light, dark, system
        "newFavoriteAddTo": .string("end"), // start, end
        "moveFavoriteAfterRead": .string("none"), // none, end, start
        "proxy": .string("system"), // direct, system, host:port
        "explore_pages": .array([]),
        "categories": .array([]),
        "favorites": .array([]),
        "searchSources": .null,
        "showFavoriteStatusOnTile": .bool(true),
        "showHistoryStatusOnTile": .bool(false),
        "showReadLaterStatusOnTile": .bool(true),
        "blockedWords": .array([]),
        "blockedTags": .array([]),
        "blockedCommentWords": .array([]),
        "defaultSearchTarget": .null,
        "comicListDisplayMode": .string("paging"), // paging, continuous
        "localFavoritesFirst": .bool(true),
        "initialPage": .string("0"),
        "language": .string("system"), // system, zh-CN, zh-TW, en-US
        "showSystemStatusBar": .bool(false),
        "appLauncherIcon": .string("default"),

        // 阅读器
        "autoPageTurningInterval": .int(5), // seconds
        "readerMode": .string("galleryLeftToRight"),
        "enableContinuousChapterReading": .bool(true),
        "readerScreenPicNumberForLandscape": .int(1), // 1-5
        "readerScreenPicNumberForPortrait": .int(1), // 1-5
        "enableTapToTurnPages": .bool(true),
        "reverseTapToTurnPages": .bool(false),
        "enableCustomTapZones": .bool(false),
        "tapZoneTop": .string("prev"),
        "tapZoneBottom": .string("next"),
        "tapZoneLeft": .string("none"),
        "tapZoneRight": .string("none"),
        "enablePageAnimation": .bool(true),
        "enablePredictiveBack": .bool(true),
        "enableTurnPageByVolumeKey": .bool(true),
        "enableClockAndBatteryInfoInReader": .bool(true),
        "showPageNumberInReader": .bool(true),
        "showSingleImageOnFirstPage": .bool(false),
        "enableDoubleTapToZoom": .bool(true),
        "enableLongPressToZoom": .bool(true),
        "longPressZoomPosition": .string("press"), // press, center
        "readerScrollSpeed": .double(1.0), // 0.5-3.0
        "readerCenterPageOnTurn": .bool(false),
        "readerPageSpacing": .double(0.0), // 0-50
        "galleryFillScreen": .bool(false),
        "readerBackgroundColor": .string("system"), // system, white, gray, black, sepia, green
        "readerNightMode": .bool(false),
        "readerNightModeFollowSystem": .bool(false),
        "readerNightModeColor": .string("warm"), // warm, black, red
        "readerNightModeIntensity": .double(0.45), // 0.1-0.85
        "enableReaderImageEnhance": .bool(false),
        "readerImageEnhanceStrength": .double(0.5),
        "readerImageEnhanceClarity": .double(0.0),
        "readerImageEnhanceContrast": .double(0.0),
        "readerImageEnhanceVibrance": .double(0.0),
        "autoFullscreenOnRead": .bool(false),
        "preloadImageCount": .int(4),
        "limitImageWidth": .bool(true),
        "imageWidthPercent": .int(70),
        "reverseChapterOrder": .bool(false),
        "showChapterComments": .bool(true),
        "showChapterCommentsAtEnd": .bool(false),
        "commentsFontSize": .double(14.0),

        // 收藏 / 稍后读
        "autoRemoveFromReadLater": .bool(false),
        "quickFavorite": .null,
        "onClickFavorite": .string("viewDetail"), // viewDetail, read
        "autoFavoriteCover": .bool(false),
        "quickCollectImage": .string("No"), // No, DoubleTap, Swipe
        "autoCloseFavoritePanel": .bool(false),

        // 屏蔽 / 评论
        "autoAddLanguageFilter": .string("none"), // none, chinese, english, japanese

        // 网络
        "sni": .bool(true),
        "enableDnsOverrides": .bool(false),
        "dnsOverrides": .object([:]),
        "ignoreBadCertificate": .bool(false),
        "verboseNetworkLog": .bool(false),
        "enableCustomImageProcessing": .bool(false),
        "customImageProcessing": .string(defaultCustomImageProcessing),

        // 下载 / 缓存
        "cacheSize": .int(2048), // MB
        "downloadThreads": .int(5),
        "maxParallelDownloads": .int(1), // 1-3
        "downloadWifiOnly": .bool(false),

        // WebDAV / 同步
        "webdav": .array([]), // 空 = 未配置
        "syncLocalComics": .bool(true),
        "syncLocalComicImages": .bool(true),
        "webdavUseProxy": .bool(true),
        "webdavBackupRetention": .int(10),
        "disableSyncFields": .string(""),
        "dataVersion": .int(0),
        "deviceId": .string(""),

        // 漫画源
        "comicSourceListUrl": .string(""), // 旧版单目录 URL，已由 libraries 取代
        "comicSourceLibraries": .array([]),
        "comicSourceProvenance": .object([:]),
        "comicSourceLibrariesMigrated": .bool(false),

        // 更新 / 其他
        "checkUpdateOnStart": .bool(true),
        "autoCleanHistoryDays": .string("0"),
        "minimizeToTray": .bool(false), // 桌面端专用
        "requireDisclaimerConsent": .bool(false),
        "disclaimerConsented": .bool(false),
        "batteryOptimizationPrompted": .bool(false),
        "authorizationRequired": .bool(false),
        "appLockType": .string("biometric"), // biometric, pin, password, pattern
        "appLockCredential": .null, // {salt, hash}
        "followUpdatesFolder": .null,
        "comicSpecificSettings": .object([:]),
        "deviceSpecificSettings": .object([:]),

        // 图片翻译（子系统延后至 M7；键与默认值先行保留以维持 syncdata 兼容）
        "enableImageTranslation": .bool(false),
        "imageTranslationSource": .string("auto"),
        "imageTranslationTarget": .string("zh"),
        "imageTranslationHfEndpoint": .string("https://huggingface.co"),
        "imageTranslationLlmUrl": .string(""),
        "imageTranslationLlmKey": .string(""),
        "imageTranslationLlmModel": .string(""),
        "imageTranslationProviders": .array([]),
        "imageTranslationActiveProviderId": .string(""),
        "imageTranslationPerformancePreset": .string("balanced"),
        "imageTranslationPreBatchPages": .int(1),
        "imageTranslationOcrWorkers": .int(0),
        "imageTranslationImageConcurrency": .int(3),
        "imageTranslationLlmConcurrency": .int(2),
        "imageTranslationInpaintMode": .string("smart"), // patch, smart
    ]
}
