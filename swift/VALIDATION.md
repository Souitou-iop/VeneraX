# Swift 版验证边界与审计记录

更新时间：2026-08-29（Asia/Shanghai）


## 2026-08-29 本轮追加修复与验证

- 阅读器双页画廊现在也把章节评论作为独立末尾页加入，避免双页模式下评论入口缺失；评论页不会伪装成双页 spread。已通过 Swift 编译验证，仍需在真机/模拟器中切换双页与评论设置做交互验收。
- 阅读器 `loadedImages` 与 `continuousLoadedImages` 现在除邻近窗口外再受约 96 MiB 的 Data 字节预算约束，优先保留当前页；新增 `testReaderDecodedImageCacheHasByteBudget` 回归测试。该预算约束的是原始图片字节，不等同于 UIKit/Core Image 解码后的全部峰值内存。
- `ImageDownloader` 现在读取并应用源 `onImageLoad` 返回的 `url`，并统一带上 `User-Agent`；`CoverLoader` 的源封面请求改为复用该完整管线，因此封面也能获得源级 url/method/data/headers/onResponse 处理。该改动已通过 VeneraKit 单测和 App Debug 构建。
- 下载列表的单任务滑动取消改为先弹出确认对话框，避免误触直接取消并删除部分下载；整队取消继续保留确认。该 UI 改动已通过 App Debug 构建。
- `FollowUpdatesManager` 的检查状态改为受 `NSLock` 保护，重复并发触发追更检查时只允许一个检查流程进入，避免 `@unchecked Sendable` 状态竞争。
- 追更页面不再用无法回收的非结构化任务启动检查；页面离开时取消持有的检查任务，管理器循环在每个条目和网络错误路径检查取消状态，减少离开页面后继续高强度请求和状态回写的风险。
- 连续阅读触底加载现在合并为单一、可取消的追加任务；`LazyVStack`/`LazyHStack` 因视图重建重复触发 `onAppear` 时，不会为同一下一章节创建并发请求，切章/重载时也会取消该任务。`FollowUpdatesView` 取消检查后通过 `defer` 恢复 UI 状态，避免页面离开或任务取消后永久显示转圈。
- `ImageFavoriteManager.addFavorite` 在仅刷新元数据时保留已有 `local_file`，并使用原子写入；新增回归测试覆盖离线文件不丢失。
- `CacheManager` 修正缓存覆盖、删除、过期清理和目录扫描的大小核算，避免长期运行后 `currentSize` 虚增并触发过早淘汰；新增覆盖写入回归断言。
- `ImageFavoritesView` 补齐原版常用交互：多选、全选、批量删除确认、外部变化自动刷新、远程/本地图片分享。
- `TasksView` 增加下载任务入口与实时数量联动，避免运行中的下载任务在任务中心显示为空；仍未实现 Flutter 全部任务管理器的统一历史/取消操作。
- 阅读器工具栏新增当前页单图收藏，统一调用 `ReaderModel` 与 `ImageFavoriteManager`，并增加测试中的阅读器收藏回归测试。
- 阅读器 `ReaderPageView` 改为由 `Coordinator` 持有并取消页图加载任务，避免 SwiftUI 重复调用 `updateUIView` 时产生重复请求和过期图片回写。
- `ReaderModel.loadPages` 增加加载代次校验、旧预载任务清理和过期错误抑制，快速重试/切章时不会让旧请求覆盖新章节状态。
- `swift test --package-path swift/VeneraKit -c release`：90/90 通过，新增阅读器解码图片字节预算、`.venera_comics` 跨平台往返和归档路径穿越防护回归测试。
- `xcodebuild ... iphonesimulator26.5 ... build`：BUILD SUCCEEDED。
- 对当前已运行模拟器进程执行 `leaks` 快照：物理 footprint 80.2 MB（peak 80.4 MB），报告 1 个 32-byte allocator zone 项；未发现 app-owned Swift 类型泄漏。该快照仅代表启动后约 3 分钟的静态时点，不能证明高强度/长时间无泄漏。

- 本地漫画 `.venera_comics` 已补齐 Flutter 兼容 manifest、单/多本归档、导入和归档路径安全校验；Local Comics 页面可直接导入并从单本漫画操作中导出。

## 已实际执行

