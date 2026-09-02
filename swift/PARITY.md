# VeneraX Swift 迁移功能对等清单（PARITY）

> **实现状态审计（2026-08-29）**：
> 下方“✅”仅表示已有代码路径或局部测试，不等同于 Flutter 版逐项真机验收；“⬜”与备注中的延后项仍是实际功能缺口。
>
> **高阶体验与周边功能专项打磨（截至 2026-08-29）**：
> ㉜ 连续阅读模式跨章平滑无缝连读落地（`ContinuousPageItem` + 自动预拉取追加 + 章节分隔标头），
> 彻底解决竖向/横向条漫滑到底部时的切章重置感。
> ㉝ 多源聚合搜索（`AggregatedSearchView`）与跨源换源搜索（`RelatedSourcesSheet`）全量落地。
> ㉞ 阅读统计页（`ReadingStatisticsView`）基于 Swift Charts 落地（近 7 天趋势柱状图/作品分布/时长卡片/排序/清空）。
> ㉟ 追更监控系统（`FollowUpdatesManager` + `FollowUpdatesView`）全量落地（更新检测/未读徽标/一键检查）。
> ㊱ Cloudflare 5秒盾挑战拦截与 WKWebView 解盾写回 `CookieStore` 闭环落地。
> ㊲ VeneraKit 单元测试达到 90/90 通过；iOS 模拟器 Debug 构建与启动验证正常；仍未完成真机压力与发布验收。

以 Flutter 版 v2.2.11 功能基线逐项对照 Swift 原生实现进度。
状态：⬜ 未开始 · 🚧 进行中 · ✅ 完成 · ⏸ 已确认延后（M7+） · ➖ iOS 端不适用

> **2026-08-29 任务历史补充**：任务中心新增清空历史二次确认，运行中任务保留；追更、源更新、源迁移历史均设有数量上限或清理入口，降低长期列表膨胀。
> **2026-09-02 功能组整合**：启动时更新检查、扫码导入同步配置、PDF/EPUB 与本地漫画批量导出、图片翻译最小闭环、WebDAV 漫画库迁移和阅读器双页边界已接入代码；完整 App 构建与 117 个 VeneraKit 测试通过。PDF/EPUB、扫码、图片翻译和 WebDAV 漫画库迁移仍需实体设备/真实服务器端到端验收，图片翻译尚未包含文本擦除与 inpaint。
> **2026-09-02 WebDAV 兼容补充**：Swift 端现读取 Flutter 的 `webdavComicLibraries`，兼容旧 `webdavLibraries`，对齐稳定 library ID、`detectLinkedFolders`、多平台 `.venera` 版本比较、异常上传认领、按平台保留策略、基础路径编码和有限重试；VPS 真实写入与 Flutter 端实际读取仍需隔离测试目录验收。
> **2026-08-29 WebDAV 任务补充**：WebDAV 上传、普通下载和指定备份下载已接入 `DataSyncManager`，任务中心显示阶段/进度、历史、取消和清理；同步操作不再只由设置页持有临时 `Task`。`WebDAVClient` 增加 HTTP(S) URL 校验、请求/资源超时、取消检查和 WebDAV `Depth`/`Content-Type` 请求头。
> **2026-08-29 源目录并发补充**：目录抓取、可用更新列表和批量源更新的共享状态已增加锁保护，减少源市场刷新与任务中心并发读取时的数据竞争；仍需真实网络源和真机长时间验证。
> **2026-08-29 源更新补充**：在线源目录“Update All”已接入可持久化摘要任务、逐源进度/失败状态和取消，任务中心新增源更新类别；翻译任务和部分本地漫画批量导入导出语义仍未完全对齐。
> **2026-08-29 任务中心补充**：源迁移任务历史限制为最近 100 条，同一迁移组合不会重复启动，部分失败会保留为 `failed` 状态；
> **2026-08-29 任务中心补充**：追更检查已从页面临时任务提升为可持久化摘要任务，接入任务中心运行中/历史列表，支持取消与失败状态；源迁移部分失败不再误报完成。仍未达到 Flutter 全部后台任务类型和真正后台恢复的完整对等。
> **2026-08-29 稳定性补充**：连续阅读触底加载改为合并且可取消的单一任务，避免 `Lazy*` 重建导致下一章节重复并发请求；追更检查取消后确保页面状态复位。此项降低任务堆积风险，但仍不构成真机长时间无泄漏/无卡顿证明。
> **2026-08-29 审计补充**：本轮修复了单图收藏元数据刷新会丢失本地文件、磁盘缓存替换时 `currentSize` 失真、图片收藏页无法批量选择/跨页面刷新/分享远程图等问题。单元测试与模拟器构建通过；这不等于已证明真机长时间零泄漏或零卡顿；本轮继续补齐封面与正文统一复用源级 url/headers/method/data/onResponse 配置、合并同 URL 封面并发请求，并为合集删除增加确认与跨页面变更自动刷新；新增阅读器自动翻页、章节评论独立入口，并在单页画廊模式加入章节末评论页；双页模式和评论页前后章节哨兵仍未完整对齐。阅读器图片解码/增强已移出 SwiftUI body 计算路径，并为页图字节缓存增加邻近窗口 + 约 96 MiB 总预算；双页模式现已加入独立章节末评论页，但评论页前后章节哨兵仍未完整对齐。

