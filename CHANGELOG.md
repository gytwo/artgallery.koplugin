# 更新日志 / Changelog

> 中英双语摘要（按开发阶段倒序）。完整逐次改动时间线见 `audit/CHANGELOG.html`（中文）。
> Bilingual summary by development phase (newest first). The full chronological log is in `audit/CHANGELOG.html` (Chinese).

---

## 阶段二十 / Phase 20 — 内置更新器指向本仓库 + 关于/作者更正（2026-08-10）
- **中文**：内置更新器（移植自 Footcream）机制完整，唯一缺陷是 `github_repo` 仍指向旧仓库名 `ksaMask/mirador`，已改为真实仓库 `ksaMask123/artgallery.koplugin`，更新器现指向本仓库且确实可用（已实时核验 release API 可达）。「关于 美术馆」对话框插件名更正为「美术馆 / ArtGallery」、作者更正为 ksaMask123、更新链接同步更正；`_meta.lua` 同步（fullname/author/version 升 1.0.1）。为可真实验证更新，发布 v1.0.1 release 并上传 zip，设备内「检查更新」即可安装。代码改动已推送本仓库。
- **English**: The built-in updater (ported from Footcream) was complete; its only defect was `github_repo` still pointing to the old `ksaMask/mirador`, now changed to the real repo `ksaMask123/artgallery.koplugin` (release API reachability verified live). The "About" dialog name is corrected to "美术馆 / ArtGallery", author to ksaMask123, and the update link synced; `_meta.lua` updated (fullname/author/version→1.0.1). To make the updater genuinely testable, a v1.0.1 release with the zip was published so "Check for updates" can install it. Code changes pushed to the repo.

## 阶段十九 / Phase 19 — README 致谢溯源（2026-08-10）
- **中文**：在 README 中补全上游作者与项目链接致谢——Glimpse（作者 Fank1 / Erik Fanki）、Illustrations（作者 agaragou），中英双语对照。
- **English**: Added bilingual credits to README for upstream authors and project links — Glimpse (Fank1 / Erik Fanki) and Illustrations (agaragou).

## 阶段十八 / Phase 18 — 创建 GitHub 仓库并发布 v1.0.0（2026-08-10）
- **中文**：在 GitHub 新建公开仓库 `ksaMask123/artgallery.koplugin`，上传插件本体，配中英双语 README.md 与 CHANGELOG.md，并发布 v1.0.0 release（含打包 zip 供直接下载安装）。
- **English**: Created the public GitHub repo `ksaMask123/artgallery.koplugin`, uploaded the plugin with bilingual README.md and CHANGELOG.md, and published v1.0.0 with a downloadable zip.

## 阶段十七 / Phase 17 — 代码缺陷审查（2026-08-10）
- **中文**：聚焦阶段十六的拉伸缩放手势，逐段核查。修复一处真实缺陷：拉伸/铺满分支未门控 `_fullscreen`，会导致退出全屏后抽屉小图被非均匀拉伸变形；已加 `self._fullscreen and` 门控，守住"抽屉态恒为 contain"契约。并更正一处过时注释。其余（nil 兜底、手势路由、沉浸式取消链路、缩放回弹不变量）均健康。
- **English**: Reviewed the Phase-16 stretch zoom gestures line by line. Fixed a real defect: the stretch/cover fit branches were not gated by `_fullscreen`, which distorted the drawer thumbnail after exiting fullscreen; added a `self._fullscreen and` gate to honor the "drawer is always contain" contract. Also corrected a stale comment. The rest (nil fallbacks, gesture routing, immersive cancel chain, zoom-rebound invariants) were healthy.

## 阶段十六 / Phase 16 — 拉伸模式启用缩放手势（2026-08-10）
- **中文**：放开拉伸态的缩放手势——双击放大、双指张开放大、双指捏合缩小、按住图片移动全部可用。核心改动：删除两道缩放守卫、收窄拉伸渲染分支（`scale_factor==0` 才非均匀拉伸）、新增 `onZoomIn/onZoomOut` 修复"从填满态进不了缩放"的数学坑；缩放回弹到下限即归 0 回到拉伸填满。
- **English**: Enabled zoom gestures in stretch mode — double-tap zoom, pinch/spread zoom, and hold-to-pan all work. Key changes: removed two zoom guards, narrowed the stretch render branch (non-uniform stretch only at `scale_factor==0`), and added `onZoomIn/onZoomOut` overrides to fix the "cannot zoom out of fill state" math pitfall; zoom rebounding to the lower bound returns to 0 (stretch fill).

## 阶段十五（修订）/ Phase 15 (rev) — 布局简化：三态收进「右 ⋯」菜单（2026-08-10）
- **中文**：用户审阅后指出底部居中三态按钮簇多余，撤裁导航栏底部按钮簇，铺满/适配/拉伸三个选项统一收进「右 ⋯」菜单（单击切换、长按设默认）。
- **English**: After review, the bottom-center three-button cluster was deemed redundant; removed it and consolidated cover/contain/stretch into the `⋯` menu (tap to switch, long-press to set default).

## 阶段十五 / Phase 15 — 全屏「拉伸」模式（三态）+ 长按设默认（2026-08-10）
- **中文**：新增全屏三态填充（铺满/适配/拉伸）。拉伸态按屏幕长宽非均匀拉伸刚好填满整屏，不裁切、无黑边；默认 cover，顺序铺满→适配→拉伸；首次选拉伸弹一次性变形确认；「右 ⋯」菜单与导航栏均提供三态选项，长按可设为默认全屏看图模式。
- **English**: Added three fullscreen fit modes (cover/contain/stretch). Stretch non-uniformly scales the image to exactly fill the screen (no crop, no letterbox); default is cover, order cover→contain→stretch; first-time stretch shows a one-time distortion confirmation; both the `⋯` menu and the navbar expose the three modes, long-press sets the default fullscreen mode.