- `swift test --package-path swift/VeneraKit -c release`：90/90 通过，约 0.74 秒；损坏数据库和缺失 `uuid` handler 的日志仍属于既有测试噪声。
- `xcodebuild -project swift/VeneraX.xcodeproj -target VeneraX -sdk iphonesimulator26.5 -configuration Debug -arch arm64 CODE_SIGNING_ALLOWED=NO build`：成功。
- 已安装并启动到模拟器 `B37FC62C-8F44-42B7-A003-7B2779255ED3`，并取得启动后截图 `/tmp/venera_after_polish.png`。
- 本轮双页评论页改动后的 Debug 构建已重新安装并启动到同一模拟器，取得启动截图 `/tmp/venera_two_page_comments_build.png`；启动后已主动终止应用。该截图验证构建产物可启动和发现页可见，不等同于已完成阅读器双页评论页的 UI 自动化操作验收。
- 在最新构建上重新执行一次模拟器启动后 memgraph/leaks 快照：physical footprint 65.2 MB，peak 69.0 MB，报告 1 个 32-byte `DefaultMallocZone`/unknown leak；没有发现 app-owned 类型，但进程为 Simulator target/corpse，且只做了启动后单次快照，不能替代真机 Instruments 长时压力测试。
- 代码级检查发现并修复：
  - 源能力探测对缺失嵌套字段产生大量 JS `TypeError` 日志；`ComicSource.checkExists/readJSON` 改为安全逐段遍历。
  - 漫画封面加载使用阻塞式 `Data(contentsOf:)`；改为 `URLSession` 异步加载。
  - `CoverLoader` 原先按 URL 无限保留 `UIImage`；改为有数量/总成本上限的 `NSCache`。
  - 阅读器页图像内存缓存原先随长时间翻页持续增长；改为围绕当前页/可视连续条目的有限窗口裁剪，并在切章时取消预载任务、清空缓存。
- 阅读器连续页与画廊页的 `UIImage(data:)` 和 `ImageEnhancer` 不再在 SwiftUI `body` 计算路径执行；设置先快照为不可变参数，解码/滤镜在可取消的 detached task 中执行，页切换或视图销毁时取消渲染任务。
- 任务中心取消迁移增加二次确认；迁移进度更新仅允许作用于 `running` 任务，避免取消与最后一项进度回调竞态导致状态错误回到 `completed`。
- 离线指南页面已接入 About，构建产物中实际包含 `guide.zh.md` 和 `guide.en.md`，内容直接来自仓库文档。
  - `venera://` 漫画链接此前只解析不导航；现在会等待启动完成，加载详情并打开阅读器。
  - JS 输入对话框此前确认时始终返回 `nil`；现在使用原生输入 Sheet 返回用户输入。

## 尚不能声称的内容

- 88 个单元测试不是 UI、真机、网络源、WebDAV、下载大文件或 Instruments 泄漏测试；它们不能证明长时间使用零泄漏或绝不卡顿。
- 当前模拟器验证只证明“可编译、可安装、可启动、首屏可见”；没有完成连续数小时翻页、快速切源、下载/取消/恢复、WebDAV 冲突、内存图与 FPS 对比。
- 当前 PARITY 中仍明确列出未完成或部分完成项：增强滤镜的像素级移植、双页/阅读器评论的完整对等、任务中心的全部任务类型、`venera://` 完整端到端验收、指南/iPad 专项、扫码配置导入、性能画像、无障碍与发布管线。双页阅读已有基础 UI 开关但跨页切分/平板专项仍未完成；首页编辑、源 catalog 更新、图片收藏与合集基础闭环已不再列为“未实现”。
- 封面请求现已复用 `ImageDownloader` 的源级 `onImageLoad` 管线；仍需用需要鉴权和自定义响应变换的真实源做端到端验证，不能把单个公开 URL 加载成功当作所有源均可用。

## 下一轮验收建议

1. 在真机执行 30 分钟浏览 + 30 分钟连续阅读，使用 Instruments Allocations/Leaks 记录基线、峰值与回收后的稳定值。
2. 以 Komiic、CopyManga、MangaDex 各跑一次：安装源 → 探索 → 搜索 → 详情 → 章节 → 阅读 → 下载 → 离线阅读。
3. 反复执行快速切换章节、前后翻页、进入/退出阅读器、取消/恢复下载，检查任务数、网络请求、内存和 UI 响应是否回落。
4. 将上述结果补回本文件，并逐项更新 `PARITY.md`；在此之前只能称为“核心链路已实现，仍在验收”，不能称为“全量对等/无泄漏”。

## 本轮追加修复

- 外部链接不再在 `WindowGroup` 启动早期直接执行；先保存到 `AppState.pendingExternalURL`，待启动、迁移和应用锁门禁完成后再处理，避免深链丢失或在服务尚未初始化时失败。
- `venera://comic?...` 会解析源和漫画 ID，加载漫画详情后进入全屏阅读器；无源或加载失败时显示可见错误消息。
- JS 输入对话框改为可编辑原生 Sheet，确认会返回输入内容，取消才返回 `nil`。

- `simctl openurl` 已确认系统能够识别 `venera://` Scheme；模拟器会显示系统“在 VeneraX 中打开？”确认页。由于本轮未通过 UI 自动点击确认按钮，因此漫画深链的后续详情加载/阅读器跳转仍应在下一轮 UI 自动化中验证，不能把 Scheme 注册等同于完整端到端验收。
- JS `showSelectDialog` 此前立即回传初始值；现在改为可取消、可确认的原生选项 Sheet，真正返回用户选择。
- `ImageDownloader` 已改为 actor，并按完整缓存键合并 in-flight 请求；阅读器可视页和预载任务同时请求同一图片时只保留一个共享网络任务，完成后立即移除共享任务引用。