## M1 核心引擎与数据层 ✅
| 功能 | 状态 | 备注 |
|---|---|---|
| SQLite 网关与连接管理（WAL/锁/重入/自愈） | ✅ | DatabaseGateway 单例 + Managed 连接 |
| 5 个核心库（history/local_favorite/read_later/cookie/local） | ✅ | local.db 已落地 |
| ComicType int-key 注册表兼容 | ✅ | SourcePlatformResolver |
| JavaScriptCore 运行时（事件循环/定时器/Promise/微任务） | ✅ | 尖峰 6/6 通过，无需 QuickJS 兜底 |
| init.js API 面（Network/Convert/Html/Storage/Cookie/UI） | ✅ | JS 源文件直接复用 |
| Convert（AES 各模式/MD5/SHA/HMAC/RSA/GBK） | ✅ | 字节级验证 |
| Html DOM（SwiftSoup + 句柄池 RPC） | ✅ | 8 文档 LRU |
| Cookie 持久化（cookie.db 兼容 + Set-Cookie 解析） | ✅ | WebView 共享与 Cloudflare 解盾打通 |
| 网络客户端（代理/UA/坏证书/Cookie 注入/CF重试） | ✅ | SNI/DNS 覆盖为已知限制 |
| CacheManager（LRU 磁盘缓存） | ✅ | |
| ComicSourceParser（JS class → Swift 回调） | ✅ | 含 isAppVersionAfter 修补 |
| ComicSourceManager（安装/删除/排序/目录加载） | ✅ | 源库 catalog / 更新检查由 `SourceCatalogManager` 在 M2 提供 |
| 源设置表单 / 三种登录方式数据面 | ✅ | UI 在 M2 |
| Komiic 源端到端验收（解析→探索→搜索→详情→章节→票据） | ✅ | mock HTTP 全链路 6 测试 |

