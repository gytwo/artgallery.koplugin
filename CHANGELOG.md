# 更新日志 / Changelog

> 中英双语摘要（按开发阶段倒序）。完整逐次改动时间线见 `audit/CHANGELOG.html`（中文）。
> Bilingual summary by development phase (newest first). The full chronological log is in `audit/CHANGELOG.html` (Chinese).

---

## 阶段三十二 / Phase 32 — 最大放大倍数可配置（吸收母插件 glance v1.2.2）（2026-08-13）
- **中文**：v1.0.16。吸收母插件 glimpse v1.2.2 的「可配置最大缩放」能力（对比报告 `D:\Download\artgallery_vs_glimpse_compare.html`）。改动：① 新增设置键 `artgallery_max_zoom`，`ArtGalleryViewer:init()`（:1000）读取（默认 1.5 保持旧行为）；② 插件菜单新增「最大放大倍数」子菜单（radio：1.5×/2.0×/2.5×/3.0×/4.0×，对齐母插件 150%–400%，:5661-5667），`text_func` 实时显示当前值；③ `_maxScale()`（:3572）抽屉态上限取该值，全屏态 `×2` 逻辑不变。纯配置改动，零新增渲染路径、零回归风险，改动约 20 行。校验：LuaJIT 语法 `SYNTAX OK`。依「发版须经同意」纪律未发 Release，待真机复核后授权。
- **English**: v1.0.16. Absorbed the configurable max-zoom from upstream glimpse v1.2.2 (compare report `D:\Download\artgallery_vs_glimpse_compare.html`). New setting `artgallery_max_zoom` read in `init()` (:1000, default 1.5 preserves old behavior); new plugin-menu submenu "最大放大倍数" (radio 1.5×–4.0×, :5661-5667) with a live `text_func`; `_maxScale()` (:3572) uses it as the drawer cap while fullscreen keeps ×2. Config-only change (~20 lines), no new render path, no regression risk. Syntax OK. Not released (pending user authorization per the release-discipline rule).

## 阶段三十一 / Phase 31 — 验收整改：补 logger.dbg 关键路径日志 + 主动 collectgarbage（2026-08-11）
- **中文**：v1.0.15。依「合并插件验收标准」静态体检后的待整改项（二.4 / 五.1）执行 hardening。① 关键路径日志：在 `init`（:3711）、网络更新检查开始/结束（_runUpdateCheck :5356/:5361）、配置持久化（`_safeFlush` :3973、`_saveFavRecords` :4146）补 `logger.dbg` 埋点，便于真机按 `[ArtGallery]` 过滤取证（debug 级别，常态静默）。② 主动内存释放：在全屏 viewer 拆除（onCloseWidget :5086 置 nil 后）与一次完整扫描结束（_getScan :4040 后）两处安全点显式 `pcall(collectgarbage, "collect")`，及时回收全屏位图（≈0.8MB/张）与扫描临时表，缓解 KPW3 低内存压力。③ 源码复核纠偏：技能 pending 项"2.2 进度保存防抖"经核查不成立——`_syncReadingProgress`（:3905）本身不写 settings，仅经核心推进阅读位置；唯一落盘是 `on_image_shown` 的 `doc_settings:saveSetting("artgallery_last")`(:4912)，仅画廊内翻新图触发一次，底层持久化由 KOReader 核心节流，故由硬 ⚠ 降级为可选优化，不在本轮改动。三项校验（语法/类顺序/加载）全过。
- **English**: v1.0.15. Remediation of acceptance pending items (2.4 / 5.1). ① Key-path logging: added `logger.dbg` at init (:3711), network update-check start/end (_runUpdateCheck :5356/:5361), and persistence chokepoints (`_safeFlush` :3973, `_saveFavRecords` :4146) for on-device forensics via `[ArtGallery]` filter (debug level, silent normally). ② Active GC: explicit `pcall(collectgarbage,"collect")` at two safe points — fullscreen viewer teardown (onCloseWidget :5086 after nil-ing) and after a full scan (_getScan :4040) — to promptly reclaim fullscreen bitmaps (~0.8MB each) and scan temporaries on low-memory KPW3. ③ Source review corrected the pending "2.2 progress-save debounce": `_syncReadingProgress` (:3905) doesn't write settings itself; the only write is `doc_settings:saveSetting("artgallery_last")` on image-shown (:4912), fired once per gallery navigation, with core-throttled persistence — downgraded from hard ⚠ to optional, not changed this round. All three checks (syntax / class-order / load) pass.