## 本轮继续打磨（任务中心与取消生命周期）

- `FollowUpdatesManager` 现在提供可持久化的 `FollowUpdateTask` 摘要，记录手动检查、创建/完成时间、总量、已检查、发现更新、失败数和 `running/completed/cancelled/failed` 状态；历史最多保留 100 条，避免任务摘要自身无限增长。
- 追更检查现已进入 `TasksView` 的运行中/历史列表，并可从任务中心发起带确认的取消；页面离开时取消外层等待任务也会通过 cancellation handler 取消实际检查 Job，而不是仅停止 UI 等待。
- 进程重启时不会把无法恢复的旧 `running` 任务伪装成仍在运行，而是归档为 `cancelled`，避免任务中心出现永久转圈的假状态。
- 源迁移任务完成时若存在失败项现在显示 `failed`，不再把“部分失败”误报为 `completed`。
- 新增 `FollowUpdateTask` Codable/进度边界回归测试；VeneraKit Release 测试由 81 个增加到 83 个，全部通过。
- 新增源更新任务摘要的 Codable、逐源失败信息和进度边界回归测试。
- 源迁移任务历史现在限制为最近 100 条，并拒绝同一文件夹/源/目标组合的重复运行；任务含失败项时状态为 `failed`，避免任务列表无限增长或把部分失败误报为完成。

## 本轮继续打磨（源目录更新任务）

- 新增 `SourceUpdateManager`，批量源更新现在具备任务摘要、每源状态、进度、失败记录、取消和有限历史；进程重启后不会伪装恢复不可恢复的 `running` 任务。
- `TasksView` 现已展示下载、源迁移、追更、源目录更新四类任务；源管理页的“Update All”改为创建可追踪任务，而不是页面内启动一个无法统一管理的临时 Task。
- 源迁移任务同样限制最近 100 条历史、拒绝重复组合，并将部分失败标为 `failed`。
- `SourceCatalogManager` 的目录、更新列表和 `isChecking` 状态改为锁保护，并通过同步辅助方法在 async 代码中安全写入，降低源市场刷新与批量更新并发时的数据竞争风险。

## 本轮继续打磨（任务历史与源目录并发）

- 任务中心新增“清空任务历史”二次确认；只删除已完成、失败和已取消记录，运行中任务不会被误删。
- `FollowUpdatesManager`、`SourceUpdateManager`、`SourceMigrationManager` 均提供有限历史清理入口，减少长期运行后任务列表持续膨胀。
- `SourceCatalogManager` 的目录状态锁改为同步辅助方法写入，避免 Swift 6 在 async 上下文直接使用 `NSLock`，并修正了状态保存路径；之后重新通过 90/90 单测和 App Debug 构建。
## 本轮继续打磨（本地备份导入生命周期）

- 本地 `.venera` 文件导入现在通过 `DataSyncManager.startImport(fileURL:)` 进入任务中心，具备阶段进度、失败/取消状态、历史清理和单任务并发保护；不再由设置页创建无法追踪的临时 `Task`。
- 修复安全作用域时序：原实现先调用 `startAccessingSecurityScopedResource()`，随后立即退出作用域，再由异步任务读取文件；现在由实际后台导入任务在读取期间打开并关闭安全作用域。
- 备份文件读取使用 utility 优先级的 detached task，导入和源脚本重载完成后才报告任务成功；旧任务历史新增字段采用兼容解码，不会因升级丢失既有记录。
- Release 单元测试当前为 **90/90 通过**。

## 本轮继续打磨（WebDAV 同步任务与网络边界）

- 新增 `DataSyncManager`，将 WebDAV 上传、普通下载、指定备份下载统一为可持久化摘要任务；任务中心现在显示运行/历史、阶段、有限进度、失败原因、取消和历史清理。运行中任务在进程重启后会归档为 `cancelled`，不会显示永久运行。
- 设置页和数据同步页改为提交任务，而不是在页面生命周期中持有不可追踪的临时同步 `Task`；重复点击会拒绝并发同步，防止多个操作同时覆盖本地数据库。
- `WebDAVClient` 现在拒绝非 HTTP(S) URL，使用独立 ephemeral `URLSession`，设置请求/资源超时，并在请求前后检查取消；PROPFIND 显式发送 `Depth: 1` 和 XML `Content-Type`。新增 URL/任务模型回归测试。
- Release 单元测试当前为 **90/90 通过**；测试仍包含主动损坏数据库用例和未注册 `uuid` handler 的既有日志噪声。
- 这些改动改善了任务可追踪性和“网络永不返回”风险，但同步进度目前仍是阶段性估计，不是远端传输字节级进度；WebDAV 真服务器、网络断开恢复、后台挂起/恢复仍需真实环境验收。