## 阶段十四 / Phase 14 — 菜单「关于 ArtGallery」汉化（2026-08-10）
- **中文**：统一插件对外中文名为「美术馆」，将菜单中残留的"关于 ArtGallery"与帮助文本一并汉化。
- **English**: Unified the public Chinese name as 美术馆 and localized the leftover "关于 ArtGallery" menu item and its help text.

## 阶段十三 / Phase 13 — 全屏沉浸式阅读（2026-08-10）
- **中文**：进入全屏即隐藏功能按钮 / 页码圆点 / 左上标题；点屏幕底部恢复，点图面延迟 0.35s 再隐藏（双击缩放不被打断）；补 `_pill_frame` 释放防泄漏。附 KPW3 内存/续航审查（内存低且受控、续航几乎无影响）。
- **English**: Entering fullscreen hides buttons / page dots / caption; tap the bottom edge to restore, tap the image to auto-hide after 0.35s (double-tap zoom unaffected); added `_pill_frame` free to prevent leaks. Includes a KPW3 memory/battery review (low, controlled memory; negligible battery impact).

## 阶段十二 / Phase 12 — EPUB 漫画看图同步进度（独立开关）（2026-08-10）
- **中文**：补齐滚动文档 EPUB 的看图进度同步，与分页文档各用独立开关、各自"只前进不倒退"。修复滚动文档下 `self.ui.paging` 非 nil 导致的误判（须先判 `self.ui.rolling`）。
- **English**: Added reading-progress sync for scrolling EPUB comics, with a separate toggle from paged documents, each advancing-only. Fixed the misclassification where `self.ui.paging` is non-nil under scrolling docs (must check `self.ui.rolling` first).

## 阶段十一 / Phase 11 — 看图同步书籍阅读进度（分页文档）（2026-08-10）
- **中文**：通过美术馆看图时同步更新书籍本身进度（CBZ/DjVu/PDF 等分页文档），避免看完漫画书本进度仍停第一页。
- **English**: Viewing images via ArtGallery now also advances the book's own progress for paged documents (CBZ/DjVu/PDF), so finishing a comic no longer leaves the book on page one.

## 阶段十 / Phase 10 — .MOBI 漫画支持方案（仅设计，搁置）（2026-08-09）
- **中文**：产出 .MOBI 漫画支持的纯设计方案，未落地实现，按用户要求搁置待议。
- **English**: Produced a design-only plan for .MOBI comic support; not implemented, deferred per user request.

## 阶段九 / Phase 9 — 代码审查与健壮性加固（2026-08-09）
- **中文**：用户要求查缺陷并加固，提升错误处理与边界健壮性。
- **English**: User-requested defect review and hardening of error handling and edge cases.

## 阶段八 / Phase 8 — 全屏渲染缺陷修复（2026-08-09）
- **中文**：修复全屏下右列露书页、图片只露左半两类渲染缺陷。
- **English**: Fixed two fullscreen render defects: book page bleeding on the right column, and image showing only its left half.

## 阶段七 / Phase 7 — 智能适配屏幕（2026-08-09）
- **中文**：自动选向（依图片宽高比旋转以最佳填满）+ 全屏铺满/适配切换。
- **English**: Auto-orientation (rotate by aspect ratio for best fill) plus fullscreen cover/contain toggle.

## 阶段六 / Phase 6 — 四项体验修复（2026-08-09）
- **中文**：菜单中文名、全书搜索记忆、按书清缓存、全屏铺满。
- **English**: Menu Chinese name, persistent in-book search memory, per-book cache clearing, fullscreen cover.

## 阶段五 / Phase 5 — 更名（Mirador → 美术馆）（2026-08-09）
- **中文**：插件对外名称统一为「美术馆 / ArtGallery」。
- **English**: Unified the public plugin name as 美术馆 / ArtGallery.

## 阶段四 / Phase 4 — 全面审查（2026-08-09）
- **中文**：对照 KOReader 纯洁源码 `koreader-kindle-v2026.07.1` 做全面审查。
- **English**: Full review against the pristine KOReader source `koreader-kindle-v2026.07.1`.

## 阶段三 / Phase 3 — 统一抽取/缓存层 + 收尾自检（2026-08-09）
- **中文**：统一图片抽取与缓存层，迁移旧收藏，收尾自检；v1.0.0 功能闭环。
- **English**: Unified the image extraction/cache layer, migrated legacy favorites, final self-check; v1.0.0 feature-complete.

## 阶段二 / Phase 2 — 移植 Illustrations 增强（2026-08-09）
- **中文**：收藏、更新+关于（继承）、最小尺寸（继承）、CBZ、三选一作用域，五项增强落地。
- **English**: Ported five enhancements: favorites, update+about (inherited), min-size (inherited), CBZ support, and three-way scope.

## 阶段一 / Phase 1 — 底座搭建 + 改名 + 全屏切换（2026-08-09）
- **中文**：搭建插件底座（基于 Glimpse 合并 Illustrations），完成改名 Mirador→美术馆，实现抽屉预览与一键全屏切换。
- **English**: Laid the plugin foundation (Glimpse + Illustrations merge), renamed Mirador→美术馆, and implemented drawer preview with one-tap fullscreen.

---

### 备注 / Notes
- 版本 / Version: `1.0.0`（见 `_meta.lua`）。
- 详细改动、风险表与方案文档见 `audit/` 目录（中文）。
  Detailed changes, risk tables, and design docs are in the `audit/` folder (Chinese).