## 阶段三十 / Phase 30 — 关于文档菜单项配图标（轻量 Unicode）+ 眼睛 emoji 占位（2026-08-11）
- **中文**：v1.0.14。用户实机确认 v1.0.13 关于弹窗已稳定弹出；要求「关于」文档各带图标菜单项配真实图标（凡有图标菜单必配）。核验：插件菜单图标实为 `assets/*.svg`，而 TextViewer 用 `x_smallinfofont`=NotoSans-Regular 渲染，无法内联 SVG / 不渲染彩色 emoji（KOReader 缺 emoji 字体易变方框）→ 采用轻量 Unicode 近似（⤢▦◎↻↺➤↩☑⭐）。眼睛行加 👁 图标 + 保留文字「划掉眼睛」，依赖用户自行安装 emoji 字体渲染。校验 SYNTAX OK。用户授权"不升版本号、改完直接更新发行版" → 已发 GitHub Release v1.0.14（含 BLC 修复 + 图标文档）。
- **English**: v1.0.14. Confirmed v1.0.13 About popup is stable. Added lightweight Unicode glyphs (⤢▦◎↻↺➤↩☑⭐) approximating each menu icon in the About doc (TextViewer uses NotoSans-Regular, can't inline SVG/emoji). Eye row gets 👁 + "划掉眼睛" text (needs user-installed emoji font). User authorized direct release update without bumping version → GitHub Release v1.0.14 published.

## 阶段二十九 / Phase 29 — 根治「关于」弹窗：锁定真凶 BookLoadCover Plus（2026-08-11）
- **中文**：v1.0.13。KPW3 真机带调用栈日志彻底锁定「关于」弹窗白闪/无弹窗的真凶——同机安装的 BookLoadCover Plus 补丁（`patches/2-bookloadcover-plus.lua`）。其 `patchUIManagerShow`（:1203-1219）在 `shouldSuppressClosingNotice()` 为真时，对文本同时含「关闭」+「书」的 widget 命中 `textLooksLikeClosingBookNotice`（中文判定 `{ "关闭", "书" }`，:486），将 widget 的 `paintTo` 清空为 `function() end`、`visible=false` 静默吞掉（onShow 仍触发、paintTo 永不调用 → 看不见弹窗）。本「关于」长文本恰含「关闭全部」「在书中定位」命中误判。→ 推翻阶段二十八「残留 tap 误关」结论（v1.0.12 假设被此真因掩盖）。修复：移除 v1.0.12 的 scheduleIn(0.3)/TapClose 吸收和全部诊断埋点；`UIManager:show(tv)` 后检测 `tv._bookloadcover_suppressed`，恢复 `tv.paintTo`（从 `_original_paintTo_bookloadcover`）/`visible`/`hasVisibleContent` 并 `setDirty` 强制重绘；未装该补丁时分支跳过（防御性）。未 push、未发版（依"发版须经同意"纪律）。
- **English**: v1.0.13. Stack-trace logging on KPW3 pinpointed the real culprit of the About popup flash/missing — the BookLoadCover Plus patch on the same device. Its `patchUIManagerShow` misclassifies any widget whose text contains both "关闭" and "书" as a "close book" notice and silently nulls its `paintTo`. Removed v1.0.12's TapClose-absorb hack and all diagnostics; after `UIManager:show(tv)`, if `tv._bookloadcover_suppressed`, restore `paintTo`/`visible`/`hasVisibleContent` and force repaint (skipped when the patch isn't installed). Not pushed / not released.

## 阶段二十八 / Phase 28 — 路线 C 真机日志锁定根因·初步根治关于弹窗（2026-08-11）
- **中文**：v1.0.12。在关于回调注入 `[AG_DEBUG]` 时序日志，KPW3 真机回传后锁定当时的修复方向：viewer 实测为 nil（排除"叠加覆盖"），弹窗被 TextViewer 自身的 TapClose 残留抬起手势秒关（存活仅 0.119s）。据此移除旧延迟、加 0.3s TapClose 吸收窗。⚠ 事后被阶段二十九推翻：该"残留 tap 误关"假设被 BookLoadCover Plus 误判真因掩盖，v1.0.12 实为失败修复（用户已立"发版须经同意"纪律，未再擅自发版）。
- **English**: v1.0.12. Injected `[AG_DEBUG]` timing logs; on-device data pointed to TapClose residual-gesture closing the popup (viewer was nil, ruling out overlay). Applied a 0.3s TapClose-absorb window. ⚠ Superseded by Phase 29: this hypothesis was masked by the real BookLoadCover Plus cause; v1.0.12 was an ineffective fix.

