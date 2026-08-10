# 美术馆 / ArtGallery — KOReader 看图插件

> 中文说明在上，English below. / Chinese description first, English below.

---

## 简介 / Introduction

**中文**：美术馆（ArtGallery）是 [KOReader](https://github.com/koreader/koreader) 的一款看图插件，原名 **Mirador**，由 **Glimpse** 合并 **Illustrations** 的全屏看图能力而来。它让你在阅读电子书时直接浏览书中的地图、族谱、参考图、漫画分镜等图片，**不丢失阅读位置**；支持抽屉式缩略图预览与一键全屏沉浸式查看，可缩放、平移、旋转、收藏。

**English**: ArtGallery (美术馆) is a KOReader plugin for viewing images embedded in books — such as maps, family trees, reference illustrations, and comic panels — without losing your reading position. Originally named **Mirador**, it merges the fullscreen image-viewing capability of **Illustrations** into **Glimpse**. It offers a drawer thumbnail preview and one-tap immersive fullscreen viewing, with zoom, pan, rotate, and favorite support.

---

## 支持格式 / Supported formats

**中文**：本插件适用于 KOReader 能够打开、且内含图片的主流电子书格式，尤其适合：
- **EPUB** — 滚动文档（小说、带地图 / 族谱的参考书），也是本插件的原生强项；
- **CBZ / DjVu / PDF** — 分页文档（漫画、扫描版插图集、带插图的资料书）。

只要书籍中包含可被提取的图片（地图、族谱、漫画分镜、插图等），即可用本插件浏览；纯文本无图书籍不适用。

**English**: This plugin works with any mainstream e-book format KOReader can open that contains extractable images — especially:
- **EPUB** — scrolling documents (novels, reference books with maps / family trees); the plugin's native strength;
- **CBZ / DjVu / PDF** — paged documents (comics, scanned illustration collections, illustrated materials).

It works whenever the book contains extractable images (maps, family trees, comic panels, illustrations); plain-text books without images are not applicable.

---

## 功能特色 / Features

### 1. 内置菜单入口，阅读中一键看图 / In-book menu entry

在任意书籍的阅读界面打开顶部菜单，即可看到「美术馆 / ArtGallery」入口，点击后直接进入本书图片浏览器，无需离开当前书籍。

Open the top menu while reading any book to find the **美术馆 / ArtGallery** entry. Tap it to open the image browser for the current book without leaving your reading position.

![内置看图菜单](assets/screenshots/内置看图菜单.png)

### 2. 插件级菜单与关于对话框 / Plugin menu & About dialog

插件在 KOReader 的插件列表中注册完整菜单，包含设置项与「关于美术馆 / About ArtGallery」对话框，版本、作者、更新来源一目了然。

The plugin registers a full menu in KOReader's plugin list, including settings and the **About ArtGallery / 关于美术馆** dialog, showing version, author, and update source at a glance.

![插件菜单界面](assets/screenshots/插件菜单界面.png)

### 3. 抽屉式图片预览 / Drawer-style image preview

从书籍菜单唤出插件后，呈现抽屉式图片列表，列出本书内所有可用图片。轻点任一缩略图即可进入单图查看；退出后自动回到书籍原阅读位置。

After invoking the plugin from the book menu, a drawer-style image list appears, showing all available images in the book. Tap any thumbnail to enter single-image view; exiting returns you to the original reading position.

![插件唤出界面](assets/screenshots/插件唤出界面.png)

### 4. 全屏沉浸式三态填充 / Immersive fullscreen with three fit modes

进入全屏后自动隐藏功能按钮、页码圆点与标题栏，最大化利用屏幕空间。点击屏幕底部可临时恢复控件，再次点击图片后延迟自动隐藏，双击缩放不受影响。

全屏提供三种填充模式，可在「右 ⋯」菜单中即时切换，**长按某个模式可将其设为默认全屏看图模式**：

- **铺满 (Cover)**：按比例放大直至填满整个屏幕，边缘超出部分被裁切，适合漫画、海报等需要填满画面的场景。
- **适配 (Contain)**：按比例完整显示整张图片，保留全部内容，可能留出黑边，适合地图、图表等不能丢信息的场景。
- **拉伸 (Stretch)**：非等比拉伸填满屏幕，充分利用每一寸显示面积，同时仍支持缩放与平移手势。

In fullscreen, buttons, page dots, and captions are auto-hidden to maximize screen usage. Tap the bottom edge to temporarily restore controls; tap the image to auto-hide again. Double-tap zoom remains available.

Three fit modes are available in the `⋯` menu; **long-press a mode to set it as the default fullscreen mode**:

- **Cover**: scales proportionally until the screen is fully filled; edges are cropped. Great for comics and posters.
- **Contain**: shows the entire image proportionally, possibly with letterboxing. Ideal for maps and diagrams.
- **Stretch**: non-uniformly fills the screen, making full use of the display area while still supporting zoom and pan gestures.

#### 铺满模式（裁切）/ Cover mode (cropped)

![全屏铺满模式（裁切）](assets/screenshots/全屏铺满模式（裁切）.png)

#### 适配模式 / Contain mode

![全屏适配模式](assets/screenshots/全屏适配模式.png)

#### 拉伸模式 / Stretch mode

![全屏拉伸模式](assets/screenshots/全屏拉伸模式.png)

### 5. 完整缩放手势 / Full zoom & pan gestures

- 双击图片：放大 / 还原。
- 双指张开：放大。
- 双指捏合：缩小。
- 按住并拖动：平移查看大图细节。
- 上述手势在 **Cover / Contain / Stretch 三种模式下均可用**，拉伸模式也不例外。

- Double-tap: zoom in / restore.
- Two-finger spread: zoom in.
- Two-finger pinch: zoom out.
- Hold and drag: pan to inspect details.
- All gestures work in **Cover, Contain, and Stretch modes**, including Stretch.

### 6. 看图同步书籍进度 / Reading-progress sync

看图时自动同步更新书籍本身的阅读进度，避免"看完了漫画、书本进度还停在第一页"。分页文档（CBZ / DjVu / PDF）与滚动文档（EPUB）**各用独立开关**，可按文档类型分别开启或关闭。

Viewing images also advances the book's own reading progress, so your book won't stay on page one after you finish a comic. **Separate toggles** are provided for paged documents (CBZ / DjVu / PDF) and scrolling documents (EPUB).

### 7. 智能适配与自动选向 / Smart fitting & auto-orientation

全屏查看时自动根据图片宽高比选择最佳屏幕方向，让画面以最大有效面积呈现；同时支持手动切换铺满 / 适配 / 拉伸。

Fullscreen view automatically picks the optimal screen orientation based on image aspect ratio, maximizing usable display area while allowing manual switching among cover / contain / stretch.

### 8. 收藏、缓存清理与搜索记忆 / Favorites, cache, and search memory

- **收藏图片**：快速标记常用图片，方便反复查看。
- **按书清缓存**：释放单本书籍生成的图片缓存，管理存储空间。
- **全书搜索记忆**：记住在书中的图片搜索状态，退出后再次进入可继续浏览。

- **Favorite images**: mark frequently used images for quick access.
- **Per-book cache clearing**: free image caches per book to manage storage.
- **Persistent in-book search memory**: remember your image search state across sessions.

---

## 相比上游的改进 / Improvements over the upstreams

**中文**：美术馆（ArtGallery）并非简单堆叠两个插件，而是在合并 **Glimpse** 与 **Illustrations** 能力的基础上做了针对性增强。两个上游插件均**仅支持 EPUB**；本插件在保留其优良特性的同时，补齐了以下短板并新增能力：

| 维度 | Glimpse / Illustrations（上游） | 美术馆 / ArtGallery |
| --- | --- | --- |
| 支持格式 | 仅 EPUB | **EPUB + CBZ / DjVu / PDF**（分页文档同样可看图、可翻页） |
| 全屏填充 | Illustrations 仅单一全屏模式 | 新增 **铺满 / 适配 / 拉伸** 三态，可长按设为默认；全屏自动隐藏按钮/页码/标题，单击底部显隐 |
| 拉伸模式手势 | 无独立"拉伸"模式 | 拉伸态下仍完整支持双击放大、双指缩放、按住平移 |
| 阅读进度 | Glimpse"不丢失你的位置"、Illustrations 可"跳回书中页码" | 进一步**主动同步书籍自身进度**（分页/滚动分别开关），看漫画不再"书还停在第一页" |
| 界面语言 | 全英文 | 全中文菜单与「关于美术馆」对话框（含双语元数据） |
| 更新维护 | 各插件各自指向自己的仓库 | 内置更新器统一指向本仓库 `ksaMask123/artgallery.koplugin`，一处维护 |

同时，上游的优秀特性被完整保留并延续：图书内一键入口、抽屉/画廊缩略图、收藏、按书清缓存、防剧透（仅显示当前位置之前）、缩放/平移、手势与内置更新器——你不再需要同时安装两个插件。

**English**: ArtGallery is not a simple stacking of two plugins; it merges **Glimpse** and **Illustrations** and adds targeted enhancements. Both upstreams support **EPUB only**; this plugin keeps their strengths while closing gaps and adding capabilities:

| Aspect | Glimpse / Illustrations (upstream) | ArtGallery (美术馆) |
| --- | --- | --- |
| Formats | EPUB only | **EPUB + CBZ / DjVu / PDF** (paged docs are viewable & pageable) |
| Fullscreen fit | Illustrations: single fullscreen mode | New **cover / contain / stretch** three-mode fit; long-press to set default; auto-hide buttons/dots/title, tap bottom to toggle |
| Stretch gestures | No dedicated "stretch" mode | Stretch mode still fully supports double-tap zoom, pinch/spread, and hold-pan |
| Reading progress | Glimpse "doesn't lose your place"; Illustrations "jump back to page" | Further **actively syncs the book's own progress** (separate toggles for paged vs scrolling) — comics no longer leave the book stuck on page one |
| UI language | English only | Fully Chinese menus and About dialog (with bilingual metadata) |
| Updates | Each plugin points to its own repo | Built-in updater uniformly points to this repo `ksaMask123/artgallery.koplugin` |

Meanwhile, the upstream's good features are preserved: in-book entry, drawer/gallery thumbnails, favorites, per-book cache clearing, spoiler protection (show only up to current position), zoom/pan, gestures, and the built-in updater — so you no longer need both plugins installed.

---

## 安装 / Installation

### 方式一：Release 安装包（推荐）/ Option 1: Release package (recommended)

**中文**：
1. 前往 [Releases · v1.0.1](https://github.com/ksaMask123/artgallery.koplugin/releases/tag/v1.0.1)；
2. 下载 `artgallery.koplugin-v1.0.1.zip`；
3. 解压得到 `artgallery.koplugin` 文件夹，复制到 KOReader 的插件目录 `koreader/plugins/`（设备上路径为 `KOReader/plugins/artgallery.koplugin/`）；
4. 重启 KOReader，即可在书籍内通过菜单「美术馆 / ArtGallery」打开看图。

**English**:
1. Go to [Releases · v1.0.1](https://github.com/ksaMask123/artgallery.koplugin/releases/tag/v1.0.1);
2. Download `artgallery.koplugin-v1.0.1.zip`;
3. Extract the `artgallery.koplugin` folder and copy it into KOReader's plugin directory `koreader/plugins/` (i.e. `KOReader/plugins/artgallery.koplugin/` on your device);
4. Restart KOReader. Open the viewer from the in-book menu item **美术馆 / ArtGallery**.

### 方式二：手动复制源码 / Option 2: Copy source manually

**中文**：直接下载本仓库的 `artgallery.koplugin` 目录（保持文件夹名不变），复制到 `koreader/plugins/`，然后重启 KOReader。

**English**: Download the `artgallery.koplugin` folder from this repository (keep the folder name unchanged), copy it into `koreader/plugins/`, and restart KOReader.

---

## 使用 / Usage

- **打开**：在书籍内点击菜单 → 「美术馆 / ArtGallery」；浏览缩略图，点选进入单图。
  Open: in-book menu → **美术馆 / ArtGallery**; browse thumbnails, tap to enter a single image.
- **全屏**：单图界面点右下角全屏按钮进入全屏沉浸式看图。
  Fullscreen: tap the fullscreen button (bottom-right) for immersive viewing.
- **填充模式**：全屏下打开「右 ⋯」菜单，选择「铺满 / 适配 / 拉伸」，长按可设为默认。
  Fit mode: in fullscreen, open the `⋯` menu and pick **cover / contain / stretch**; long-press to set as default.
- **缩放 / 平移**：双击放大，双指张开 / 捏合，按住拖动。
  Zoom / pan: double-tap, pinch / spread, hold-and-drag.
- **更新插件**：在插件菜单中选择「检查更新 / Check for updates」，插件会自动从本仓库 Release 下载并安装最新版本。
  Update: choose **检查更新 / Check for updates** in the plugin menu to automatically download and install the latest release from this repository.

---

## 兼容 / Compatibility

- 设备：Kindle PaperWhite 3（KPW3）等墨水屏；通用 LuaJIT 环境。
  Devices: Kindle PaperWhite 3 (KPW3) and other E-ink readers; any LuaJIT KOReader build.
- KOReader：基于 `koreader-kindle-v2026.07.1` 纯净源码开发校验。
  Built and verified against the pristine `koreader-kindle-v2026.07.1` source.

---

## 目录结构 / Repository layout

```
artgallery.koplugin/
├── main.lua                 # 插件主体（查看器逻辑）
├── artgallery_scanner.lua   # 图片扫描与抽取层
├── _meta.lua               # 插件元数据
├── assets/                 # 图标与截图（SVG / screenshots）
│   └── screenshots/        # README 配图
├── audit/                  # 详细中文更新日志与方案文档（CHANGELOG.html 等）
├── README.md               # 本文件
├── CHANGELOG.md            # 中英双语更新摘要
└── LICENSE                 # GNU AGPL-3.0 全文
```

---

## 更新日志 / Changelog

本仓库根目录 `CHANGELOG.md` 为中英双语摘要；完整逐次改动时间线见 `audit/CHANGELOG.html`（中文）。
The root `CHANGELOG.md` is a bilingual summary; the full chronological log lives in `audit/CHANGELOG.html` (Chinese).

---

## 致谢 / Credits

本插件（美术馆 / ArtGallery，原名 **Mirador**）由 **Erik Fanki** 创作，是 **Glimpse** 与 **Illustrations** 两个 KOReader 社区插件能力的合并与延续。在此特别致谢两位原作者的开源贡献：

- **Glimpse** — 作者 [Fank1（Erik Fanki）](https://github.com/Fank1) · 项目：[github.com/Fank1/glimpse](https://github.com/Fank1/glimpse)
  > Glimpse is a plugin for KOReader that lets you peek at maps, family trees and other reference images from anywhere in a book without losing your reading position.
- **Illustrations** — 作者 [agaragou](https://github.com/agaragou) · 项目：[github.com/agaragou/illustrations.koplugin](https://github.com/agaragou/illustrations.koplugin)
  > A plugin for KOReader that allows you to browse, preview, and navigate through all illustrations contained in an EPUB book.

当前分支（ArtGallery）由 **ksaMask123** 维护并发布于 [ksaMask123/artgallery.koplugin](https://github.com/ksaMask123/artgallery.koplugin)。

**English**: This plugin (ArtGallery, originally named **Mirador**) was created by **Erik Fanki**, merging and building upon two community KOReader plugins, **Glimpse** and **Illustrations**. Special thanks to both original authors for their open-source work:

- **Glimpse** — by [Fank1 (Erik Fanki)](https://github.com/Fank1) · [github.com/Fank1/glimpse](https://github.com/Fank1/glimpse)
- **Illustrations** — by [agaragou](https://github.com/agaragou) · [github.com/agaragou/illustrations.koplugin](https://github.com/agaragou/illustrations.koplugin)

The current fork (ArtGallery) is maintained and published by **ksaMask123** at [ksaMask123/artgallery.koplugin](https://github.com/ksaMask123/artgallery.koplugin).

---

## 许可证 / License

本插件（美术馆 / ArtGallery）整体采用 **GNU Affero General Public License v3.0 or later（AGPL-3.0-or-later）** 发布。许可证全文见仓库根目录 [`LICENSE`](LICENSE)。

This plugin (ArtGallery / 美术馆) is released under the **GNU Affero General Public License v3.0 or later (AGPL-3.0-or-later)**. The full text is in [`LICENSE`](LICENSE) at the repository root.

### 授权来源 / Provenance

本插件由 **Glimpse** 与 **Illustrations** 两个 KOReader 社区插件合并而来，沿用其开源授权：

This plugin is a merge of two KOReader community plugins, **Glimpse** and **Illustrations**, and follows their open-source licensing:

- **Illustrations**（作者 [agaragou](https://github.com/agaragou)）以 **AGPL-3.0** 发布；本插件因包含其代码，依 AGPL-3.0 条款整体采用该许可证。
  **Illustrations** (by [agaragou](https://github.com/agaragou)) is released under **AGPL-3.0**; because this plugin includes its code, the whole work adopts this license per the AGPL-3.0 terms.
- **Glimpse**（作者 [Fank1 / Erik Fanki](https://github.com/Fank1)）作为本插件 fork 链（Glimpse → Mirador → ArtGallery）的上游，其仓库未单独分发许可证文件；本插件基于该社区 fork 链开发，并以 **AGPL-3.0-or-later** 统一发布，以保持上游强 copyleft 兼容并持续开源。
  **Glimpse** (by [Fank1 / Erik Fanki](https://github.com/Fank1)), as the upstream of this plugin's fork chain (Glimpse → Mirador → ArtGallery), does not ship a separate license file in its repository; built upon that community fork chain, this plugin is likewise published under **AGPL-3.0-or-later** to remain compatible with upstream copyleft and stay open source.
