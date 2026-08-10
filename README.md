# 美术馆 / ArtGallery — KOReader 看图插件

> 中文说明在上，English below. / Chinese description first, English below.

---

## 简介 / Introduction

**中文**：美术馆（ArtGallery）是 [KOReader](https://github.com/koreader/koreader) 的一款看图插件，原名 **Mirador**，由 **Glimpse** 合并 **Illustrations** 的全屏看图能力而来。它让你在看书时直接浏览书中的地图、族谱、参考图等图片，**不丢失阅读位置**；支持抽屉式预览与一键全屏查看，可缩放、平移、旋转、收藏。

**English**: ArtGallery (美术馆) is a KOReader plugin for viewing images embedded in books — such as maps, family trees, and reference illustrations — without losing your reading position. It is a fork of **Mirador**, built by merging the fullscreen image-viewing capability of **Illustrations** into **Glimpse**. It offers a drawer preview and one-tap fullscreen viewing, with zoom, pan, rotate, and favorite support.

## 功能特性 / Features

- **抽屉预览 + 全屏沉浸式看图** — 在书中直接看图，进出不丢位置。
  Drawer preview + immersive fullscreen viewing, preserving the book reading position.
- **全屏三态填充** — 铺满(cover) / 适配(contain) / 拉伸(stretch)，可在「右 ⋯」菜单切换，长按某态可设为默认全屏看图模式。
  Three fullscreen fit modes — cover / contain / stretch — switchable from the `⋯` menu; long-press a mode to make it the default fullscreen mode.
- **看图同步书籍进度** — 看图时同步更新书籍本身的阅读进度（分页文档 CBZ/DjVu/PDF 与滚动文档 EPUB **各用独立开关**），避免"看完了漫画、书本进度还停在第一页"。
  Reading-progress sync — viewing images also advances the book's own progress, with **separate toggles** for paged documents (CBZ/DjVu/PDF) and scrolling documents (EPUB).
- **沉浸式模式** — 进入全屏即隐藏功能按钮 / 页码圆点 / 左上标题；点屏幕底部恢复，点图面延迟后再次隐藏（兼容双击缩放）。
  Immersive mode — entering fullscreen hides buttons / page dots / caption; tap the bottom edge to restore, tap the image to auto-hide again (double-tap zoom still works).
- **缩放手势** — 双击放大、双指张开/捏合、按住图片移动；**拉伸态同样可用**。
  Zoom gestures — double-tap to zoom, pinch/spread, and hold-to-pan; **also available in stretch mode**.
- **智能适配屏幕** — 自动选向（依图片宽高比旋转以最佳填满屏幕），全屏铺满/适配可切换。
  Smart screen fitting — auto-orientation and switchable cover/contain fullscreen.
- **收藏 / 按书清缓存 / 全书搜索记忆** — 实用小工具一应俱全。
  Favorites, per-book cache clearing, and persistent in-book search memory.

## 安装 / Installation

**中文**：
1. 将本仓库整个 `artgallery.koplugin` 目录下载到你的设备；
2. 复制到 KOReader 的插件目录 `koreader/plugins/`（即设备上的 `KOReader/plugins/artgallery.koplugin/`）；
3. 重启 KOReader，即可在书籍内通过菜单「美术馆」打开看图。

**English**:
1. Download the whole `artgallery.koplugin` folder from this repository;
2. Copy it into KOReader's plugin directory `koreader/plugins/` (i.e. `KOReader/plugins/artgallery.koplugin/` on your device);
3. Restart KOReader. Open the viewer from the in-book menu item **美术馆 / ArtGallery**.

## 使用 / Usage

- **打开**：在书籍内点击菜单 → 「美术馆」，浏览本书所有图片缩略图，点选进入单图。
  Open: in-book menu → **美术馆 / ArtGallery**; browse thumbnails, tap to enter a single image.
- **全屏**：单图界面点右下角全屏按钮进入全屏沉浸式看图。
  Fullscreen: tap the fullscreen button (bottom-right) for immersive viewing.
- **填充模式**：全屏下打开「右 ⋯」菜单，选择「铺满 / 适配 / 拉伸」，长按可设为默认。
  Fit mode: in fullscreen, open the `⋯` menu and pick **cover / contain / stretch**; long-press to set as default.
- **缩放 / 平移**：双击放大，双指张开/捏合，按住拖动。
  Zoom / pan: double-tap, pinch/spread, hold-and-drag.

## 兼容 / Compatibility

- 设备：Kindle PaperWhite 3（KPW3）等墨水屏；通用 LuaJIT 环境。
  Devices: Kindle PaperWhite 3 (KPW3) and other E-ink readers; any LuaJIT KOReader build.
- KOReader：基于 `koreader-kindle-v2026.07.1` 纯净源码开发校验。
  Built and verified against the pristine `koreader-kindle-v2026.07.1` source.

## 目录结构 / Repository layout

```
artgallery.koplugin/
├── main.lua                 # 插件主体（查看器逻辑）
├── artgallery_scanner.lua   # 图片扫描与抽取层
├── _meta.lua               # 插件元数据
├── assets/                 # 图标（SVG）
└── audit/                  # 详细中文更新日志与方案文档（CHANGELOG.html 等）
```

## 更新日志 / Changelog

本仓库根目录 `CHANGELOG.md` 为中英双语摘要；完整逐次改动时间线见 `audit/CHANGELOG.html`（中文）。
The root `CHANGELOG.md` is a bilingual summary; the full chronological log lives in `audit/CHANGELOG.html` (Chinese).

## 致谢 / Credits

- 原作 / Original: **Erik Fanki**（Glimpse、Illustrations 等 KOReader 社区插件）
- 本分支维护 / This fork: **ksaMask**
- Based on Glimpse, merging the fullscreen image-viewing capability of Illustrations; originally named Mirador.

## 许可证 / License

本插件继承自上游社区插件的许可；具体以插件源文件头注释为准。
Inherited from the upstream community plugins; see the license headers in the source files.