## 阶段二十七 / Phase 27 — 关于弹窗借鉴 poker24 加 show_menu=false（2026-08-11）
- **中文**：v1.0.11。用户要求参考 poker24.koplugin 的「游戏规则」说明弹窗（同为 TextViewer 大面积纯文本）与 artgallery 修复后的「关于 美术馆」弹窗作比对。实测对比两处源码：poker24 经由自建 ButtonDialog 菜单（modal）主动 close 后同步 show、下层 GameUI 为按钮驱动不持续刷新 → 无需延迟；artgallery 经由读者主菜单 TouchMenu（callback 后才 closeMenu + 关闭动画整屏重绘）、下层 ArtGalleryViewer 为非 modal 全屏图片查看器、交互会刷新自身 → 必须保留 closeMenu + scheduleIn(0.3) + modal + close_callback（照搬 poker24 同步写法会退回 v1.0.8「无弹窗」）。两者共同精髓（先关菜单 + modal）artgallery 已吸收。唯一值得借鉴 poker24 的是 `show_menu = false`：关于说明为纯只读文档，顶部 ⋯ 菜单（复制/搜索）多余，且其注释指出 TextViewer 内部菜单若 modal 处理不当会被遮蔽。已在关于回调的 TextViewer 中加 `show_menu = false`（main.lua:5898 附近），延迟与 close_callback 不变。三项校验全过。
- **English**: v1.0.11. Per user request, compared poker24.koplugin's "game rules" popup (also a large TextViewer) with artgallery's fixed "About" popup. Source review: poker24 shows its TextViewer synchronously after actively closing its own modal ButtonDialog, and its underlying GameUI is button-driven (no continuous repaint) → no delay needed. artgallery shows the About popup via the reader's TouchMenu (which only closes after the callback, with a full-screen repaint animation) over a non-modal fullscreen image viewer that repaints on interaction → it must keep closeMenu + scheduleIn(0.3) + modal + close_callback (copying poker24's synchronous style would regress to v1.0.8's "no popup"). The shared essence (close-menu-first + modal) is already adopted. The one improvement worth borrowing is `show_menu = false`: the About text is read-only, so its top ⋯ menu (copy/search) is redundant and risks the internal menu being obscured. Added `show_menu = false` to the About TextViewer (main.lua:~5898); delay and close_callback unchanged. All three checks pass.