## M2 浏览与详情 UI 🚧（核心浏览与首页/源市场路径已落地，仍需端到端覆盖与细节验收）
| 功能 | 状态 | 备注 |
|---|---|---|
| 探索页（multiPage/multiPart，多源切换） | ✅ 按 explore_pages 可见列表过滤排序 | |
| 漫画列表（分页/游标/无限滚动 + 自适应网格） | ✅ | |
| 搜索页（历史持久化同库 + 单源结果） | ✅ | |
| 多源聚合搜索（Aggregated Search） | ✅ | 并发查询/分源横滑呈现 |
| 跨源换源搜索（Related Sources） | ✅ | 详情页一键同名检索/换源阅读 |
| 漫画详情页（封面/标签/分组章节/推荐/评论入口/下载弹窗） | ✅ | |
| 评论页（分页/楼中楼/发送） | ✅ | |
| 漫画源管理页（URL 安装/删除/设置表单/登录登出） | ✅ 安装自动加入可见页列表 | |
| Cloudflare 检测 + WKWebView 解盾 | ✅ | 403/503 拦截并自动写回 CookieStore |
| 首页可编辑区块（kHomeSections 九类） | ✅ | `HomeLayoutStore` + `HomeLayoutEditorSheet` 支持显示/隐藏/排序并持久化；仍需 iPad 端真机验收 |
| 分类页分类部件 + 排行榜 | ✅ 真实数据（38 分类 + 排行选项） | |
| 源库 catalog + 更新检查 | ✅ | `SourceCatalogManager` + 市场页支持刷新、版本比较、单源安装与一键更新；网络失败反馈仍可继续细化 |

## M3 阅读器 🚧（基础阅读闭环已完成，若干原版能力仍缺）
| 功能 | 状态 | 备注 |
|---|---|---|
| 6 种翻页模式（画廊 3 + 连续 3，运行时切换） | ✅ | |
| 跨章节平滑连读（Continuous Seamless Append） | ✅ | 连续模式自动追加下一话 |
| 双击缩放/捏合缩放（UIScrollView 内核，2x-10x） | ✅ | |
| 单击呼出工具栏 | ✅ | |
| ±N 双向预载（preloadImageCount） | ✅ | |
| 夜间模式（暖色/黑/红遮罩 + 强度） | ✅ | |
| 页码浮层 + 滑动条 + 模式菜单 + 重载 | ✅ | |
| 章节抽屉 + 已读标记 | ✅ | |
| 历史记录写入（ep/page/readEpisode） | ✅ | |
| 阅读时长统计（30s 结算 reading_statistics） | ✅ | |
| ImageDownloader（headers/onResponse/modifyImage） | ✅ headers+onResponse | |
| 本地离线直读（本地漫画/已下载章节优先读磁盘） | ✅ | |
| 阅读器当前页单图收藏（本地保存/收藏页/多选管理） | ✅ | 阅读器工具栏可切换当前页收藏并保存图片数据；连续模式与画廊模式共用状态 |
| 阅读器页加载任务生命周期 | ✅ | `ReaderPageView.Coordinator` 取消重复/过期任务，避免快速翻页时重复请求和旧图回写 |
| 阅读器加载竞态（重试/切章） | ✅ | `ReaderModel` 使用加载代次校验并清理旧预载，避免旧请求覆盖新章节状态 |
| 双页阅读与跨页切分 | 🚧 | 已实现封面单页、双页分组、RTL 顺序、前后章节哨兵和章节评论独立页；真实跨页切分、iPad/横屏和真机边界仍需验收 |
| 长按缩放/音量键（iOS 不适用）/自动翻页 | 🚧 | 已加入阅读器自动翻页按钮与 `autoPageTurningInterval`；长按/音量键不适用，仍需真机验证章节边界与后台取消 |
| 增强滤镜（Metal 移植 GLSL） | 🚧 | 已从 SwiftUI body 计算路径移出 UIImage 解码/增强，使用不可变参数快照 + detached Core Image；当前仍是 CoreImage 近似实现，不是原 Flutter GLSL 的像素级移植，需真机画质与性能对比 |
| 阅读器内章节评论 | 🚧 | 已加入 API、分页/回复/发送、单页和双页章节末评论页及哨兵；双页/前后章节边界仍需真机验收 |

