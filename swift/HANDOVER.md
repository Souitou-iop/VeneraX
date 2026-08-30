# VeneraX Swift 原生重构迁移接手交接文档

> **交接时间**：2026-08-29  
> **工作区目录**：`/Volumes/SanDisk/Projects/VeneraX`  
> **当前 Git 分支**：`Swift-native`  
> **目标平台**：iOS 18+ / iPadOS 18+（支持 iPhone TabView 与 iPad/Mac NavigationSplitView 响应式自适应）  
> **包管理器 / 构建体系**：SwiftPM 本地包 `swift/VeneraKit/` + Xcode 工程 `swift/VeneraX.xcodeproj`  
> **当前状态（2026-08-29 审计）**：核心浏览、阅读、下载、本地库与同步链路已具备；但 PARITY 中仍有明确未实现项，不能宣称与 Flutter 版全量对等。90/90 个 VeneraKit 单元测试通过；模拟器 Debug 构建通过。稳定性与真机长时间压力证据仍不足，详见 `swift/VALIDATION.md`。

---

## 一、项目背景与核心技术架构

本项目是对原 Flutter 开发的跨平台漫画源聚合阅读器 **VeneraX**（v2.2.11+241，无内置源，运行用户自备的 JS 源脚本）进行 **Swift 原生重写迁移**。

### 1. 关键架构决策（已锁定）
- **独立应用形态与响应式布局**：
  - iPhone 采用底部经典 TabBar（首页/收藏/探索/分类）。
  - iPad / Mac 宽屏端自适应展开为 `NavigationSplitView` 侧边栏模式（涵盖发现、漫画库与系统三大分区）。
- **存储与同步协议字节级对齐**：沿用原版全部 SQLite 表结构（`history.db`, `local_favorite.db`, `read_later.db`, `cookie.db`, `cache.db`, `local.db`）与 JSON 键名规范，实现新旧版本互通。
- **JavaScriptCore 引擎**：替代 Flutter 端的 QuickJS。使用串行 `DispatchQueue` + `evaluateScript("0;")` 冲刷微任务循环驱动 Promise；`assets/init.js` 以 `#"""` 原生内嵌（`InitJSSource.swift`），源脚本无需修改即可直接执行。
- **图像画质增强管线（`ImageEnhancer`）**：
  - 基于 Metal / CoreImage 实现自适应锐化（`CISharpenLuminance`）、清晰度（`CIUnsharpMask`）、对比度与色彩鲜艳度（`CIColorControls`）四重硬件加速滤镜。

---

## 二、模块实现与对标全景

### 1. 漫画源与生态交互 ✅
- **源管理拖拽排序（`ComicSourcesView`）**：支持原生 `EditButton` 与拖拽手势重排源优先级，持久化至 `comicSourceOrder`。
- **探索页多源平铺与快速切换（`ExploreView`）**：顶部横向胶囊切换栏（All Sources / 单源聚焦），支持下拉刷新。
- **单源多维高级搜索抽屉（`SearchView`）**：自动解析 `search.options` / `search.optionList`，提供抽屉式参数过滤。
- **标签翻译与点击反查（`TagTranslator` & `ComicDetailsView`）**：内置 1000+ 漫画标签中英对照词典，详情页标签支持点击一键反查同标签作品。
- **章节正倒序与高级批量下载（`ComicDetailsView`）**：支持章节升降序切换、全选未读、区间选择与反选下载。
- **网络收藏夹多文件夹与分页（`FavoritesView`）**：支持 `multiFolder` 远程文件夹切换与增量翻页。

### 2. 系统级功能与后台任务 ✅
- **跨源漫画一键迁移（`SourceMigrationManager`）**：源失效时一键检索目标源同名漫画并批量迁移本地收藏与阅读历史。
- **全局后台任务中心（`TasksView`）**：集中管理跨源迁移、追更检测、源批量更新和 WebDAV 数据同步等后台任务；本地整库 `.venera` 导入/导出已接入，翻译、WebDAV 漫画库迁移和本地漫画 `.venera_comics` 单/多本归档与导入已具备，但批量导出任务 UI、PDF/EPUB 和后台恢复仍未全部接入。
- **屏蔽词与标签过滤系统（`BlockListFilter`）**：标题/副标题关键字、标签（原文+译文双向）、评论词多层级屏蔽。

---

## 三、常用构建与测试命令指南

```bash
cd /Volumes/SanDisk/Projects/VeneraX/swift

# 1. 运行所有单元测试（极速纯本地 90/90 项）
swift test --package-path VeneraKit

# 2. 编译 iOS 模拟器目标
xcodebuild -project VeneraX.xcodeproj -target VeneraX -sdk iphonesimulator26.5 -configuration Debug -arch arm64 CODE_SIGNING_ALLOWED=NO build

# 3. 安装并启动到测试模拟器
xcrun simctl install B37FC62C-8F44-42B7-A003-7B2779255ED3 build/Debug-iphonesimulator/VeneraX.app
xcrun simctl launch B37FC62C-8F44-42B7-A003-7B2779255ED3 io.github.kyosee.venerax

# 4. 编译 Release 并打包未签名 IPA
xcodebuild -project VeneraX.xcodeproj -target VeneraX -sdk iphoneos26.5 -configuration Release CODE_SIGNING_ALLOWED=NO build
python3 -c '
import os, shutil, zipfile
swift_dir = "/Volumes/SanDisk/Projects/VeneraX/swift"
app_path = os.path.join(swift_dir, "build/Release-iphoneos/VeneraX.app")
ipa_dir = os.path.join(swift_dir, "ipa")
payload_dir = os.path.join(ipa_dir, "Payload")
ipa_out = os.path.join(ipa_dir, "VeneraX-unsigned.ipa")
os.makedirs(payload_dir, exist_ok=True)
dest_app = os.path.join(payload_dir, "VeneraX.app")
if os.path.exists(dest_app): shutil.rmtree(dest_app)
shutil.copytree(app_path, dest_app)
if os.path.exists(ipa_out): os.remove(ipa_out)
with zipfile.ZipFile(ipa_out, "w", zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk(payload_dir):
        for file in files:
            full_path = os.path.join(root, file)
            zf.write(full_path, os.path.relpath(full_path, ipa_dir))
print(f"Created {ipa_out}: {os.path.getsize(ipa_out)/(1024*1024):.2f} MB")
'
```