## 阶段二十六 / Phase 26 — 修复「关于弹窗被全屏 viewer 覆盖」与「放大图库收藏/忽略角标」（2026-08-11）
- **中文**：v1.0.10。修复 KPW3 实机复测反馈的 2 项。①「关于 美术馆」仍无弹窗（但新增白色矩形闪烁）——阶段二十五的「菜单关闭竞态」修复不完整：本项是在「viewer 已全屏显示」之上叠加 TextViewer，viewer 作为全屏组件仍会在其后刷新周期把说明覆盖掉（TextViewer 的 onShow 仅标脏一次）→ 白闪即消失。改法：给关于回调的 TextViewer 加 `modal = true`（KOReader 中 modal 独占输入，使 viewer 在说明显示期间收不到点击、不再刷新覆盖），关闭后由 `close_callback` 恢复 viewer 刷新；保留 closeMenu + scheduleIn(0.3)。② 图库（全部）缩略图右下角收藏 ⭐ / 忽略（划掉眼睛）角标尺寸由 `csize = scaleBySize(18)` 放大为 `scaleBySize(36)`（即两倍，同时用于 SVG 渲染分辨率，放大后仍清晰）。三项校验全过。
- **English**: v1.0.10. Fixed 2 real-device items. ① The "About" popup still didn't appear (with a new white-rectangle flash) — Phase 25's menu-close fix was incomplete: here TextViewer is overlaid on top of an already-fullscreen viewer, which keeps repainting over the popup (TextViewer's onShow only dirties itself once) → the flash vanishes. Fix: add `modal = true` to the About TextViewer (modal captures all input in KOReader, so the viewer underneath receives no taps and stops repainting over it); a `close_callback` restores the viewer's refresh on close; keep closeMenu + scheduleIn(0.3). ② The gallery (All) thumbnail corner badges — favorite ⭐ / ignored (crossed-out eye) — were enlarged from `scaleBySize(18)` to `scaleBySize(36)` (2×; also the SVG render resolution, so still crisp). All three checks pass.

## 阶段二十五 / Phase 25 — 修复「全屏图库忽略后退半屏」与「关于弹窗仍不显示」（2026-08-10）
- **中文**：v1.0.9。修复 KPW3 实机复测反馈的 2 个 bug。① 全屏图库内忽略 / 取消忽略后退半屏——`on_ignore`/`on_unignore` 关闭 viewer 后 `showViewer` 重开，新 viewer 默认抽屉态，且 `_toggleFullscreen` 在画廊态直接 return，无法恢复全屏；现于 `_pending_gallery` 传入 `fullscreen` 标志，在 `_enterGallery` 前直接置位 `_fullscreen` 与 `panel_ratio`（1.0=铺满）维持全屏。②「关于 美术馆」仍无弹窗——真实根因为菜单关闭竞态：回调同步 `show(TextViewer)` 后 `onMenuSelect` 立即 `closeMenu()`，菜单关闭重绘盖住弹窗；照搬本插件「打开美术馆」已验证模式，先 `closeMenu()` 再 `scheduleIn(0.3, 显示)`，消除竞态（阶段二十四曾误判「弹窗逻辑正确」）。上半屏闪烁系弹窗失败后乱点命中顶区唤起菜单所致，弹窗正常后消失。三项校验全过。
- **English**: v1.0.9. Fixed 2 real-device bugs. ① From a fullscreen gallery, ignore/un-ignore dropped back to the half-screen (drawer) gallery — `on_ignore`/`on_unignore` closed the viewer and `showViewer` reopened it in drawer mode, and `_toggleFullscreen` returns early in gallery mode; now the `fullscreen` flag is threaded through `_pending_gallery` and applied (set `_fullscreen` + `panel_ratio=1.0`) before `_enterGallery`. ② The "About" popup still didn't appear — the real cause was a menu-close race: the callback's synchronous `show(TextViewer)` was immediately covered by `onMenuSelect`'s `closeMenu()` repaint; mirroring this plugin's proven "Open ArtGallery" pattern (close menu first, then `scheduleIn(0.3, show)`) fixes it. The upper-screen flicker was a side effect of tapping around after the failed popup. All three checks pass.

---

## 阶段二十四 / Phase 24 — 修复四项真机 bug（收藏写入 / 忽略同步 / 图库黑底 / 关于与闪烁）（2026-08-10）
- **中文**：v1.0.8。修复 KPW3 实机复测反馈的 4 个 bug：① 收藏「无法写入收藏」——`addFavorite` 仅建末级目录、父目录 `artgallery` 缺失致 `lfs.mkdir` 静默失败，新增递归建目录 `_mkdirs` 解决；② 全屏忽略未同步到「图库（忽略）」——`_hideCurrentImage` 未迁移 `ignored_metas/ignored_list` 内存池，已镜像图库态分区迁移并重置 `_derived_ok`；③ 全屏进图库整屏变黑——背景判定加 `not self._gallery_mode` 使画廊恒白底；④ 关于弹窗与上半屏闪烁——移除关于项冗余 `help_text`，并门控沉浸态（`_chrome_hidden`）顶部菜单唤起以消除闪烁。三项校验（语法/类顺序/加载）全过。
- **English**: v1.0.8. Fixed 4 real-device bugs: ① "Cannot write favorite" — `addFavorite` only created the leaf dir and the parent `artgallery` was missing, silently failing `lfs.mkdir`; added a recursive `_mkdirs`. ② Fullscreen-ignore not appearing in the "Ignored" gallery tab — `_hideCurrentImage` didn't migrate the `ignored_metas/ignored_list` pools; now mirrors the gallery-state partition move and resets `_derived_ok`. ③ Black gallery background when entering from fullscreen — background now forced white in gallery mode. ④ About popup + upper-screen flicker — removed the redundant `help_text` and gated the immersive-state top-menu trigger to stop flicker. All three checks (syntax / class-order / load) pass.

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
- 版本 / Version: `1.0.8`（见 `_meta.lua`）。
- 详细改动、风险表与方案文档见 `audit/` 目录（中文）。
  Detailed changes, risk tables, and design docs are in the `audit/` folder (Chinese).