## M4 收藏·历史·本地库 🚧（下载/本地库与图片收藏/合集基础闭环已落地，任务类型汇总仍缺）
| 功能 | 状态 | 备注 |
|---|---|---|
| 收藏操作面板（本地文件夹/新建/网络收藏夹） | ✅ | |
| 收藏页（本地多文件夹 + 网络收藏 + 滑动删除） | ✅ | |
| 追更监控（Follow Updates / 徽标 / 追更列表） | ✅ | |
| 稍后读页 + 详情页加入 | ✅ | |
| 历史页（进度显示/隐藏/清空） | ✅ | |
| 本地漫画存储（local.db / LocalManager / LocalComic） | ✅ | |
| 下载管理器（DownloadManager + Images/Archive 任务） | ✅ | |
| 本地漫画页（LocalComicsView，4 状态分栏/搜索/排序） | ✅ | |
| 下载管理页（DownloadingView，实时网速/队列控制） | ✅ | |
| 本地漫画导入导出（CBZ/ZIP/文件夹/ComicInfo.xml） | 🚧 | 已支持 CBZ/ZIP/文件夹、`.venera_comics`、PDF/EPUB 与多选导出任务；批量 `.venera_comics` 仍为多个文件，不是 Flutter 的合并单文件模式 |
| 图片收藏 / 合集 / 任务中心 | 🚧 | 图片收藏、合集和任务中心基础闭环已具备；任务中心现展示下载、迁移、追更、源更新、WebDAV 同步、WebDAV 漫画库迁移和本地批量导出；翻译任务、后台恢复和合并 `.venera_comics` 仍有缺口 |

## M5 同步与系统集成 🚧（同步主链路与深链代码已落地，端到端/指南/iPad 专项仍缺）
| 功能 | 状态 | 备注 |
|---|---|---|
| WebDAV 客户端（PROPFIND/GET/PUT/MKCOL/Basic Auth） | ✅ | 含路径编码和基础 URL 保留 |
| 同步引擎（.venera 打包/版本判定/上传下载/保留清理/local.db 同步） | ✅ | |
| 导出→导入往返对拍（逐库逐键） | ✅ | |
| 首启迁移向导（WebDAV 导入） | ✅ | |
| 应用锁（生物识别 + PIN） | ✅ 含设置录入表单 | |
| 同步设置页（配置/手动上传下载） | ✅ 并入数据与同步分区 | |
| 三档自动同步（realtime/dataSaver/manual） | ✅ realtime 防抖上传 + dataSaver 场景结算 | |
| 本地 .venera 文件导入（文件选择器） | ✅ 数据与同步分区 | |
| 远程备份列表 + 指定备份下载 + 同步日志 | ✅ | |
| WebDAV 漫画库迁移 | 🚧 | 已接入本地已下载漫画→远端目录/章节/图片的可取消任务；跳过已存在目录，真实服务器验证和断点续传仍缺 |
| 跳过同步分类（disableSyncFields） | ✅ | |
| 15 个设置分区全量 + 设置搜索 | ✅ 8 分区（iOS 端原版即 8 分区）+ 搜索 | |
| 阅读统计页（Swift Charts 图表） | ✅ | |
| venera:// 深链 | ✅ | 已接入启动后延迟路由；漫画链接加载详情后打开阅读器 |
| 免责声明 | ✅ 关于分区可重看（首启同意在向导） | |
| 指南 / iPad 专项 | 🚧 | 已加入离线 Guide 页面并直接复用 `doc/guide.zh.md` / `doc/guide.en.md`；iPad 专项仍需真机验收 |

## M6 打磨与发布
| 功能 | 状态 | 备注 |
|---|---|---|
| 随机抽漫画 | ✅ | 收藏候选池内本轮不重复，候选耗尽后自动开启新轮次 |
| 扫码导入同步配置 | 🚧 | 已接入原生 AVFoundation QR 扫描、PIN、Flutter 兼容 AES-GCM/PBKDF2 解码和 WebDAV 表单回填；模拟器无真实摄像头，需实体机验收 |
| 缓存管理 / 性能画像 / 无障碍 | ⬜ | 尚未完成系统化功能与 Instruments/Accessibility 审计 |
| AltStore 发布管线 + 图标 | ⬜ | |
