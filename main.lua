--[[--
ArtGallery: peek at maps, family trees and other reference images from anywhere
in the book, without losing your reading position.

EPUB-only (crengine): the book's HTML is parsed directly (see
artgallery_scanner.lua), which gives real pixel dimensions plus captions/alt
text for filtering out ornaments and icons.
]]

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageViewer = require("ui/widget/imageviewer")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local LuaSettings = require("luasettings")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Notification = require("ui/widget/notification")
local OverlapGroup = require("ui/widget/overlapgroup")
local RenderImage = require("ui/renderimage")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

-- Plugin-local module (package.path for plugins is not guaranteed while our
-- own plugin is being loaded, and "scanner" would be a collision-prone name).
local _PLUGIN_DIR = (debug.getinfo(1, "S").source or ""):match("@?(.*)/[^/]*$") or "."
local scanner
do
    local ok, mod = pcall(dofile, _PLUGIN_DIR .. "/artgallery_scanner.lua")
    if ok then scanner = mod end
end

local LOG_TAG = "[ArtGallery]"
local SCOPE_KEY = "artgallery_scope"    -- "whole_book" | "read_so_far" | "current_page"
-- "all" = filtering off; anything else = the built-in "balanced" scanner
-- level. (The scanner still knows strict/relaxed internally, but they are
-- not exposed: corpus analysis showed strict silently drops real figures
-- and the level choice mostly created confusion.)
local FILTER_KEY = "artgallery_filter"
-- Invert images while night mode is on (global setting).
local INVERT_KEY = "artgallery_invert_night"
local NAV_BUTTONS_KEY = "artgallery_nav_buttons" -- prev/next buttons, off by default
-- 看图同步阅读进度（分页文档/漫画），默认开：在美术馆翻看图时把书籍本身的
-- 阅读位置推进到对应页，避免看完漫画后书本仍停在第一页。
local SYNC_PROGRESS_KEY = "artgallery_sync_progress"
-- 同上，但针对滚动文档（EPUB 等）：默认开，独立开关。用 xpointer 定位，
-- 复用「在书中显示」的已校验跳转逻辑。普通带插图文字书若表现异常可单独关闭。
local SYNC_PROGRESS_EPUB_KEY = "artgallery_sync_progress_epub"
local CAPTIONS_KEY = "artgallery_captions"        -- caption overlay, ON by default (nilOrTrue)
local TOP_MENU_KEY = "artgallery_top_menu_zone"   -- tap top strip → KOReader top menu, ON by default (nilOrTrue)
local SHADOW_KEY = "artgallery_disable_shadow"    -- drop the drawer's gradient shadow, OFF by default (e-ink ghost source)
local GESTURE_TIP_KEY = "artgallery_gesture_tip_shown" -- one-time menu-open nudge to bind a gesture
-- Which actions appear in the viewer's ⋯ popup ("Quick Actions", configured
-- from the plugin menu). Table order = popup order; `default` = shown unless
-- the user has toggled it. The six that were always in the popup default ON;
-- the three promoted from the plugin menu (restore/prevnext/captions) default
-- OFF, so out of the box the popup is exactly what it was before.
local QUICK_ACTIONS_KEY = "artgallery_quick_actions"
local QUICK_ACTIONS = {
    { key = "gallery",    default = true  },
    { key = "hide",       default = true  },
    { key = "mode",       default = true  },
    { key = "rotate",     default = true  },
    { key = "showinbook", default = true  },
    { key = "restore",    default = false },
    { key = "prevnext",   default = false },
    { key = "captions",   default = false },
    { key = "invert",     default = true  },
}
local function _quick_enabled(key)
    local cfg = G_reader_settings:readSetting(QUICK_ACTIONS_KEY)
    if type(cfg) == "table" and cfg[key] ~= nil then return cfg[key] end
    for _, d in ipairs(QUICK_ACTIONS) do
        if d.key == key then return d.default end
    end
    return false
end
local function _quick_label(key)
    return ({
        gallery    = _("图库"),
        hide       = _("忽略此图片"),
        mode       = _("模式切换"),
        rotate     = _("旋转90°"),
        showinbook = _("在书中定位"),
        restore    = _("恢复被忽略的图片"),
        prevnext   = _("显示导航按钮开关"),
        captions   = _("显示图片标题开关"),
        invert     = _("夜间模式反转图片"),
    })[key] or key
end

-- ── overlay chrome: dot pill and ⋯ button (from the Figma design) ──────────

-- 8x8 Bayer ordered-dither matrix (values 0..63): turns a continuous
-- darkness level into a binary black/white DOT PATTERN. e-ink panels have
-- few native gray levels and crush a true alpha gradient into visible
-- bands no matter what dither hint accompanies the refresh; a pattern
-- that's only ever fully opaque or fully transparent (dot DENSITY
-- encoding the darkness) leaves nothing for the hardware to quantize.
-- Used by the drawer shadow (_paintPanel) and the caption scrim.
local SHADOW_BAYER8 = {
    { 0, 32,  8, 40,  2, 34, 10, 42},
    {48, 16, 56, 24, 50, 18, 58, 26},
    {12, 44,  4, 36, 14, 46,  6, 38},
    {60, 28, 52, 20, 62, 30, 54, 22},
    { 3, 35, 11, 43,  1, 33,  9, 41},
    {51, 19, 59, 27, 49, 17, 57, 25},
    {15, 47,  7, 39, 13, 45,  5, 37},
    {63, 31, 55, 23, 61, 29, 53, 21},
}

-- Anti-aliased filled circle blending fg over bg by edge coverage
-- (paintCircle is hard-edged and looks jagged at dot sizes). All chrome is
-- drawn black-on-white; night mode inverts the framebuffer for free, which
-- yields the design's dark variant (outlined pill, white dialog ring).
local function paint_dot(bb, cx, cy, r, fg, bg)
    for dy = -r - 1, r + 1 do
        for dx = -r - 1, r + 1 do
            local cov = r - math.sqrt(dx * dx + dy * dy) + 0.5
            if cov > 0 then
                if cov > 1 then cov = 1 end
                local v = math.floor(bg + cov * (fg - bg) + 0.5)
                bb:paintRect(cx + dx, cy + dy, 1, 1, Blitbuffer.Color8(v))
            end
        end
    end
end

-- One dot per image, drawn on the pill's black background: current one
-- white, the others 40% white (per the design SVG — same size, dimmed).
-- `pitch` is set by the caller from the space actually available between
-- the chrome buttons (so more images stay dots before the "n / N"
-- fallback kicks in).
local ArtGalleryDots = Widget:extend{
    nb = 1,
    cur = 1,
    dot_r = Screen:scaleBySize(3),
    pitch = Screen:scaleBySize(11),
    height = Screen:scaleBySize(10),
}

function ArtGalleryDots:getSize()
    return Geom:new{
        w = (self.nb - 1) * self.pitch + 2 * self.dot_r,
        h = self.height,
    }
end

function ArtGalleryDots:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self:getSize().w, h = self.height }
    local cy = y + math.floor(self.height / 2)
    local x0 = x + self.dot_r
    for i = 1, self.nb do
        local cx = x0 + (i - 1) * self.pitch
        paint_dot(bb, cx, cy, self.dot_r, i == self.cur and 0xFF or 0x66, 0x00)
    end
end

-- The ⋯ icon for the more button, drawn as three dots (font-independent).
local ArtGalleryEllipsis = Widget:extend{
    size = Screen:scaleBySize(18),
}

function ArtGalleryEllipsis:getSize()
    return Geom:new{ w = self.size, h = self.size }
end

function ArtGalleryEllipsis:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.size, h = self.size }
    local r = math.max(2, math.floor(self.size / 9))
    local cx = x + math.floor(self.size / 2)
    local cy = y + math.floor(self.size / 2)
    paint_dot(bb, cx - 3 * r, cy, r, 0x00, 0xFF)
    paint_dot(bb, cx, cy, r, 0x00, 0xFF)
    paint_dot(bb, cx + 3 * r, cy, r, 0x00, 0xFF)
end

-- Per-pixel-alpha BBRGB32 stencil of a rounded rectangle with an
-- anti-aliased `stroke`-wide outline; `fill` and `outline` are 0–255
-- grays. Alpha-blitting this paints smooth rounded shapes over any
-- background — FrameContainer radii are hard-edged and look jagged at
-- chrome sizes. r = h/2 gives a stadium. Pass fill = nil for a border-ONLY
-- stencil (transparent interior): just the outline ring, so whatever is
-- behind shows through the middle.
local function make_rounded_stencil(w, h, r, stroke, fill, outline)
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
    local no_fill = fill == nil
    for py = 0, h - 1 do
        for px = 0, w - 1 do
            local sx = math.min(math.max(px + 0.5, r), w - r)
            local sy = math.min(math.max(py + 0.5, r), h - r)
            local dx, dy = px + 0.5 - sx, py + 0.5 - sy
            local d = math.sqrt(dx * dx + dy * dy)
            local cov = math.min(math.max(r - d + 0.5, 0), 1)
            if cov > 0 then
                local t_in = math.min(math.max((r - stroke) - d + 0.5, 0), 1)
                if no_fill then
                    -- keep only the ring: full alpha in the stroke band,
                    -- fading to transparent as t_in rises into the interior
                    local a = cov * (1 - t_in)
                    if a > 0 then
                        bb:setPixel(px, py, Blitbuffer.ColorRGB32(
                            outline, outline, outline,
                            math.floor(a * 255 + 0.5)))
                    end
                else
                    local g = math.floor(outline + t_in * (fill - outline) + 0.5)
                    bb:setPixel(px, py, Blitbuffer.ColorRGB32(
                        g, g, g, math.floor(cov * 255 + 0.5)))
                end
            end
        end
    end
    return bb
end

-- The stadium-shaped pill behind the dots / "n / N" counter. Default is
-- the design's black fill + 2px white stroke (keeps the dots legible over
-- dark images). `inverted` flips it to a white fill + black stroke: used
-- for the "n / N" text fallback, which as a solid black block with white
-- text drew far more attention than the light dots pill it replaces.
local ArtGalleryPill = WidgetContainer:extend{
    inner = nil, -- content, centered
    padding_h = Screen:scaleBySize(9),
    height = Screen:scaleBySize(21),
    stroke = Screen:scaleBySize(2),
    inverted = nil,
}

function ArtGalleryPill:init()
    self[1] = self.inner
end

function ArtGalleryPill:getSize()
    local inner = self.inner:getSize()
    return Geom:new{
        w = inner.w + 2 * self.padding_h,
        h = math.max(self.height, inner.h),
    }
end

function ArtGalleryPill:paintTo(bb, x, y)
    local size = self:getSize()
    local w, h = size.w, size.h
    self.dimen = Geom:new{ x = x, y = y, w = w, h = h }
    if not self._bg_bb or self._bg_w ~= w or self._bg_h ~= h then
        if self._bg_bb then self._bg_bb:free() end
        local fill = self.inverted and 0xFF or 0x00
        local outline = self.inverted and 0x00 or 0xFF
        self._bg_bb = make_rounded_stencil(w, h, h / 2, self.stroke, fill, outline)
        self._bg_w, self._bg_h = w, h
    end
    bb:alphablitFrom(self._bg_bb, x, y, 0, 0, w, h)
    local inner_size = self.inner:getSize()
    self.inner:paintTo(bb,
        x + math.floor((w - inner_size.w) / 2),
        y + math.floor((h - inner_size.h) / 2))
end

function ArtGalleryPill:free(...)
    if self._bg_bb then
        self._bg_bb:free()
        self._bg_bb = nil
    end
    WidgetContainer.free(self, ...)
end

-- A small numbered badge for a gallery thumbnail's corner: white rounded
-- square, thin black border, bold black number — so the reading order is
-- explicit and a specific image is findable, without disturbing the
-- masonry layout. Day polarity (night's fb inversion → dark badge, light
-- number), same as the rest of the chrome. Widens for 2+ digit numbers.
local ArtGalleryBadge = Widget:extend{
    num = 1,
    glyph = nil, -- when set, drawn instead of the number (e.g. "+" on Ignored)
    height = Screen:scaleBySize(17),
    radius = Screen:scaleBySize(4),
    stroke = Screen:scaleBySize(1),
    pad_h = Screen:scaleBySize(4),
}

function ArtGalleryBadge:init()
    self._txt = TextWidget:new{
        text = self.glyph or tostring(self.num),
        face = Font:getFace("cfont", 11),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    self._w = math.max(self.height, self._txt:getSize().w + 2 * self.pad_h)
end

function ArtGalleryBadge:getSize()
    return Geom:new{ w = self._w, h = self.height }
end

function ArtGalleryBadge:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self._w, h = self.height }
    if not self._bg_bb then
        self._bg_bb = make_rounded_stencil(self._w, self.height,
            self.radius, self.stroke, 0xFF, 0x00)
    end
    bb:alphablitFrom(self._bg_bb, x, y, 0, 0, self._w, self.height)
    local ts = self._txt:getSize()
    self._txt:paintTo(bb, x + math.floor((self._w - ts.w) / 2),
        y + math.floor((self.height - ts.h) / 2))
end

function ArtGalleryBadge:free()
    if self._bg_bb then self._bg_bb:free(); self._bg_bb = nil end
    if self._txt then self._txt:free() end
end

-- The ⋯ button: solid white rounded square with an anti-aliased 2px black
-- border, so it stays visible over any image. `disabled` grays the border
-- and icon (used by prev/next at the ends of the image list); `inverted`
-- is the pressed state.
local ArtGalleryMoreButton = Widget:extend{
    size = Screen:scaleBySize(42),       -- 2px larger than the old 40 (icon/border unchanged)
    radius = Screen:scaleBySize(8),
    stroke = Screen:scaleBySize(2),
    icon = nil,                          -- SVG path; nil draws the ⋯ glyph
    icon_size = Screen:scaleBySize(18),
    disabled = nil,
    disabled_gray = 0xB4,                -- border/icon gray when disabled
}

function ArtGalleryMoreButton:getSize()
    return Geom:new{ w = self.size, h = self.size }
end

function ArtGalleryMoreButton:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.size, h = self.size }
    if not self._bg_bb then
        -- disabled (dead-end prev/next): no white fill — just the dimmed
        -- outline ring (fill=nil) so the image shows through; the icon is
        -- lifted to the same gray below. NB: an explicit if, not
        -- `disabled and nil or 0xFF` — that idiom returns 0xFF when the
        -- middle value is nil, which is exactly the disabled case.
        local fill = 0xFF
        if self.disabled then fill = nil end
        self._bg_bb = make_rounded_stencil(self.size, self.size,
            self.radius, self.stroke, fill,
            self.disabled and self.disabled_gray or 0x00)
    end
    bb:alphablitFrom(self._bg_bb, x, y, 0, 0, self.size, self.size)
    -- icon: an SVG (chevrons for prev/next) or the default ⋯ glyph
    if self.icon and not self._icon_bb then
        local ok, ibb = pcall(RenderImage.renderSVGImageFile, RenderImage,
            self.icon, self.icon_size, self.icon_size)
        if ok and ibb then
            if self.disabled then
                -- lift the black strokes to gray, keeping the AA alpha
                local g = self.disabled_gray
                for yy = 0, ibb:getHeight() - 1 do
                    for xx = 0, ibb:getWidth() - 1 do
                        local c = ibb:getPixel(xx, yy):getColorRGB32()
                        if c.alpha > 0 then
                            ibb:setPixel(xx, yy,
                                Blitbuffer.ColorRGB32(g, g, g, c.alpha))
                        end
                    end
                end
            end
            self._icon_bb = ibb
        end
    end
    if self._icon_bb then
        bb:alphablitFrom(self._icon_bb,
            x + math.floor((self.size - self.icon_size) / 2),
            y + math.floor((self.size - self.icon_size) / 2),
            0, 0, self._icon_bb:getWidth(), self._icon_bb:getHeight())
    else
        if not self._icon then
            self._icon = ArtGalleryEllipsis:new{}
        end
        local isz = self._icon:getSize()
        self._icon:paintTo(bb,
            x + math.floor((self.size - isz.w) / 2),
            y + math.floor((self.size - isz.h) / 2))
    end
    if self.inverted then
        -- pressed state: invert the rendered button, but only within its
        -- rounded silhouette (the stencil's alpha) — a square invertRect
        -- would flip the image corners outside the radius too
        for yy = 0, self.size - 1 do
            for xx = 0, self.size - 1 do
                local a = self._bg_bb:getPixel(xx, yy):getColorRGB32().alpha
                if a > 127 then
                    bb:setPixel(x + xx, y + yy,
                        bb:getPixel(x + xx, y + yy):getColorRGB32():invert())
                end
            end
        end
    end
end

function ArtGalleryMoreButton:free()
    if self._bg_bb then
        self._bg_bb:free()
        self._bg_bb = nil
    end
    if self._icon_bb then
        self._icon_bb:free()
        self._icon_bb = nil
    end
end

-- Caption overlay: the image's caption tucked into the top-left corner of
-- the drawer as a solid tab — white fill, black text, ONLY the bottom-right
-- corner rounded (the other three sit flush in the screen corner). Painted
-- in DAY polarity, so night mode's framebuffer inversion flips it to a black
-- tab with white text automatically — the wanted look holds both ways with
-- no per-mode branching. Truncates to max_width.
local ArtGalleryCaption = Widget:extend{
    text = "",
    max_width = 0,
    pad_left = Screen:scaleBySize(6),  -- left text inset (tight to the corner)
    pad_right = Screen:scaleBySize(8), -- right text inset
    pad_top = 0,                       -- top text inset (flush)
    pad_bottom = Screen:scaleBySize(2),-- bottom text inset
    radius = Screen:scaleBySize(10),   -- bottom-right corner only
}

function ArtGalleryCaption:init()
    local face = Font:getFace("cfont", 12)
    -- Measure the caption's natural single-line width so a short caption keeps
    -- a snug tab, and only wrap (grow downward) when it would exceed max_width.
    local probe = TextWidget:new{ text = self.text, face = face, bold = true }
    local natural = probe:getSize().w
    probe:free()
    local box_w = math.min(natural + Screen:scaleBySize(1), self.max_width)
    if box_w < 1 then box_w = 1 end
    self._text = TextBoxWidget:new{
        text = self.text,
        face = face,
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = box_w,
        alignment = "left",
        -- height omitted -> auto, grows with the number of wrapped lines
    }
end

function ArtGalleryCaption:getSize()
    local s = self._text:getSize()
    return Geom:new{
        w = s.w + self.pad_left + self.pad_right,
        h = s.h + self.pad_top + self.pad_bottom,
    }
end

-- Solid white tab with the caption text baked in, only the bottom-right corner
-- rounded (anti-aliased). TextBoxWidget:paintTo blits an opaque rectangle, so
-- the text is composited FIRST and the corner is carved LAST — otherwise the
-- opaque text box would refill the rounded corner. Opaque everywhere except
-- the carved corner, so it reads as a clean-edged tab over the image and
-- inverts to solid black at night.
function ArtGalleryCaption:_buildBg(w, h)
    self._bg_bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
    self._bg_bb:fill(Blitbuffer.ColorRGB32(255, 255, 255, 255))
    -- Bake the wrapped text onto the white tab.
    self._text:paintTo(self._bg_bb, self.pad_left, self.pad_top)
    -- Carve the anti-aliased bottom-right corner on the finished composite.
    local r = self.radius
    if r > 0 then
        local cx, cy = w - r, h - r  -- arc centre of the bottom-right corner
        for py = math.floor(cy), h - 1 do
            for px = math.floor(cx), w - 1 do
                local dx, dy = px + 0.5 - cx, py + 0.5 - cy
                local cov = r - math.sqrt(dx * dx + dy * dy) + 0.5
                local a
                if cov <= 0 then a = 0
                elseif cov < 1 then a = math.floor(cov * 255 + 0.5) end
                if a then
                    self._bg_bb:setPixel(px, py, Blitbuffer.ColorRGB32(255, 255, 255, a))
                end
            end
        end
    end
end

function ArtGalleryCaption:paintTo(bb, x, y)
    self.dimen = self:getSize()
    self.dimen.x, self.dimen.y = x, y
    local w, h = self.dimen.w, self.dimen.h
    if not self._bg_bb then self:_buildBg(w, h) end
    bb:alphablitFrom(self._bg_bb, x, y, 0, 0, w, h)
end

function ArtGalleryCaption:free()
    if self._text then self._text:free() end
    if self._bg_bb then self._bg_bb:free(); self._bg_bb = nil end
end

-- A pill-shaped text button in the SAME style as the ⋯ button: solid white
-- rounded rectangle, anti-aliased 2px black border, black text — and the
-- same height, so the two read as one control set. An optional black-line
-- SVG icon sits to the left of the text. Width fits its contents.
local ArtGalleryTextButton = Widget:extend{
    text = "",
    bold = false,
    icon = nil,                          -- absolute path to an SVG, or nil
    icon_size = Screen:scaleBySize(16),
    icon_gap = Screen:scaleBySize(7),
    height = Screen:scaleBySize(42),     -- 2px larger than the old 40 (icon/border unchanged)
    radius = Screen:scaleBySize(8),
    stroke = Screen:scaleBySize(2),
    padding_h = Screen:scaleBySize(14),
    inverted = nil,                      -- pressed state, see paintTo
}

function ArtGalleryTextButton:init()
    self._text_wg = TextWidget:new{
        text = self.text,
        face = Font:getFace("cfont", 15),
        bold = self.bold,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local content_w = self._text_wg:getSize().w
    if self.icon then
        -- render once; a black-line SVG on transparent, alpha-blitted so
        -- it inherits the white button (and night-mode inversion) like text
        local ok, ibb = pcall(RenderImage.renderSVGImageFile, RenderImage,
            self.icon, self.icon_size, self.icon_size)
        if ok and ibb then
            self._icon_bb = ibb
            content_w = content_w + self.icon_size + self.icon_gap
        end
    end
    self._w = content_w + 2 * self.padding_h
end

function ArtGalleryTextButton:getSize()
    return Geom:new{ w = self._w, h = self.height }
end

-- Stretch (or shrink) to an explicit width; the label stays centred (see
-- paintTo). Used to make the gallery Shown/Ignored toggle fill the bottom bar.
function ArtGalleryTextButton:setWidth(w)
    if w and w > 0 and w ~= self._w then
        self._w = w
        if self._bg_bb then self._bg_bb:free(); self._bg_bb = nil end
    end
end

function ArtGalleryTextButton:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self._w, h = self.height }
    if not self._bg_bb then
        self._bg_bb = make_rounded_stencil(self._w, self.height,
            self.radius, self.stroke, 0xFF, 0x00)
    end
    bb:alphablitFrom(self._bg_bb, x, y, 0, 0, self._w, self.height)
    local tsz = self._text_wg:getSize()
    local icon_w = self._icon_bb and (self.icon_size + self.icon_gap) or 0
    local cx = x + math.floor((self._w - icon_w - tsz.w) / 2)
    if self._icon_bb then
        bb:alphablitFrom(self._icon_bb, cx,
            y + math.floor((self.height - self.icon_size) / 2),
            0, 0, self._icon_bb:getWidth(), self._icon_bb:getHeight())
        cx = cx + self.icon_size + self.icon_gap
    end
    self._text_wg:paintTo(bb, cx, y + math.floor((self.height - tsz.h) / 2))
    if self.inverted then
        -- pressed state: invert within the rounded silhouette only (the
        -- stencil's alpha), same trick as ArtGalleryMoreButton
        for yy = 0, self.height - 1 do
            for xx = 0, self._w - 1 do
                local a = self._bg_bb:getPixel(xx, yy):getColorRGB32().alpha
                if a > 127 then
                    bb:setPixel(x + xx, y + yy,
                        bb:getPixel(x + xx, y + yy):getColorRGB32():invert())
                end
            end
        end
    end
end

function ArtGalleryTextButton:free()
    if self._bg_bb then
        self._bg_bb:free()
        self._bg_bb = nil
    end
    if self._icon_bb then
        self._icon_bb:free()
        self._icon_bb = nil
    end
    if self._text_wg then
        self._text_wg:free()
    end
end

-- One row of the ⋯ popup: an optional left icon (black-line SVG on
-- transparent, alpha-blitted so it inherits the white row and night-mode
-- inversion like the text) then the label, both left-aligned. The icon
-- column is reserved for every row when ANY row has an icon, so labels
-- line up whether or not their row carries one. Painting-only; the parent
-- menu does hit-testing off self.dimen.
local ArtGalleryMenuRow = Widget:extend{
    text = "",
    icon_bb = nil,      -- pre-rendered icon blitbuffer, or nil
    lead_wg = nil,      -- widget drawn in the icon column instead (checkbox)
    width = 0,          -- shared row width (set by the menu)
    height = Screen:scaleBySize(44),
    icon_col = 0,       -- reserved icon+gap width (0 if no row has an icon)
    icon_size = Screen:scaleBySize(18),
    pad_left = Screen:scaleBySize(16),
}

function ArtGalleryMenuRow:init()
    self._text_wg = TextWidget:new{
        text = self.text,
        face = Font:getFace("cfont", 15),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
end

function ArtGalleryMenuRow:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function ArtGalleryMenuRow:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    -- icon column: an SVG icon, or a lead widget (checkbox glyph), centred
    if self.icon_bb then
        bb:alphablitFrom(self.icon_bb,
    x + self.pad_left + math.floor((self.icon_size - self.icon_bb:getWidth()) / 2),
    y + math.floor((self.height - self.icon_bb:getHeight()) / 2),
    0, 0, self.icon_bb:getWidth(), self.icon_bb:getHeight())   -- ✅ 修正
    elseif self.lead_wg then
        local lsz = self.lead_wg:getSize()
        self.lead_wg:paintTo(bb,
            x + self.pad_left + math.floor((self.icon_size - lsz.w) / 2),
            y + math.floor((self.height - lsz.h) / 2))
    end
    local tsz = self._text_wg:getSize()
    self._text_wg:paintTo(bb,
        x + self.pad_left + self.icon_col,
        y + math.floor((self.height - tsz.h) / 2))
end

function ArtGalleryMenuRow:free()
    if self._text_wg then self._text_wg:free() end
    if self.lead_wg then self.lead_wg:free() end
end

-- White rounded card with an anti-aliased border, sized to its single
-- child. Drawn from the shared stencil rather than a FrameContainer radius,
-- whose hard-edged rounding leaves grit in the corners at these sizes.
-- Painted in three passes: a solid white rounded fill, then the child, then
-- the border ring ON TOP — so full-width content (the gray row dividers)
-- tucks under the outline instead of drawing over it (FrameContainer paints
-- its border last for the same reason).
local ArtGalleryCard = WidgetContainer:extend{
    radius = Screen:scaleBySize(9),
    stroke = Screen:scaleBySize(2),
    outline = 0x00,     -- black border, matching the old FrameContainer
}

function ArtGalleryCard:getSize()
    return self[1]:getSize()
end

function ArtGalleryCard:paintTo(bb, x, y)
    local sz = self[1]:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = sz.w, h = sz.h }
    if not self._fill_bb or self._bg_w ~= sz.w or self._bg_h ~= sz.h then
        if self._fill_bb then self._fill_bb:free() end
        if self._ring_bb then self._ring_bb:free() end
        self._bg_w, self._bg_h = sz.w, sz.h
        -- solid white rounded rect (outline == fill, so no visible edge yet)
        self._fill_bb = make_rounded_stencil(sz.w, sz.h,
            self.radius, self.stroke, 0xFF, 0xFF)
        -- border-only ring, laid over the content afterwards
        self._ring_bb = make_rounded_stencil(sz.w, sz.h,
            self.radius, self.stroke, nil, self.outline)
    end
    bb:alphablitFrom(self._fill_bb, x, y, 0, 0, sz.w, sz.h)
    self[1]:paintTo(bb, x, y)
    bb:alphablitFrom(self._ring_bb, x, y, 0, 0, sz.w, sz.h)
end

function ArtGalleryCard:free(full)
    if self._fill_bb then self._fill_bb:free(); self._fill_bb = nil end
    if self._ring_bb then self._ring_bb:free(); self._ring_bb = nil end
    WidgetContainer.free(self, full)
end

-- A small popup menu of icon+text rows, anchored to a widget (the ⋯
-- button). White rounded card with a thin border, gray separators between
-- rows; tap a row to fire its callback, tap outside to dismiss. Built in
-- our own style instead of ButtonDialog because a ButtonDialog button
-- shows an icon OR text, never both.
local ArtGalleryPopupMenu = InputContainer:extend{
    items = nil,    -- { {text=, icon=<svg path or nil>, callback=}, ... }
    anchor = nil,   -- function -> Geom (like MovableContainer's anchor)
    pad_left = Screen:scaleBySize(16),
    pad_right = Screen:scaleBySize(16),
    icon_size = Screen:scaleBySize(18),
    icon_gap = Screen:scaleBySize(12),
    row_h = Screen:scaleBySize(44),
}

function ArtGalleryPopupMenu:init()
    self._icon_bbs = {}
    local any_lead = false
    for _, it in ipairs(self.items) do
        if it.icon or it.check ~= nil then any_lead = true break end
    end
    local icon_col = any_lead and (self.icon_size + self.icon_gap) or 0

    -- widest label decides the shared row width
    local max_text_w = 0
    local probes = {}
    for i, it in ipairs(self.items) do
        local wg = TextWidget:new{
            text = it.text, face = Font:getFace("cfont", 15), bold = true,
        }
        probes[i] = wg
        max_text_w = math.max(max_text_w, wg:getSize().w)
    end
    for _, wg in ipairs(probes) do wg:free() end
    local row_w = self.pad_left + icon_col + max_text_w + self.pad_right

    self._rows = {}
    local vg = VerticalGroup:new{ align = "left" }
    for i, it in ipairs(self.items) do
        local icon_bb, lead_wg
        if it.icon then
            local ok, ibb = pcall(RenderImage.renderSVGImageFile, RenderImage,
                it.icon, self.icon_size, self.icon_size)
            if ok and ibb then
                icon_bb = ibb
                self._icon_bbs[#self._icon_bbs + 1] = ibb
            end
        elseif it.check ~= nil then
            -- checkbox glyph, a bit larger than the label, drawn in the
            -- icon column so it aligns with the other rows' icons
            lead_wg = TextWidget:new{
                text = it.check and "☑" or "☐",
                face = Font:getFace("cfont", 22),
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
        end
        local row = ArtGalleryMenuRow:new{
            text = it.text, icon_bb = icon_bb, lead_wg = lead_wg, width = row_w,
            height = self.row_h, icon_col = icon_col,
            icon_size = self.icon_size, pad_left = self.pad_left,
        }
        row._callback = it.callback
        self._rows[#self._rows + 1] = row
        table.insert(vg, row)
        if i < #self.items then
            table.insert(vg, LineWidget:new{
                background = Blitbuffer.COLOR_GRAY,
                dimen = Geom:new{ w = row_w, h = Screen:scaleBySize(1) },
            })
        end
    end

    self.movable = MovableContainer:new{
        anchor = self.anchor,
        ArtGalleryCard:new{ vg },
    }
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        self.movable,
    }
    if Device:isTouchDevice() then
        self.ges_events.Tap = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{ x = 0, y = 0,
                    w = Screen:getWidth(), h = Screen:getHeight() },
            },
        }
    end
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
end

-- The widget's own dimen is the full screen (CenterContainer), so default
-- show/close refreshes would flash the whole drawer; refresh only the
-- anchored menu rectangle instead (known after MovableContainer paints).
function ArtGalleryPopupMenu:dismiss()
    local region = self.movable.dimen
    if region and self._restore_region then
        region = region:combine(self._restore_region)
    end
    UIManager:close(self, "ui", region)
end

function ArtGalleryPopupMenu:onTap(_, ges)
    for _, row in ipairs(self._rows) do
        if row.dimen and ges.pos:intersectWith(row.dimen) then
            local cb = row._callback
            self:dismiss()
            if cb then cb() end
            return true
        end
    end
    -- tapped a separator or outside: dismiss
    self:dismiss()
    return true
end

function ArtGalleryPopupMenu:onClose()
    self:dismiss()
    return true
end

function ArtGalleryPopupMenu:onCloseWidget()
    for _, ibb in ipairs(self._icon_bbs) do ibb:free() end
    self._icon_bbs = {}
    if self.on_dismiss then self.on_dismiss() end
end

-- ── viewer ──────────────────────────────────────────────────────────────────
-- ImageViewer already provides pan/zoom/rotate, multi-image lists with lazy
-- per-image render functions, captions and resource cleanup. We add:
--   * horizontal swipe switches images while in fit-to-screen mode
--     (when zoomed in, swipe keeps panning, as upstream)
--   * a dot indicator instead of the progress bar (as many dots as fit
--     between the chrome buttons; an "n / N" counter beyond that)
--   * a ⋯ overlay button with remove/rotate/invert actions
-- Layout (Figma "New Design", drawn at 630×730): a full-height drawer
-- anchored to the LEFT screen edge, ~80% of the screen wide, with a strip
-- of the page visible on the right. Square on the left (flush with the
-- edge), rounded on the right, 2px black border, and a soft black gradient
-- shadow cast to the right. The drawer is painted from a stencil in
-- _paintPanel (FrameContainer can't do per-corner radii).

local ArtGalleryViewer = ImageViewer:extend{
    image_metas = nil,     -- parallel to the image list: scanner records
    gallery_hidden_count = 0, -- images the chapter scope holds back (heading)
    on_image_shown = nil,  -- function(meta, index)
    on_hide = nil,         -- function(meta)
    on_show_in_book = nil, -- function(meta): jump the reader to the image
    on_rotate = nil,       -- function(rotation): re-layout + reopen
    on_show_menu = nil,    -- function(): open KOReader's top menu (only)
    scope = nil,           -- effective scope: "read_so_far" | "whole_book"
    on_toggle_scope = nil, -- function(): flip the scope setting and reopen
    hidden_count = nil,    -- function() -> number of per-book hidden images
    on_restore_hidden = nil, -- function(): restore hidden images and reopen
    get_pref = nil,        -- function(meta) -> per-image prefs {rotation=}
    set_pref = nil,        -- function(meta, key, value)
    -- Gallery tabs. The single-image view uses image/image_metas (= the
    -- primary pool); the Gallery shows shown_* or ignored_* per active tab.
    shown_metas = nil,     -- scanner records for the shown collection
    shown_list = nil,      -- parallel render closures for shown_metas
    ignored_metas = nil,   -- scanner records the filter dropped / user hid
    ignored_list = nil,    -- parallel render closures for ignored_metas
    primary_tab = "shown", -- which pool the single-image view is showing
    on_ignore = nil,       -- function(meta, tab, page): move to Ignored
    on_unignore = nil,     -- function(meta, tab, page): add back to Shown
    -- gallery masonry (⋯ → Gallery): fixed-width columns, variable heights
    gallery_cols = 3,
    -- No title bar and no button row: everything is image. Position comes
    -- from the dot pill, actions from the ⋯ button, closing from
    -- tap-outside, multiswipe or Back.
    with_title_bar = false,
    -- Zoom ceiling as a multiple of the image's native resolution: pinch may
    -- push a little past 100% (actual pixel size) for readability, but not so
    -- far that upscaling turns to mush. Double-tap still stops at 100%.
    max_zoom_of_native = 1.5,
    -- Drawer metrics from the design (design px == px at the reference DPI)
    panel_ratio = 505 / 630,               -- of screen width
    panel_ratio_full = 1.0,                -- 一键全屏：抽屉铺满整屏
    panel_vgap = 0,                        -- full height, border included
    panel_border = Screen:scaleBySize(2),
    panel_radius = Screen:scaleBySize(24), -- right corners only
    -- gradient shadow: 50% black at its (covered) start, fading rightwards;
    -- the visible part beyond the panel edge starts around 25%
    shadow_width = Screen:scaleBySize(131),
    shadow_overlap = Screen:scaleBySize(66), -- part hidden under the panel
    -- gap between the image area and the panel's rounded right edge
    image_right_gap = Screen:scaleBySize(12),
    image_padding = Screen:scaleBySize(2),
    -- Numeric alpha in (0,1) makes UIManager:setDirty flag every window
    -- below us dirty too, so the translucent shadow always blends against a
    -- freshly painted page instead of accumulating over its own output.
    alpha = 0.25,
    -- Double-tap (toggle fit ↔ 2×) is detected manually from plain Tap
    -- events (see onTap/_checkDoubleTap): enabling the input layer's
    -- double-tap would delay EVERY tap ~300ms for disambiguation, making
    -- tap-outside-to-close and image switching feel sluggish — and it
    -- zoomed on double-taps outside the drawer. Must be an explicit true,
    -- not nil: UIManager restores the flag from the topmost widget with a
    -- non-nil field whenever a window above us closes, and if the user
    -- has double tap enabled reader-wide, ReaderUI's false would win and
    -- silently swallow our tap pairs into unhandled double_tap gestures.
    disable_double_tap = true,
}

function ArtGalleryViewer:init()
    self._cur_rotation = self:_prefFor(1).rotation or 0
    -- 全屏默认「铺满」(cover)：图片占满整屏、溢出部分裁切。置 true 即转
    -- 「适配」(contain)，整图完整可见（适合地图/示意图）。抽屉态永远 contain。
    -- 全屏填充模式（三态枚举）：cover=铺满（占满整屏、裁切溢出，默认）、
    -- contain=适配（整图完整可见，适合地图/示意图）、stretch=拉伸填满
    -- （按当前屏幕长宽比改变图片比例，刚好填满整屏、可能使内容变形）。
    -- 抽屉态恒为 contain，本字段仅在全屏有意义。默认值取用户持久化的
    -- 默认态（长按导航栏填充按钮可设），未设则 cover（沿用原默认行为）。
    self._fullscreen_fill = G_reader_settings:readSetting("artgallery_default_fill") or "cover"
    -- 已自动选向的图片序号：每图仅在首次构建 widget 时自动选一次朝向，
    -- 用户手动旋转后由 _setRotation 记住，不再被自动选向覆盖。
    self._auto_rotated_for = nil
    -- 智能选向失败（图片尺寸未就绪）的序号集合：避免每次 update 重复尝试。
    self._smart_failed_for = {}
    -- 缩略图缓存键的插入顺序（FIFO 淘汰，限制常驻内存）。
    self._thumb_keys = {}
    ImageViewer.init(self)
    self:_buildMoreButton()
    self:update()
end

-- ⤢ 一键全屏：在抽屉态（panel_ratio = 505/630）与全屏态（panel_ratio = 1.0）
-- 之间切换。布局完全复用既有逻辑（update() 会按 panel_ratio 重算面板宽度
-- 与图片适配区），故全屏态天然继承 ImageViewer 的缩放/平移/旋转。
function ArtGalleryViewer:_toggleFullscreen()
    if self._gallery_mode then return end       -- 图库态无意义
    self._fullscreen = not self._fullscreen
    -- 进入全屏即沉浸式隐藏覆盖层（功能按钮/页码圆点/左上标题 caption），
    -- 退出全屏恢复显示
    self._chrome_hidden = self._fullscreen
    -- 进入全屏时套用用户默认填充模式（长按导航栏填充按钮设定的默认值），
    -- 退出全屏无意义（抽屉态恒 contain），故仅进入时重置。
    if self._fullscreen then
        self._fullscreen_fill = G_reader_settings:readSetting("artgallery_default_fill") or "cover"
    end
    -- 切换前若处于放大态，先回到适配，避免全屏后图片移位/溢出
    if self.scale_factor and self.scale_factor ~= 0 then
        self.scale_factor = 0
        self._center_x_ratio, self._center_y_ratio = 0.5, 0.5
    end
    -- 清掉旧的 fit 基准（缩放下限/预渲染解析值），使其按新基准（_fullscreen）
    -- 重新计算：全屏=contain + 黑底铺满、抽屉=contain 白卡（见 update() 底色
    -- 调换与 _computeFitScaleFactor 的封顶差异）。
    self._fit_scale_factor = nil
    self._scale_factor_0 = nil
    self.panel_ratio = self._fullscreen and self.panel_ratio_full or (505 / 630)
    self:update()
end

-- 全屏沉浸式覆盖层显隐：隐藏后只留图片本身（功能按钮 / 页码圆点 / 左上标题
-- caption 全部不绘制），便于漫画连读。仅对全屏态有意义；抽屉态恒为显示。
-- 任何变更都重建覆盖层（update），并清掉挂起的「延迟隐藏」定时器，避免关查看器
-- 后误触发。
function ArtGalleryViewer:_setChrome(hidden)
    if self._chrome_hide_action then
        UIManager:unschedule(self._chrome_hide_action)
        self._chrome_hide_action = nil
    end
    if self._chrome_hidden == hidden then return end
    self._chrome_hidden = hidden
    self:update()
end

-- 底部感应区（屏幕底缘一条带）：用于「点底部恢复覆盖层」。坐标取屏幕坐标系
-- （与 ges.pos、_inTopMenuZone 一致）。仅全屏态使用。
function ArtGalleryViewer:_inBottomZone(pos)
    local zh = Screen:scaleBySize(56)
    local sh = Screen:getHeight()
    return pos.y >= sh - zh
end

-- 全屏填充模式的中文标签（导航栏按钮 / 菜单项 / 提示复用）。
function ArtGalleryViewer:_fillLabel(mode)
    if mode == "contain" then return _("适配") end
    if mode == "stretch" then return _("拉伸") end
    return _("铺满")  -- cover
end

-- 设置全屏填充模式（「右 ⋯」菜单三态项入口；拉伸首选用弹一次性变形确认）。
-- stretch 首次选用弹出一次性确认（说明会变形），确认后持久化为"已告知"，
-- 之后不再弹；取消则保持原模式不变。
function ArtGalleryViewer:_setFullscreenFill(mode)
    if mode == self._fullscreen_fill then return end
    if mode == "stretch" and not G_reader_settings:isTrue("artgallery_stretch_warned") then
        UIManager:show(ConfirmBox:new{
            text = _("“拉伸”会按当前屏幕长宽比改变图片比例以刚好填满整屏，"
                .. "可能使内容变形（超高/超宽图不再裁切或留边，但比例不再保持原样）。"
                .. "是否继续？"),
            ok_text = _("继续"),
            cancel_text = _("取消"),
            ok_callback = function()
                -- 一次性确认：标记后不再弹出
                G_reader_settings:makeTrue("artgallery_stretch_warned")
                self:_applyFullscreenFill("stretch")
            end,
        })
        return
    end
    self:_applyFullscreenFill(mode)
end

-- 真正落地填充模式切换：重置缩放态与 fit 基准后重建。
function ArtGalleryViewer:_applyFullscreenFill(mode)
    self._fullscreen_fill = mode
    -- 拉伸态缩放已放开（双击 / 双指手势可进缩放，缩放下限为 cover 均匀铺满）；
    -- 切换填充模式时若处于放大态，先回到适配，避免错位
    if self.scale_factor and self.scale_factor ~= 0 then
        self.scale_factor = 0
        self._center_x_ratio, self._center_y_ratio = 0.5, 0.5
    end
    self._fit_scale_factor = nil
    self._scale_factor_0 = nil
    self:update()
end

-- 长按导航栏 / 菜单的填充选项：将其设为默认全屏看图模式（持久化，下次进入
-- 全屏自动套用）。
function ArtGalleryViewer:_setDefaultFill(mode)
    G_reader_settings:saveSetting("artgallery_default_fill", mode)
    UIManager:show(InfoMessage:new{
        text = _("已将“" .. self:_fillLabel(mode) .. "”设为默认全屏看图模式"),
        timeout = 2,
    })
end

-- Upstream ImageViewer:onShow() unconditionally queues its OWN "full"
-- flashing refresh of the whole widget — UIManager:show() fires the
-- Show event (which reaches this) immediately after enqueuing whatever
-- refresh WE explicitly asked for, so every open queued both: our
-- careful "ui" refresh (see showViewer) AND upstream's forced "full"
-- one, and the queue promotes the merged region to the more aggressive
-- "full" — flashing on every single open regardless of what we asked
-- for (2026-07-21, reported worst in Night Mode). No-op this instead;
-- showViewer already enqueues the one refresh we actually want.
function ArtGalleryViewer:onShow()
    return true
end

function ArtGalleryViewer:_prefFor(i)
    local meta = self.image_metas and self.image_metas[i]
    if meta and self.get_pref then
        return self.get_pref(meta) or {}
    end
    return {}
end

-- Forked from ImageViewer:update() (verified against current upstream):
-- same lifecycle, but the widget is a left-anchored drawer sized from
-- panel_ratio, and the dot pill and ⋯ button are OVERLAID on the image
-- instead of stacked below it.
function ArtGalleryViewer:update()
    self:_clean_image_wg()
    local orig_dimen = self.main_frame.dimen
    -- 丢弃 main_frame 被 paint 缓存的旧尺寸：FrameContainer:paintTo 只在首次
    -- paint 时按当前子节点算出 w/h 存进 self.dimen，之后每次 paint 只更新
    -- x/y、不重算 w/h（见 frontend/ui/widget/container/framecontainer.lua:104）。
    -- 抽屉⇄全屏切换会改变面板宽度并重排子节点，若不清除，main_frame.dimen
    -- 会停在旧宽度，导致：(a) 末尾 setDirty 的刷新区(self.main_frame.dimen:
    -- combine(orig_dimen))只覆盖旧抽屉区域，全屏时右列书页在墨水屏残留；
    -- (b) 图片以 cover 溢出后只露出左半。置 nil 让下次 paintTo 按新子节点
    -- 重算正确尺寸，刷新区随即覆盖整屏、书页被真正遮蔽。
    self.main_frame.dimen = nil

    self._panel_w = math.floor(Screen:getWidth() * self.panel_ratio)
    self._panel_h = Screen:getHeight() - 2 * self.panel_vgap
    -- content area inside the drawer's border (top/right/bottom only — the
    -- left edge is borderless and flush with the screen); self.width/height
    -- are what the inherited zoom/pan code sizes the image against
    self.width = self._panel_w - self.panel_border
    self.height = self._panel_h - 2 * self.panel_border

    while table.remove(self.frame_elements) do end
    self.frame_elements:resetLayout()

    self.img_container_h = self.height
    if self._gallery_mode then
        self:_buildGallery()
    else
        self._gallery_cells = nil
        self:_new_image_wg()
    end
    self:_buildPill()

    -- Explicit day-white backing behind the image area. KOReader's night mode
    -- inverts the framebuffer when compositing, so this shows black in dark
    -- mode (issue #9) rather than leaving a light gap around the image; in day
    -- mode it just matches the white card. Logical/day polarity, flag 0.
    local image_layer = FrameContainer:new{
        -- 全屏态用黑色底：contain 适配的留白在墨水屏上隐形，图片视觉铺满整屏
        -- （借鉴 Illustrations 的全屏做法）；抽屉态保持白色卡片观感。
        background = self._fullscreen and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        self.image_container,
    }
    local overlay = OverlapGroup:new{
        dimen = Geom:new{ w = self.width, h = self.height },
        image_layer,
    }
    -- chrome is centered/aligned on the image area (content minus the gap
    -- that keeps it clear of the rounded right edge), like the design
    local image_area_w = self.width - self.image_right_gap
    -- 14, not 16: the bottom row sits 2px closer to the drawer's bottom
    -- edge than before (the buttons also grew 2px, see ArtGalleryMoreButton)
    local btn_inset = Screen:scaleBySize(14)
    local btn_gap = Screen:scaleBySize(10)
    -- optional prev/next buttons: always shown while the toggle is on
    -- (zoomed too — switching lands the next image at fit); at the ends
    -- of the list the dead-end button stays visible but grayed out, so
    -- the layout never jumps. Next sits at the right edge; ⋯ moves left
    -- of it whenever the buttons are enabled.
    if self._nav_prev_frame then self._nav_prev_frame:free() end
    if self._nav_next_frame then self._nav_next_frame:free() end
    self._nav_prev_frame, self._nav_next_frame = nil, nil
    local nav = G_reader_settings:isTrue(NAV_BUTTONS_KEY)
        and self._images_list and (self._images_list_nb or 1) > 1
    local cur = self._images_list_cur or 1
    local nb = self._images_list_nb or 1
    if self._gallery_mode then
        -- gallery: the arrows page the grid and are its primary
        -- affordance, so they show regardless of the setting (hidden
        -- when everything fits on one page)
        nav = self:_galleryPages() > 1
        cur = self._gallery_page or 1
        nb = self:_galleryPages()
    end
    if self._close_frame then
        self._close_frame:free()
        self._close_frame = nil
    end
    if nav and not (self._fullscreen and self._chrome_hidden) then
        self._nav_prev_frame = ArtGalleryMoreButton:new{
            icon = _PLUGIN_DIR .. "/assets/prev.svg",
            disabled = cur <= 1 or nil,
        }
        self._nav_prev_frame.overlap_offset = {
            Screen:scaleBySize(16),
            self.height - self._nav_prev_frame.size - btn_inset,
        }
        table.insert(overlay, self._nav_prev_frame)
        self._nav_next_frame = ArtGalleryMoreButton:new{
            icon = _PLUGIN_DIR .. "/assets/next.svg",
            disabled = cur >= nb or nil,
        }
        self._nav_next_frame.overlap_offset = {
            image_area_w - self._nav_next_frame.size,
            self.height - self._nav_next_frame.size - btn_inset,
        }
        table.insert(overlay, self._nav_next_frame)
    end
    -- ⤢ 全屏切换按钮（仅单图模式）：置于底栏左侧，导航键开启时紧邻 Prev 右侧，
    -- 关闭时贴左下角。图标随状态在「展开/收起」间切换。
    if self._fs_frame then self._fs_frame:free(); self._fs_frame = nil end
    if not self._gallery_mode and not (self._fullscreen and self._chrome_hidden) then
        self._fs_frame = ArtGalleryMoreButton:new{
            icon = _PLUGIN_DIR .. (self._fullscreen
                and "/assets/fullscreen_exit.svg" or "/assets/fullscreen.svg"),
        }
        local fs_x = Screen:scaleBySize(16)
        if self._nav_prev_frame and self._nav_prev_frame.overlap_offset then
            fs_x = self._nav_prev_frame.overlap_offset[1]
                + self._nav_prev_frame.size + btn_gap
        end
        self._fs_frame.overlap_offset = {
            fs_x, self.height - self._fs_frame.size - btn_inset,
        }
        table.insert(overlay, self._fs_frame)
    end
    -- 全屏填充模式三态（铺满 / 适配 / 拉伸）已收纳进「右 ⋯」菜单（见 _getQuickActionItems），
    -- 不在导航栏单独绘制按钮簇；长按菜单项即可设为默认全屏看图模式。
    -- ⋯ (single-image) / Back (gallery) both live at the BOTTOM row, just
    -- left of the next/page-forward button (or in that same slot when
    -- nav buttons are off) — kept out of the top strip entirely so it
    -- never competes with KOReader's own top-of-screen menu gesture.
    if self._gallery_mode then
        self._close_frame = ArtGalleryTextButton:new{
            text = _("返回"),
            bold = true,
            icon = _PLUGIN_DIR .. "/assets/back.svg",
        }
        local size = self._close_frame:getSize()
        local x = self._nav_next_frame
            and (self._nav_next_frame.overlap_offset[1] - btn_gap - size.w)
            or (image_area_w - size.w)
        self._close_frame.overlap_offset = {
            x,
            self.height - size.h - btn_inset,
        }
        table.insert(overlay, self._close_frame)
    elseif self._more_frame and self:_hasQuickActions()
        and not (self._fullscreen and self._chrome_hidden) then
        local more_size = self._more_frame:getSize()
        local more_x, more_y
        if self._nav_next_frame then
            -- nav on: ⋯ stacks directly ABOVE Next (same right edge), with
            -- the same gap it used to keep to Next's left now below it
            more_x = self._nav_next_frame.overlap_offset[1]
            more_y = self._nav_next_frame.overlap_offset[2] - btn_gap - more_size.h
        else
            -- nav off: ⋯ takes the bottom-right slot Next would have used
            more_x = image_area_w - more_size.w
            more_y = self.height - more_size.h - btn_inset
        end
        self._more_frame.overlap_offset = { more_x, more_y }
        table.insert(overlay, self._more_frame)
    elseif self._more_frame then
        -- every Quick Action turned off: hide the ⋯ button entirely. Clear
        -- its geometry so the pill reclaims the space (the right-bound loop
        -- skips a nil overlap_offset) and a tap where it used to be can't hit
        -- a stale dimen (see onTap).
        self._more_frame.overlap_offset = nil
        self._more_frame.dimen = nil
    end
    if self._pill_frame and not (self._fullscreen and self._chrome_hidden) then
        -- the revert button and the gallery Shown/Ignored toggle are the
        -- same height as the ⋯ button, so share its bottom inset to sit on
        -- the same baseline; the shorter dots pill uses a larger inset so
        -- its centre still lines up
        local bottom_inset = (self:_isOverFit() or self._gallery_mode)
            and btn_inset or Screen:scaleBySize(25)
        -- span between whatever sits on its left (the Prev button, or the
        -- left inset) and the nearest right-side chrome (⋯ / Back / Next)
        local left_bound = Screen:scaleBySize(16)
        if self._nav_prev_frame and self._nav_prev_frame.overlap_offset then
            left_bound = self._nav_prev_frame.overlap_offset[1]
                + self._nav_prev_frame.size
        end
        -- 全屏按钮（贴左）也要让出空间，避免与底栏圆点重叠
        if self._fs_frame and self._fs_frame.overlap_offset then
            left_bound = math.max(left_bound,
                self._fs_frame.overlap_offset[1] + self._fs_frame.size)
        end
        local right_bound = image_area_w
        for _, f in ipairs({ self._more_frame, self._close_frame,
                self._nav_next_frame }) do
            if f and f.overlap_offset then
                right_bound = math.min(right_bound, f.overlap_offset[1])
            end
        end
        -- the gallery Shown/Ignored toggle STRETCHES to fill the bottom bar;
        -- the dot pill just centres within the span
        if self._gallery_mode and self._pill_frame.setWidth then
            -- keep a gap from the Prev arrow when it's there, but go flush to
            -- the left content margin when it isn't (single-page galleries have
            -- no arrows, so the toggle should reach the same margin the arrow
            -- would occupy — not leave a phantom gap where it used to be)
            local pill_left = self._nav_prev_frame
                and (left_bound + btn_gap) or left_bound
            local pill_right = right_bound - btn_gap
            self._pill_frame:setWidth(pill_right - pill_left)
            self._pill_frame.overlap_offset = {
                pill_left, self.height - self._pill_frame:getSize().h - bottom_inset,
            }
        else
            local pill_size = self._pill_frame:getSize()
            self._pill_frame.overlap_offset = {
                math.floor(left_bound + (right_bound - left_bound - pill_size.w) / 2),
                self.height - pill_size.h - bottom_inset,
            }
        end
        table.insert(overlay, self._pill_frame)
    end
    -- caption overlay, top-left on the image (toggleable, on by default)
    if self._caption_wg then
        self._caption_wg:free()
        self._caption_wg = nil
    end
    if G_reader_settings:nilOrTrue(CAPTIONS_KEY) and not self._gallery_mode
        and not (self._fullscreen and self._chrome_hidden) then
        local meta = self.image_metas
            and self.image_metas[self._images_list_cur or 1]
        local caption = meta and meta.caption
        if caption and caption ~= "" then
            self._caption_wg = ArtGalleryCaption:new{
                text = caption,
                max_width = image_area_w - 2 * Screen:scaleBySize(16),
            }
            -- flush into the drawer's top-left corner: the tab's own three
            -- square corners sit in the screen corner, only its bottom-right
            -- is rounded (see ArtGalleryCaption)
            self._caption_wg.overlap_offset = { 0, 0 }
            table.insert(overlay, self._caption_wg)
        end
    end
    table.insert(self.frame_elements, overlay)
    self.frame_elements:resetLayout()

    -- main_frame is a transparent full-height column at the left screen
    -- edge; the drawer body (white, black border, rounded right corners)
    -- and its gradient shadow are painted by the _paintPanel hook, since
    -- FrameContainer supports neither per-corner radii nor translucency.
    self.main_frame.background = nil
    self.main_frame.radius = nil
    self.main_frame.bordersize = 0
    self.main_frame.padding = 0
    self.main_frame.padding_left = 0
    self.main_frame.padding_right = self.panel_border
    self.main_frame.padding_top = self.panel_vgap + self.panel_border
    self.main_frame.padding_bottom = self.panel_vgap + self.panel_border
    if not self._panel_paint_hooked then
        self._panel_paint_hooked = true
        local orig_paintTo = self.main_frame.paintTo
        local viewer = self
        self.main_frame.paintTo = function(frame, bb, x, y)
            viewer:_paintPanel(bb, x, y)
            orig_paintTo(frame, bb, x, y)
            viewer:_restoreCorners(bb, x, y)
        end
        -- anchor the drawer to the left edge instead of centering
        self[1].align = nil
    end

    -- Refresh policy (e-ink speed): the gradient shadow right of the panel
    -- only changes on open/close — and those paths refresh the full band
    -- themselves (showViewer/onCloseWidget) — so updates only refresh the
    -- drawer itself. Zoom/pan steps additionally skip dithering: dithered
    -- refreshes are slow and mid-gesture frames don't need the quality;
    -- stable content (open, image switch, back-to-fit) stays dithered.
    local wfm_mode = Device:hasKaleidoWfm() and "partial" or "ui"
    local fast = self._fast_refresh
    self._fast_refresh = nil
    -- Image switch: hard-clear this (panel-only) region so the previous
    -- image's ink doesn't ghost through the new one. The plain "ui"/"partial"
    -- waveforms skip the black→white→black clear cycle, so the old image
    -- lingers. We use "full" (not "flashui") on purpose: on Kobo "flashui"
    -- resolves to the AUTO waveform (the driver picks a light/fast flash that
    -- leaves residue, worst on the big fills — the black Night-Mode card),
    -- whereas "full" is true GC16, the full 16-level clearing waveform, and
    -- is the mode the EPDC waits to *settle* between consecutive updates so
    -- rapid switches don't accumulate ghosts. It stays region-limited (a Geom
    -- is always passed below), so only the drawer clears, never the whole
    -- screen; zoom/pan steps (fast) stay flashless. Consumed before the
    -- suppress return so an open-time switch never leaves the flag dangling.
    local flash_switch = self._flash_switch
    self._flash_switch = nil
    if flash_switch and not fast then wfm_mode = "full" end
    self.dithered = not fast
    if self._suppress_refresh then
        -- showViewer builds the full initial state (remembered image,
        -- restored zoom) before showing, then refreshes once
        return
    end
    -- Interior update: neither the shadow nor the page below changes, so
    -- skip both the below-repaint (the numeric alpha makes setDirty flag
    -- every window under us dirty — repainting the whole book page for a
    -- zoom step) and the shadow re-blend (blending over its own previous
    -- output would accumulate darkness). The two must always travel
    -- together: whenever the shadow DOES re-blend, the page below must
    -- have been repainted first.
    self._skip_shadow_paint = true
    local alpha = self.alpha
    -- false, not nil: alpha is a CLASS field, and nil'ing the instance
    -- slot would just fall back to the class default via the metatable
    self.alpha = false
    UIManager:setDirty(self, function()
        -- Guard a teardown race: a swipe's refresh is deferred to the next
        -- paint tick, so an immediate close can clear main_frame.dimen before
        -- this runs. Nil mode makes UIManager drop the (now meaningless)
        -- refresh instead of indexing a nil dimen.
        if not self.main_frame.dimen then return end
        return wfm_mode, self.main_frame.dimen:combine(orig_dimen), not fast
    end)
    self.alpha = alpha
end

-- Paints the drawer at (x, y): first the dithered dot-pattern shadow
-- (pure black stipple fading rightwards, blended over the live page),
-- then the panel body from a cached stencil — opaque white with a
-- black border, anti-aliased rounded corners on the right side only,
-- transparent corner notches. Blending is safe against accumulation
-- because self.alpha makes UIManager repaint the windows below us
-- first (see the class comment).
function ArtGalleryViewer:_paintPanel(bb, x, y)
    local w, h = self._panel_w, self._panel_h
    local py = y + self.panel_vgap
    -- Night mode comes in two flavors:
    --   * HW invert (real e-ink panels mostly): the fb flag stays 0 and
    --     the panel inverts its output — paint the LOGICAL (day-polarity)
    --     colors and the hardware turns them into the night look.
    --   * SW invert (emulator, some devices): the fb's inverse flag is
    --     set, which makes every mismatched-flag blit fall back to the
    --     per-pixel Lua blitter (crushingly slow for our full-height
    --     stencils) AND write pre-inverted. So in that case paint the
    --     stencils with the final night colors raw and setInverse(1) on
    --     them: with matching flags the C blitter runs and copies them
    --     as-is — same pixels on screen, at C speed.
    -- Night design in both: black card, white hairline edge, dark shadow
    -- (stronger/wider than day so it reads on black).
    local night = Screen.night_mode
    local inv = bb.getInverse and bb:getInverse() == 1
    -- SW-invert night mode (Android/Boox): KOReader inverts the framebuffer
    -- when compositing our buffers onto it. Flag-matching our stencils to that
    -- inverse flag makes the C blitter copy them RAW, BYPASSING that inversion
    -- — which left the whole drawer white in dark mode (issue #9). So in that
    -- case DON'T flag-match: keep the stencils in logical/day polarity and let
    -- KOReader invert them exactly like it does every stock widget. On HW-
    -- invert panels the fb flag is already 0, so render_inv == inv == false and
    -- nothing changes there.
    local render_inv = inv
        and not (night and Device.isAndroid and Device:isAndroid())
    local skey = tostring(night) .. tostring(render_inv)
    -- Advanced → Disable shadow: skip the gradient entirely. The dithered
    -- shadow is the main e-ink ghost source, so some users prefer it off.
    local shadow_disabled = G_reader_settings:isTrue(SHADOW_KEY)
        or self._fullscreen   -- 全屏态面板铺满整屏，阴影无意义

    -- shadow: cached DOT-PATTERN stencil (ordered/Bayer dithering, not a
    -- true alpha gradient — see SHADOW_BAYER8 above), density peak → 0
    -- across shadow_width, starting shadow_overlap left of the panel edge
    -- (that part only shows through the rounded corner notches); full
    -- screen height.
    local shadow_h = h + 2 * self.panel_vgap
    -- logical shadow color is white in night (inverts to dark); with the
    -- SW-invert flag set we store the final dark value directly instead
    local sv = render_inv and 0x00 or (night and 0xFF or 0x00)
    local speak = night and 1.0 or 0.5
    -- night mode gets a wider gradient so it reaches further onto the page
    -- (user tuning 2026-07-22: 2x read as reaching too far, 1.25x as too
    -- narrow — splitting the difference)
    local swidth = night and math.floor(self.shadow_width * 1.5 + 0.5) or self.shadow_width
    if not shadow_disabled and (not self._shadow_bb
            or self._shadow_bb:getHeight() ~= shadow_h
            or self._shadow_night ~= skey) then
        if self._shadow_bb then self._shadow_bb:free() end
        self._shadow_night = skey
        self._shadow_bb = Blitbuffer.new(swidth, shadow_h,
            Blitbuffer.TYPE_BBRGB32)
        local function origFrac(tt)
            if night then
                -- night: hold most of the darkness through the left half
                -- (a strong contact band that reads as "above the page"),
                -- then fall off quadratically so the right half is much
                -- lighter than a straight ramp; continuous at t = 0.5
                return tt < 0.5 and (1 - 0.8 * tt)
                    or 0.6 * (1 - (tt - 0.5) * 2) ^ 2
            else
                return 1 - tt
            end
        end
        -- BOOSTED NEAR-EDGE ZONE (2026-07-22, corrected twice same day):
        -- the first `shadow_overlap` columns (t < vis0) are painted OVER
        -- by the panel body along every straight edge — only the small
        -- rounded-corner notches ever expose them — so a boost anchored
        -- to t=0 (1st attempt) was invisible for ~95% of the panel's
        -- height. Anchoring to vis0 instead (2nd attempt) fixed
        -- visibility but introduced a real seam: it jumped straight to
        -- `peak_level` AT vis0, discontinuous with whatever origFrac(t)
        -- was doing just below vis0 — invisible along a straight edge
        -- (the panel itself covers t < vis0 there) but the corner's
        -- notch exposes BOTH sides of that jump within one small curved
        -- area, so it read as a hard block breaking the curve instead of
        -- following it ("the dithering missed the rounding of the
        -- corner"). Fixed by boosting with a smooth bump added ON TOP OF
        -- the untouched curve — continuous everywhere, including t <
        -- vis0, so whatever the corner exposes always tapers smoothly,
        -- no matter how much of the buffer that turns out to be.
        local vis0 = self.shadow_overlap / swidth
        local peak_level = night and 1.0 or 0.62
        -- how far the boost tapers back to the plain curve on the VISIBLE
        -- (page) side of the panel edge
        local bump_width = 0.18
        for i = 0, swidth - 1 do
            local t = (i + 0.5) / swidth
            local orig_level = speak * origFrac(t)
            -- boost = a bump peaking at peak_level right at the panel edge
            -- (vis0). LEFT of the edge (t <= vis0) it stays FLAT at the peak:
            -- that region is hidden under the opaque panel along straight
            -- edges and only ever shows through the rounded-corner notches,
            -- where a solid dark band that runs back under the panel reads
            -- as the shadow continuing UNDER the overlay (the illusion the
            -- user wanted). RIGHT of the edge it tapers to the plain curve
            -- over bump_width via a raised cosine. Both pieces meet at vis0
            -- at exactly peak_level with slope ~0, so the whole curve is
            -- seamless — a discontinuity here is what broke the corner in
            -- v0.1.13 (the notch exposes both sides of the edge at once).
            local bump
            if t <= vis0 then
                bump = 1
            else
                local dist = (t - vis0) / bump_width
                bump = dist < 1 and 0.5 * (1 + math.cos(math.pi * dist)) or 0
            end
            -- desired LOCAL darkness at this column, 0..255 — compared
            -- against the tiled Bayer matrix per-pixel below rather than
            -- written as a per-pixel alpha, so the result is always fully
            -- opaque or fully transparent (a dot, or no dot)
            local level = (orig_level + bump * (peak_level - orig_level)) * 255
            local col = (i % 8) + 1
            for j = 0, shadow_h - 1 do
                local threshold = (SHADOW_BAYER8[col][(j % 8) + 1] + 0.5) * 4
                local a = level > threshold and 255 or 0
                self._shadow_bb:setPixel(i, j, Blitbuffer.ColorRGB32(sv, sv, sv, a))
            end
        end
        self._shadow_bb:setInverse(render_inv and 1 or 0)
    end
    -- consumed by interior updates (see update()): the page under the
    -- shadow wasn't repainted, so blending again would accumulate
    local skip_shadow = self._skip_shadow_paint
    self._skip_shadow_paint = nil
    if not skip_shadow and not shadow_disabled then
        bb:alphablitFrom(self._shadow_bb, x + w - self.shadow_overlap, y,
            0, 0, swidth, shadow_h)
    end

    -- Under-corner snapshots: the panel stencil's arc pixels carry
    -- partial alpha (anti-aliasing), so unlike the opaque body they are
    -- NOT idempotent to re-blend. On a full paint (below just painted,
    -- shadow just blended) save the pristine background under the two
    -- corner squares; on skip-paints restore it first, so every interior
    -- repaint blends the arcs over the same pixels instead of slowly
    -- eating the AA against the page.
    local cr = self.panel_radius
    local cpy = y + self.panel_vgap
    if not self._under_corner_bbs then
        self._under_corner_bbs = {
            Blitbuffer.new(cr, cr, Blitbuffer.TYPE_BBRGB32),
            Blitbuffer.new(cr, cr, Blitbuffer.TYPE_BBRGB32),
        }
    end
    local ucb = self._under_corner_bbs
    if skip_shadow then
        bb:blitFrom(ucb[1], x + w - cr, cpy, 0, 0, cr, cr)
        bb:blitFrom(ucb[2], x + w - cr, cpy + h - cr, 0, 0, cr, cr)
    else
        -- match the fb's inverse flag so these copies run on the C blitter
        ucb[1]:setInverse(render_inv and 1 or 0)
        ucb[2]:setInverse(render_inv and 1 or 0)
        ucb[1]:blitFrom(bb, 0, 0, x + w - cr, cpy, cr, cr)
        ucb[2]:blitFrom(bb, 0, 0, x + w - cr, cpy + h - cr, cr, cr)
    end

    if not self._panel_bb or self._panel_bb:getWidth() ~= w
            or self._panel_bb:getHeight() ~= h or self._panel_night ~= skey then
        if self._panel_bb then
            self._panel_bb:free()
        end
        self._panel_night = skey
        self._panel_bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
        -- Logical colors: white body, black edge — the night inversion
        -- (HW panel or SW flag) turns them into a black card with a white
        -- hairline edge. With the SW-invert flag set we store the final
        -- values raw instead (flag-matched below for the C blitter).
        -- NB: screen:shot()/getPixel un-invert reads, so night shots show
        -- LOGICAL values, not the displayed ones.
        local body = render_inv and 0x00 or 0xFF     -- card background
        local edge = render_inv and 0xFF or 0x00     -- border
        local c_body = Blitbuffer.ColorRGB32(body, body, body, 0xFF)
        local c_edge = Blitbuffer.ColorRGB32(edge, edge, edge, 0xFF)
        -- night edge is a hairline: thinner than the day border but at
        -- least 2px so it doesn't vanish on high-dpi devices; the layout
        -- keeps panel_border so the image doesn't shift
        local bw = night and math.max(2, Screen:scaleBySize(1))
            or self.panel_border
        local r = self.panel_radius
        -- border on top/right/bottom only: the left edge is flush with the
        -- screen edge and borderless
        self._panel_bb:paintRectRGB32(0, 0, w, h, c_body)
        self._panel_bb:paintRectRGB32(0, 0, w, bw, c_edge)
        self._panel_bb:paintRectRGB32(0, h - bw, w, bw, c_edge)
        self._panel_bb:paintRectRGB32(w - bw, 0, bw, h, c_edge)
        -- right corners: AA arcs — body inside, border ring, transparent
        -- outside (the page shows in the notches)
        for cy_top = 0, 1 do
            local ccx, ccy = w - r, cy_top == 0 and r or h - r
            for px = w - r, w - 1 do
                for qy = 0, r - 1 do
                    local pyy = cy_top == 0 and qy or h - 1 - qy
                    local fx, fy = px + 0.5, pyy + 0.5
                    if fx >= ccx and (cy_top == 0 and fy <= ccy or cy_top == 1 and fy >= ccy) then
                        local d = math.sqrt((fx - ccx) ^ 2 + (fy - ccy) ^ 2)
                        local cov = math.min(math.max(r - d + 0.5, 0), 1)
                        local t_in = math.min(math.max((r - bw) - d + 0.5, 0), 1)
                        local g = math.floor(edge + t_in * (body - edge) + 0.5)
                        self._panel_bb:setPixel(px, pyy,
                            Blitbuffer.ColorRGB32(g, g, g, math.floor(cov * 255 + 0.5)))
                    end
                end
            end
        end
        self._panel_bb:setInverse(render_inv and 1 or 0)
    end
    bb:alphablitFrom(self._panel_bb, x, py, 0, 0, w, h)
    self:_saveCorners(bb, x, py)
end

-- The image is allowed to reach the panel border, so a zoomed image would
-- paint square corners over the rounded right ones. Right after the panel
-- is painted (page in the notches, border arc, white interior), the two
-- corner squares are copied aside with per-pixel alpha = "outside the
-- interior" (notch + border ring + an image_padding-wide white ring
-- opaque, interior transparent), and re-blended on top after the children
-- have painted — the image's corners end up rounded, with the same white
-- gap against the border as along the straight edges.
function ArtGalleryViewer:_saveCorners(bb, x, py)
    local w, h = self._panel_w, self._panel_h
    local r, bw = self.panel_radius, self.panel_border
    if not self._corner_bbs then
        self._corner_bbs = {
            Blitbuffer.new(r, r, Blitbuffer.TYPE_BBRGB32),
            Blitbuffer.new(r, r, Blitbuffer.TYPE_BBRGB32),
        }
    end
    self._corner_bbs[1]:blitFrom(bb, 0, 0, x + w - r, py, r, r)
    self._corner_bbs[2]:blitFrom(bb, 0, 0, x + w - r, py + h - r, r, r)
    for k = 1, 2 do
        local cbb = self._corner_bbs[k]
        -- circle center in corner-local coords: (0, r) for the top-right
        -- corner square, (0, 0) for the bottom-right one
        local ccy = k == 1 and r or 0
        local keep_r = r - bw - self.image_padding
        for pyy = 0, r - 1 do
            for pxx = 0, r - 1 do
                local d = math.sqrt((pxx + 0.5) ^ 2 + (pyy + 0.5 - ccy) ^ 2)
                local t_in = math.min(math.max(keep_r - d + 0.5, 0), 1)
                if t_in > 0 then
                    local c = cbb:getPixel(pxx, pyy):getColorRGB32()
                    cbb:setPixel(pxx, pyy, Blitbuffer.ColorRGB32(
                        c.r, c.g, c.b, math.floor((1 - t_in) * 255 + 0.5)))
                end
            end
        end
    end
end

function ArtGalleryViewer:_restoreCorners(bb, x, y)
    if not self._corner_bbs then return end
    local w, h = self._panel_w, self._panel_h
    local py = y + self.panel_vgap
    local r = self.panel_radius
    bb:alphablitFrom(self._corner_bbs[1], x + w - r, py, 0, 0, r, r)
    bb:alphablitFrom(self._corner_bbs[2], x + w - r, py + h - r, 0, 0, r, r)
end

-- The G-sensor's SetRotationMode event is delivered to the topmost widget
-- only, so an open drawer would silently block auto-rotation. Do what
-- Menu does: close, let the reader re-layout, and reopen — zoom/pan
-- persistence makes the reopened drawer land where the user was.
function ArtGalleryViewer:onSetRotationMode(rotation)
    if rotation ~= nil and rotation ~= Screen:getRotationMode() then
        UIManager:close(self)
        if self.on_rotate then
            self.on_rotate(rotation)
        end
    end
    return true
end

function ArtGalleryViewer:onCloseWidget()
    -- 清掉可能挂起的「延迟隐藏」定时器，避免关闭查看器后误触发 _setChrome
    if self._chrome_hide_action then
        UIManager:unschedule(self._chrome_hide_action)
        self._chrome_hide_action = nil
    end
    if self._shadow_bb then
        self._shadow_bb:free()
        self._shadow_bb = nil
    end
    if self._panel_bb then
        self._panel_bb:free()
        self._panel_bb = nil
    end
    if self._corner_bbs then
        self._corner_bbs[1]:free()
        self._corner_bbs[2]:free()
        self._corner_bbs = nil
    end
    if self._under_corner_bbs then
        self._under_corner_bbs[1]:free()
        self._under_corner_bbs[2]:free()
        self._under_corner_bbs = nil
    end
    if self._more_frame then
        self._more_frame:free()
    end
    if self._nav_prev_frame then self._nav_prev_frame:free() end
    if self._nav_next_frame then self._nav_next_frame:free() end
    if self._fs_frame then self._fs_frame:free() end
    if self._close_frame then self._close_frame:free() end
    -- _pill_frame 仅在 _new_image_wg 被插入覆盖层时由 frame_elements 统一释放；
    -- 全屏沉浸式隐藏态下它不被插入，故此处显式释放，避免关查看器时泄漏。
    if self._pill_frame then self._pill_frame:free() end
    if self._gallery_head_wgs then
        for _, w in ipairs(self._gallery_head_wgs) do w:free() end
        self._gallery_head_wgs = nil
    end
    if self._gallery_badges then
        for _, b in ipairs(self._gallery_badges) do b:free() end
        self._gallery_badges = nil
    end
    if self._caption_wg then
        self._caption_wg:free()
        self._caption_wg = nil
    end
    if self._thumb_bbs then
        for _, t in pairs(self._thumb_bbs) do
            if t.bb then t.bb:free() end
        end
        self._thumb_bbs = nil
    end
    self:_resetHiRes() -- free the zoomed image's full-res decode, if any
    -- ImageViewer.onCloseWidget() does necessary cleanup (frees self.image,
    -- title_bar, button_container, etc.) but ALSO unconditionally queues
    -- its OWN "flashui" refresh of main_frame.dimen at the very end (see
    -- imageviewer.lua ~886-889) — the exact same pattern as the onShow()
    -- bug fixed earlier this session, just on the close side instead:
    -- "flashui" outranks our own "ui" request (refresh_modes: flashui=7 >
    -- ui=3, see uimanager.lua ~1060), so it silently wins whenever the two
    -- deferred refresh callbacks get merged, no matter what we ask for.
    -- Confirmed via a headless refresh-queue trace (2026-07-21): closing
    -- was NOT triggering KOReader's normal partial-refresh-count flash
    -- promotion (measured zero "partial" ticks across several open/close
    -- cycles) — it's this direct, unconditional "flashui" request, every
    -- single time. Pop the just-queued upstream callback off the refresh
    -- func stack before pushing our own, keeping the cleanup but dropping
    -- the forced flash.
    ImageViewer.onCloseWidget(self)
    table.remove(UIManager._refresh_func_stack)
    -- "ui" (non-flashing): the drawer covers most of the page, but KOReader's
    -- own menus close the same way and rely on the normal partial-refresh
    -- promotion cadence to mop up any ghosting, rather than forcing a flash
    -- on every single close — matches that convention instead of "full"
    -- (2026-07-21: was flashing here on every close, worst at night; if
    -- ghosting turns out to be visible on device, "flashui" is the next
    -- step up — see uimanager.lua's refreshtype docs).
    -- Dither hint (2026-07-21): the open refresh always passed one, this
    -- one never did — the gradient shadow being erased here banded into a
    -- handful of distinct grays without it (very visible in Day mode's
    -- black-on-light shadow; the same banding was there in Night mode too,
    -- just far less visible against an already-dark background).
    UIManager:setDirty(nil, function()
        -- Same teardown-race guard as update(): if the frame is already gone
        -- by the time this deferred callback runs, drop the refresh.
        if not self.main_frame.dimen then return end
        local d = self.main_frame.dimen:copy()
        -- cover the shadow at its widest (night mode = 2× shadow_width) — but
        -- only when the shadow is on. With it off, keep the region to the
        -- drawer so a promoted/flash refresh never reaches the book page.
        if not G_reader_settings:isTrue(SHADOW_KEY) then
            d.w = math.min(Screen:getWidth() - d.x,
                d.w + 2 * self.shadow_width - self.shadow_overlap + 1)
        end
        -- "full": a GC16 clearing refresh over the drawer (and its shadow)
        -- area on every close — the ghosting the drawer/shadow leaves on
        -- e-ink, worst at night, is scrubbed as it lifts away. This is the
        -- former "Full Refresh on Close" option, now baked in as the default
        -- (same reliable GC16 waveform the image-switch clear uses); it stays
        -- regional so the rest of the page is never flashed.
        return "full", d, true
    end)
    -- Refresh isolation (see showViewer): hand the reader back its own
    -- ghost-clear counter, on nextTick so the close's below-repaint runs while
    -- the count is still ArtGallery's (0) and can't flash from the reader's total.
    -- Reading then continues its cadence exactly where it left off.
    if self._reader_refresh_count ~= nil then
        local saved = self._reader_refresh_count
        self._reader_refresh_count = nil
        UIManager:nextTick(function() UIManager.refresh_count = saved end)
    end
end

-- Forked from ImageViewer:_new_image_wg(): constant image inset (no
-- title-bar/buttons dependence) and per-image 0/90/180/270 rotation.
function ArtGalleryViewer:_new_image_wg()
    -- 智能选向：本图首次构建 widget 时，若用户未手动旋转，自动转到能铺满
    -- 更多屏幕的朝向（_smartRotation），不裁切。仅自动套用一次；用户手动
    -- 旋转后由 _setRotation 记住，不再被覆盖。图片尺寸未就绪（懒解码尚未
    -- 完成）时留待下次构建再试。
    if self._images_list_cur and self._auto_rotated_for ~= self._images_list_cur
       and not self._smart_failed_for[self._images_list_cur] then
        local pref_rot = self:_prefFor(self._images_list_cur or 1).rotation
        if pref_rot ~= nil then
            self._auto_rotated_for = self._images_list_cur
        else
            local smart = self:_smartRotation()
            if smart then
                if smart ~= (self._cur_rotation or 0) then
                    self._cur_rotation = smart
                    self._fit_scale_factor = nil
                    self._scale_factor_0 = nil
                end
                self._auto_rotated_for = self._images_list_cur
            else
                -- 图片尺寸尚未就绪（如 SVG 懒解码前）：标记本图，避免每次
                -- update 重复调用 _smartRotation 做无用功。
                self._smart_failed_for[self._images_list_cur] = true
            end
        end
    end
    -- the image gets the whole content area (a zoomed image must reach the
    -- panel border on all sides); image_right_gap only aligns the chrome
    local avail_w = self.width
    local max_image_h = self.img_container_h - self.image_padding * 2
    local max_image_w = avail_w - self.image_padding * 2
    -- Logical fit mode (scale_factor 0) stays 0 for the viewer (dot pill,
    -- nav state, double-tap all key off it), but an image SMALLER than
    -- the content box renders at OUR capped fit (see
    -- _computeFitScaleFactor: up to 150% of native size, never more than
    -- what fits) instead of the widget's own best-fit, which would blow
    -- it up all the way to fill the box with no cap at all.
    local wg_scale = self.scale_factor
    local src = self.image
    -- 拉伸填满仅作用于全屏态：抽屉态（非全屏）恒为 contain，不允许非均匀
    -- 变形（见 _computeFitScaleFactor 的 _fullscreen 门控）。否则退出全屏或默认
    -- 态为 stretch 时，抽屉小图会被拉变形，违背"抽屉态恒为 contain"契约。
    if self._fullscreen and self._fullscreen_fill == "stretch" and self.scale_factor == 0 then
        -- 拉伸填满（仅 fit 态）：传 scale_factor=nil + width/height 到 ImageWidget，
        -- 走 scaleBlitBuffer(bb, w, h) 非均匀拉伸到精确容器尺寸（见 imagewidget.lua），
        -- 刚好填满整屏、改变长宽比。一旦进入缩放（scale_factor ~= 0），改走均匀数字
        -- 比例（下方 wg_scale==0 分支取 _computeFitScaleFactor 的 cover 下限），
        -- 避免已放大的图被继续非均匀拉伸变形（R1）。
        wg_scale = nil
    elseif wg_scale == 0 then
        local fit = self:_computeFitScaleFactor()
        if fit then
            -- 适配/铺满比例直接作为静止比例采用：这样「铺满」(cover) 对大于
            -- 屏幕的图也能生效（旧逻辑只在 fit>=1 时采用、否则交给 widget 自行
            -- contain，导致大图无法 cover 铺满）。viewer.scale_factor 仍为 0
            -- （适配态），仅 widget 的具体渲染比例取 fit。
            wg_scale = fit
        end
    elseif wg_scale > 1 then
        -- Zoomed past 1:1 of the capped bitmap: below this it's still
        -- downscaling the cap (sharp) and fast, but beyond it the cap would
        -- upscale, so swap in the sharp full-resolution decode (lazily
        -- created, see _getHiRes) — this is what makes approaching 100% show
        -- real detail. self.scale_factor stays expressed against the capped
        -- bitmap everywhere (fit floor, ceiling, save/restore all in those
        -- units); we only divide the WIDGET's scale by the resolution ratio
        -- here so the on-screen size is byte-identical — just crisper.
        local hi = self:_getHiRes()
        if hi then
            local r = hi:getWidth() / self.image:getWidth()
            if r > 1 then
                src = hi
                wg_scale = wg_scale / r
            end
        end
    end
    self._image_wg = ImageWidget:new{
        image = src,
        image_disposable = false, -- we may reuse self.image
        alpha = true,
        width = max_image_w,
        height = max_image_h,
        rotation_angle = self._cur_rotation or 0,
        scale_factor = wg_scale,
        center_x_ratio = self._center_x_ratio,
        center_y_ratio = self._center_y_ratio,
        -- We bake the night-mode inversion into the decoded bitmap ourselves
        -- (see the decode closure in showViewer), device-agnostically — the
        -- same pixel operation ImageWidget itself would do — so opt out of
        -- its own night handling to avoid inverting twice. (Its invertRect
        -- also spans the full widget rect, which would flip the letterbox
        -- around the image.) We deliberately do NOT flag-match the bitmap to
        -- the framebuffer's night flag: matching it once tied our night
        -- correctness to a getInverse() read that could disagree between
        -- decode and paint, which flipped the image on some devices — the
        -- "Invert in Night Mode reversed" bug. A plain flag-0 blit is the
        -- same path KOReader uses for every image, correct on HW- and
        -- SW-invert alike (only marginally slower on the rare SW-invert
        -- device, which re-inverts during the blit).
        original_in_nightmode = false,
    }
    self.image_container = CenterContainer:new{
        dimen = Geom:new{ w = avail_w, h = self.img_container_h },
        self._image_wg,
    }
end

-- Full-resolution decode of the current image, for the zoomed view. Decoded
-- lazily on first zoom-in and cached for as long as this image is on screen
-- (dropped by _resetHiRes on image change / invert / rotate). Returns nil —
-- and remembers that with a `false` sentinel so it isn't retried — when there
-- is no sharper version to be had (small images the resting cap never shrank).
function ArtGalleryViewer:_getHiRes()
    if not self.hires_decode then return nil end
    if self._hi_bb == false then return nil end
    if self._hi_bb then return self._hi_bb end
    local hi = self.hires_decode(self._images_list_cur or 1)
    if not hi then self._hi_bb = false; return nil end
    -- only worth the extra bitmap if it's meaningfully larger than the cap
    if self.image and hi:getWidth() <= self.image:getWidth() * 1.05 then
        if hi.free then hi:free() end
        self._hi_bb = false
        return nil
    end
    self._hi_bb = hi
    return hi
end

-- Drop any cached full-res decode. Call whenever self.image is replaced or
-- re-rendered (image switch, hide, invert toggle, rotation) so the next
-- zoom-in re-decodes against the current pixels.
function ArtGalleryViewer:_resetHiRes()
    if self._hi_bb and self._hi_bb ~= false and self._hi_bb.free then
        self._hi_bb:free()
    end
    self._hi_bb = nil
end

-- Pill: as many dots as fit between the chrome buttons, "n / N" beyond. Rebuilt on
-- every update (position/count/text all change together).
function ArtGalleryViewer:_buildPill()
    if self._pill_frame then
        self._pill_frame:free()
        self._pill_frame = nil
    end
    self._pill_dots = nil -- only set back below when dots are actually built
    if self._gallery_mode then
        -- Gallery bottom-center is the Shown/Ignored switch (only when there
        -- IS an ignored pool). "Page X of Y" now lives top-left in the grid.
        -- The button names the destination: from the collection it offers
        -- "Show Ignored (n)", from the Ignored pool "Show Gallery (n)".
        if self:_hasIgnoredTab() then
            local label
            if self._gallery_tab == "ignored" then
                local shown_n = self.shown_metas and #self.shown_metas or 0
                label = T(_("显示图库 (%1)"), shown_n)
            else
                label = T(_("显示忽略的 (%1)"), self:_ignoredCount())
            end
            self._pill_frame = ArtGalleryTextButton:new{ text = label, bold = true }
        end
        return
    end
    if self:_isOverFit() then
        -- genuinely spilling past fit: image switching is disabled, and
        -- the indicator becomes a tappable "reset to fit" button, styled
        -- to match the ⋯ button (see onTap)
        self._pill_frame = ArtGalleryTextButton:new{
            text = _("重置"),
            bold = true,
            icon = _PLUGIN_DIR .. "/assets/zoom.svg",
        }
        return
    end
    if not (self._images_list and self._images_list_nb > 1) then return end
    local nb = self._images_list_nb
    -- Fit as many dots as the space between the chrome buttons allows,
    -- compressing the pitch down toward the dots' own diameter before
    -- giving up. Only when even that won't fit do we fall back to "n / N".
    local dot_r = ArtGalleryDots.dot_r
    local natural_pitch = ArtGalleryDots.pitch
    local min_pitch = 2 * dot_r + Screen:scaleBySize(2)
    local budget = self:_pillAvailWidth() - 2 * ArtGalleryPill.padding_h
    local pitch = natural_pitch
    if nb > 1 then
        -- pitch that would exactly fill the budget; keep small counts
        -- compact by never exceeding the natural pitch
        pitch = math.min(natural_pitch, (budget - 2 * dot_r) / (nb - 1))
    end
    if pitch >= min_pitch then
        local inner = ArtGalleryDots:new{
            nb = nb,
            cur = self._images_list_cur or 1,
            pitch = math.floor(pitch),
        }
        self._pill_dots = inner
        self._pill_frame = ArtGalleryPill:new{ inner = inner }
    else
        -- truly too many to fit even compressed: "n / N" counter, INVERTED
        -- (light pill + dark text). As a solid black block with white text
        -- it drew far more attention than the dots pill it stands in for.
        self._pill_frame = ArtGalleryPill:new{
            inverted = true,
            inner = TextWidget:new{
                text = string.format("%d / %d", self._images_list_cur or 1, nb),
                face = Font:getFace("cfont", 12),
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
        }
    end
end

-- Horizontal room the dot pill has between the bottom-row chrome buttons:
-- from the Prev button's right edge (or the left inset when nav buttons
-- are off) to the ⋯/more button's left edge, less a gap on each side.
-- Mirrors the button geometry in update() so it can run before layout.
function ArtGalleryViewer:_pillAvailWidth()
    local image_area_w = self.width - self.image_right_gap
    local btn_inset = Screen:scaleBySize(16)
    local btn_gap = Screen:scaleBySize(10)
    local btn_size = ArtGalleryMoreButton.size
    local nav = G_reader_settings:isTrue(NAV_BUTTONS_KEY)
        and self._images_list and (self._images_list_nb or 1) > 1
    local more_left
    if nav then
        more_left = image_area_w - 2 * btn_size - btn_gap
    elseif self:_hasQuickActions() then
        more_left = image_area_w - btn_size
    else
        -- ⋯ hidden (no Quick Actions) and no Next: the pill gets the full width
        more_left = image_area_w
    end
    local left_bound = nav and (btn_inset + btn_size) or btn_inset
    return more_left - left_bound - 2 * btn_gap
end

function ArtGalleryViewer:_buildMoreButton()
    self._more_frame = ArtGalleryMoreButton:new{}
end

-- ── gallery (⋯ → Gallery): a paged masonry grid in the drawer ───────────────
-- Same window, same chrome: the grid replaces the image area, the pill
-- shows "Page X of Y", the ‹ › buttons page (always shown here — they
-- are the pagination affordance — hidden on a single page), swipes and
-- physical page keys page too. Tapping a thumbnail leaves the gallery
-- and opens that image in the normal viewer. Thumbnails are laid out
-- Pinterest-style: fixed-width columns, each image at its own aspect
-- ratio, placed into the currently shortest column — a page is full
-- when the next image doesn't fit any column.

-- The list/metas/count for the active Gallery tab (shown vs ignored). The
-- single-image view always uses _images_list/image_metas (= the primary pool).
function ArtGalleryViewer:_tabList()
    if self._gallery_tab == "ignored" then
        return self.ignored_list, self.ignored_metas,
            self.ignored_metas and #self.ignored_metas or 0
    end
    return self.shown_list, self.shown_metas,
        self.shown_metas and #self.shown_metas or 0
end

function ArtGalleryViewer:_ignoredCount()
    return self.ignored_metas and #self.ignored_metas or 0
end

-- The Ignored tab (and hence the whole tab bar) only appears when there is
-- something ignored — otherwise the Gallery looks exactly as it did before.
function ArtGalleryViewer:_hasIgnoredTab()
    return self:_ignoredCount() > 0
end

function ArtGalleryViewer:_switchGalleryTab(tab)
    if tab == self._gallery_tab then return end
    self._gallery_tab = tab
    self._gallery_page = 1
    self:update()
end

function ArtGalleryViewer:_enterGallery(page, tab)
    self._gallery_mode = true
    self._gallery_tab = tab or self.primary_tab or "shown"
    local layout = self:_galleryLayout()
    if page then
        self._gallery_page = math.min(math.max(page, 1), #layout.pages)
    else
        self._gallery_page = layout.page_of[self._images_list_cur or 1] or 1
    end
    -- the gallery browses from the fit state; a zoomed view has been
    -- left behind anyway once the user goes looking for another image
    self.scale_factor = 0
    self._center_x_ratio, self._center_y_ratio = 0.5, 0.5
    self:update()
end

function ArtGalleryViewer:_exitGallery(idx)
    self._gallery_mode = false
    if idx and idx ~= (self._images_list_cur or 1) then
        self:switchToImageNum(idx) -- runs update()
    else
        self:update()
    end
end

function ArtGalleryViewer:_galleryPages()
    return #self:_galleryLayout().pages
end

-- Drawer-content origin: gallery cell/tab rects are recorded relative to it.
function ArtGalleryViewer:_contentOrigin()
    local mf = self.main_frame.dimen
    return mf.x, mf.y + self.panel_vgap + self.panel_border
end

-- The gallery cell {x,y,w,h,idx} at pos (drawer-content space), or nil.
function ArtGalleryViewer:_galleryHit(pos)
    if not self._gallery_cells then return nil end
    local ox, oy = self:_contentOrigin()
    for _, c in ipairs(self._gallery_cells) do
        if pos:intersectWith(Geom:new{
            x = ox + c.x, y = oy + c.y, w = c.w, h = c.h }) then
            return c
        end
    end
    return nil
end

-- Long-press popup: a single action anchored just above the thumbnail —
-- "Ignore this image" in the Gallery, "Add back to Gallery" in the
-- Ignored pile. Kept in its own method so the gettext `_` isn't shadowed by
-- the `_` first parameter of onHold/onTap (calling `_()` in those crashes).
function ArtGalleryViewer:_openMoveMenu(cell, pos)
    local metas = select(2, self:_tabList())
    local meta = metas and metas[cell.idx]
    if not meta then return end
    local ignored = self._gallery_tab == "ignored"
    local label, cb
    if ignored then
        label = _("添加回图库")
        cb = function()
            if self.on_unignore then
                self.on_unignore(meta, "ignored", self._gallery_page)
            end
        end
    else
        label = _("忽略此图片")
        cb = function()
            if self.on_ignore then
                self.on_ignore(meta, "shown", self._gallery_page)
            end
        end
    end
    local menu
    menu = ArtGalleryPopupMenu:new{
        items = { { text = label, callback = cb } },
        -- compact: a single short action, so shrink the row from the ⋯ menu's
        row_h = Screen:scaleBySize(38),
        pad_left = Screen:scaleBySize(12),
        pad_right = Screen:scaleBySize(12),
        -- centred on the touch point, floating a little ABOVE it: the menu
        -- pops up so its bottom sits `lift` px clear of the finger (rises its
        -- full height upward from there), instead of resting right on the
        -- press. Still flips below when near the top of the screen.
        anchor = function()
            local w = menu.movable and menu.movable.dimen
                and menu.movable.dimen.w or 0
            local ox = self.main_frame.dimen.x
            local pad = Screen:scaleBySize(4)
            local lift = Screen:scaleBySize(14)
            local x = math.floor((pos and pos.x or 0) - w / 2)
            local maxx = ox + self.width - w - pad
            if maxx < ox + pad then maxx = ox + pad end
            x = math.max(ox + pad, math.min(x, maxx))
            local y = (pos and pos.y or 0) - lift
            return Geom:new{ x = x, y = y, w = 0, h = 0 }, false
        end,
    }
    UIManager:show(menu, function() return "ui", menu.movable.dimen end)
end

-- Masonry layout for ALL images, computed once per viewer (the image
-- list and drawer size are fixed while it is open) from the scanner's
-- header-sniffed dimensions — no decoding. Returns { pages = {
-- {cell,...}, ... }, page_of = {idx -> page} }; cell = {idx,x,y,w,h}
-- relative to the drawer content origin (the onTap hit-test space).
function ArtGalleryViewer:_galleryLayout()
    local tab = self._gallery_tab or "shown"
    self._gallery_layouts = self._gallery_layouts or {}
    if self._gallery_layouts[tab] then return self._gallery_layouts[tab] end
    local _, metas, nb = self:_tabList()
    local m = self:_galleryMetrics()
    local cols = self.gallery_cols
    local col_w = math.floor(
        (m.area_w - 2 * m.pad - (cols - 1) * m.gap) / cols)
    local thumb_w = col_w - 2 * m.inset
    local layout = { pages = {}, page_of = {} }
    local page, heights = {}, {}
    for c = 1, cols do heights[c] = 0 end
    local function flush()
        if #page > 0 then
            layout.pages[#layout.pages + 1] = page
            page = {}
            for c = 1, cols do heights[c] = 0 end
        end
    end
    for i = 1, nb or 1 do
        local meta = metas and metas[i]
        local iw = meta and (meta.width or meta.attr_width)
        local ih = meta and (meta.height or meta.attr_height)
        if not (iw and ih and iw > 0 and ih > 0) then iw, ih = 1, 1 end
        -- displayed height = native scaled to the column width, but NEVER
        -- upscaled (matches _thumb, which caps at 1×). Sizing the cell to
        -- thumb_w * aspect instead gives a small image (icon, tiny ad) a
        -- full-width cell it can't fill, floating it in white space and
        -- ballooning the column so pages flush half-empty.
        local scale = math.min(thumb_w / iw, 1)
        local th = math.floor(ih * scale + 0.5)
        -- clamp: never taller than a full column, never too small to tap
        th = math.min(th, m.grid_h - 2 * m.inset)
        th = math.max(th, Screen:scaleBySize(24))
        local cell_h = th + 2 * m.inset
        -- shortest column (leftmost on ties, so pages fill left to right)
        local best = 1
        for c = 2, cols do
            if heights[c] < heights[best] then best = c end
        end
        local y = heights[best] > 0 and heights[best] + m.gap or 0
        if y + cell_h > m.grid_h and #page > 0 then
            flush()
            best, y = 1, 0
        end
        page[#page + 1] = {
            idx = i,
            x = m.pad + (best - 1) * (col_w + m.gap),
            y = m.top + y,
            w = col_w,
            h = math.min(cell_h, m.grid_h),
        }
        heights[best] = y + cell_h
        layout.page_of[i] = #layout.pages + 1
    end
    flush()
    if #layout.pages == 0 then layout.pages[1] = {} end
    self._gallery_layouts[tab] = layout
    return layout
end

-- Heading band geometry, derived from the actual rendered line heights so
-- the top breathing room scales with the font (≈ a quarter of a title line)
-- on any device. Cached for the viewer's lifetime (the faces never change).
-- Single source of truth: _buildGallery positions the two lines from
-- band_top/gap, _galleryMetrics starts the grid at content_top, so they stay
-- in lockstep.
function ArtGalleryViewer:_headMetrics()
    if self._head_metrics then return self._head_metrics end
    local t = TextWidget:new{
        text = "Gy", face = Font:getFace("cfont", 16), bold = true }
    local s = TextWidget:new{
        text = "Gy", face = Font:getFace("cfont", 12), bold = true }
    local th1, th2 = t:getSize().h, s:getSize().h
    t:free(); s:free()
    local band_top = Screen:scaleBySize(3) + math.floor(th1 / 4)
    local gap = 0                              -- subtitle tucked under title
    local below = Screen:scaleBySize(6)        -- band → grid
    self._head_metrics = {
        band_top = band_top, th1 = th1, gap = gap,
        content_top = band_top + th1 + gap + th2 + below,
    }
    return self._head_metrics
end

-- Shared gallery geometry: the band above the grid holds the heading and
-- the Close button, the band below holds the page pill and ‹ › buttons.
-- area_w is the FULL content width (unlike the single-image view, the
-- grid has no chrome that needs to dodge the rounded right corner — the
-- top/bottom bands already keep clear of it vertically) so the grid's
-- right margin (pad) matches its left margin exactly.
function ArtGalleryViewer:_galleryMetrics()
    local content_top = self:_headMetrics().content_top
    return {
        area_w = self.width,
        pad = Screen:scaleBySize(16),
        top = content_top,
        bottom = Screen:scaleBySize(60),
        gap = Screen:scaleBySize(10),
        inset = Screen:scaleBySize(4),
        grid_h = self.img_container_h - content_top - Screen:scaleBySize(60),
    }
end

function ArtGalleryViewer:_galleryGo(delta)
    local p = math.min(math.max((self._gallery_page or 1) + delta, 1),
        self:_galleryPages())
    if p ~= self._gallery_page then
        self._gallery_page = p
        self:update()
    end
end

-- Thumbnail for image i, fitted inside w×h, cached for the lifetime of
-- the drawer (revisiting a page is instant; the current image usually
-- hits the plugin's decoded-bitmap cache too). The source comes from the
-- render closure, so night baking is already in the pixels — the cache
-- can't go stale on us because night mode can't change while the drawer
-- is open; the cache is freed with the viewer.
function ArtGalleryViewer:_thumb(i, w, h)
    local THUMB_CACHE_CAP = 256 -- 缩略图缓存上限（FIFO 淘汰，防大书内存膨胀）
    self._thumb_bbs = self._thumb_bbs or {}
    self._thumb_keys = self._thumb_keys or {}
    -- key by tab too: index i means different images across tabs, and we
    -- want a cached thumbnail to survive flipping tabs back and forth
    local ckey = (self._gallery_tab or "shown") .. ":" .. i
    local t = self._thumb_bbs[ckey]
    if t and t.w == w and t.h == h then
        return t.bb
    end
    if t and t.bb then
        t.bb:free()
        self._thumb_bbs[ckey] = nil
    end
    local list = (self:_tabList())
    local src = list and list[i]
    local own = false
    if type(src) == "function" then
        src = src()
        own = true -- the closure hands us a fresh bitmap: ours to free
    end
    if not src then return nil end
    local bw, bh = src:getWidth(), src:getHeight()
    local s = math.min(w / bw, h / bh, 1)
    local bb
    if s < 1 then
        -- pcall 兜底：退化源（0×0 / 1×1 等）可能让缩放抛错，失败则退回未缩放
        -- 副本，绝不因此炸掉图库翻页。
        local ok_s, sb = pcall(RenderImage.scaleBlitBuffer, RenderImage, src,
            math.max(1, math.floor(bw * s + 0.5)),
            math.max(1, math.floor(bh * s + 0.5)), own)
        if ok_s and sb then
            bb = sb
        else
            bb = own and src or src:copy()
        end
    else
        bb = own and src or src:copy()
    end
    if not bb then return nil end
    -- No fb-flag matching here (see _new_image_wg): the source is already
    -- night-baked device-agnostically, and a plain flag-0 blit is correct on
    -- every device.
    -- FIFO 淘汰：限制常驻缩略图数量，避免大书/漫画翻页时内存无限增长
    -- （KPW3 可用 RAM 有限）。超出上限即释放最早插入的缩略图位图。
    self._thumb_bbs[ckey] = { bb = bb, w = w, h = h }
    table.insert(self._thumb_keys, ckey)
    while #self._thumb_keys > THUMB_CACHE_CAP do
        local old = table.remove(self._thumb_keys, 1)
        local ot = self._thumb_bbs[old]
        if ot and ot.bb then ot.bb:free() end
        self._thumb_bbs[old] = nil
    end
    return bb
end

-- Builds the masonry page as self.image_container (update() slots it
-- into the overlay in place of the image). Cell rects are recorded
-- relative to the drawer content origin for onTap hit-testing.
function ArtGalleryViewer:_buildGallery()
    local layout = self:_galleryLayout()
    local pages = #layout.pages
    self._gallery_page = math.min(math.max(self._gallery_page or 1, 1), pages)
    local m = self:_galleryMetrics()
    local grid = OverlapGroup:new{
        dimen = Geom:new{ w = self.width, h = self.img_container_h },
    }
    -- Two-line header (top band, display-only — the Gallery/Ignored switch
    -- lives on the BOTTOM bar, since the top strip is KOReader's top-menu tap
    -- zone). Line 1: "Gallery"/"Ignored" left, "Page X of Y" right-aligned
    -- when paged. Line 2 (smaller, grey): "N images in Gallery"/"N ignored".
    if self._gallery_head_wgs then
        for _, w in ipairs(self._gallery_head_wgs) do w:free() end
    end
    self._gallery_head_wgs = {}
    local function addHead(wg)
        table.insert(grid, wg)
        table.insert(self._gallery_head_wgs, wg)
    end
    if self._gallery_badges then
        for _, b in ipairs(self._gallery_badges) do b:free() end
    end
    self._gallery_badges = {}
    local band_top = self:_headMetrics().band_top
    local on_ignored_tab = self._gallery_tab == "ignored"
    local active_is_primary = (self._gallery_tab or "shown")
        == (self.primary_tab or "shown")
    local count = select(3, self:_tabList())
    local title_wg = TextWidget:new{
        text = on_ignored_tab and _("已忽略") or _("图库"),
        face = Font:getFace("cfont", 16),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local th1 = title_wg:getSize().h
    title_wg.overlap_offset = { m.pad, band_top }
    addHead(title_wg)
    if pages > 1 then
        local page_wg = TextWidget:new{
            text = T(_("第 %1 页，共 %2 页"), self._gallery_page or 1, pages),
            face = Font:getFace("cfont", 13),
            bold = true,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        local psz = page_wg:getSize()
        page_wg.overlap_offset = {
            m.area_w - m.pad - psz.w,
            band_top + math.floor((th1 - psz.h) / 2),
        }
        addHead(page_wg)
    end
    local sub_wg = TextWidget:new{
        text = count == 1 and _("1 张图片") or T(_("%1 张图片"), count),
        face = Font:getFace("cfont", 12),
        bold = true,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        max_width = m.area_w - 2 * m.pad,
    }
    sub_wg.overlap_offset = { m.pad, band_top + th1 + self:_headMetrics().gap }
    addHead(sub_wg)
    self._gallery_cells = {}
    for _, c in ipairs(layout.pages[self._gallery_page] or {}) do
        local bb = self:_thumb(c.idx,
            c.w - 2 * m.inset, c.h - 2 * m.inset)
        if bb then
            -- every thumbnail gets a subtle rounded outline so adjacent
            -- images (which otherwise butt edge to edge) stay visually
            -- distinct; the current image gets a heavier black one on
            -- top of that (only on the pool the single-view is showing)
            local is_cur = active_is_primary
                and c.idx == (self._images_list_cur or 1)
            local cell = CenterContainer:new{
                dimen = Geom:new{ w = c.w, h = c.h },
                FrameContainer:new{
                    bordersize = is_cur
                        and Screen:scaleBySize(2) or Screen:scaleBySize(1),
                    color = is_cur and Blitbuffer.COLOR_BLACK
                        or Blitbuffer.COLOR_GRAY,
                    radius = Screen:scaleBySize(3),
                    padding = Screen:scaleBySize(2),
                    ImageWidget:new{
                        image = bb,
                        image_disposable = false, -- cached in _thumb_bbs
                        alpha = true,
                        original_in_nightmode = false,
                        scale_factor = 1,
                    },
                },
            }
            cell.overlap_offset = { c.x, c.y }
            table.insert(grid, cell)
            table.insert(self._gallery_cells,
                { x = c.x, y = c.y, w = c.w, h = c.h, idx = c.idx })
            -- reading-order number badge (top-left), added AFTER the cell so
            -- it paints on top. Only in the Gallery grid — the Ignored
            -- grid has no badge (order there isn't meaningful).
            if not on_ignored_tab then
                local badge = ArtGalleryBadge:new{ num = c.idx }
                badge.overlap_offset = {
                    c.x + m.inset + Screen:scaleBySize(3),
                    c.y + m.inset + Screen:scaleBySize(3),
                }
                table.insert(grid, badge)
                table.insert(self._gallery_badges, badge)
            end
        end
    end
    self.image_container = grid
end

-- Would the ⋯ popup have at least one row? Mirrors the gating in
-- _showMoreMenu so update() can hide the ⋯ button entirely when the user
-- has turned every Quick Action off (restore only counts when something is
-- actually hidden; the rest are unconditional).
function ArtGalleryViewer:_hasQuickActions()
    for _, d in ipairs(QUICK_ACTIONS) do
        if _quick_enabled(d.key) then
            if d.key == "restore" then
                if self.hidden_count and self.hidden_count() > 0 then
                    return true
                end
            else
                return true
            end
        end
    end
    return false
end

-- The ⋯ menu (from the design): gallery, remove from collection, rotate
-- 90° (remembered per image, plus a reset once rotated), show in book,
-- invert in night mode (the global setting, also in the plugin menu).
-- The gallery has no ⋯ button (it shows a Close button instead), so this
-- only ever runs on the single-image view.
function ArtGalleryViewer:_showMoreMenu()
    -- Which rows appear is user-configurable ("Quick Actions" in the plugin
    -- menu, see QUICK_ACTIONS). Order here = the canonical popup order; each
    -- block is gated on its own flag. Toggle rows (prevnext/captions/invert)
    -- draw a checkbox in the icon column and flip the matching setting live.
    local items = {}
    -- ⤢ 一键全屏（仅单图模式）：状态随当前是否全屏显示「退出全屏 / 全屏查看」
    if not self._gallery_mode then
        items[#items + 1] = {
            text = self._fullscreen and _("退出全屏") or _("全屏查看"),
            icon = _PLUGIN_DIR .. (self._fullscreen
                and "/assets/fullscreen_exit.svg" or "/assets/fullscreen.svg"),
            callback = function() self:_toggleFullscreen() end,
        }
    end
    -- ★ 收藏（单图模式）：加入 / 移出收藏（全局可用，脱离书本也有效）
    if not self._gallery_mode then
        local fav = self:_currentFavoriteState()
        items[#items + 1] = {
            text = fav and _("移出收藏") or _("加入收藏"),
            icon = _PLUGIN_DIR .. "/assets/"
                .. (fav and "favorite_on.svg" or "favorite_off.svg"),
            callback = function() self:_toggleFavorite() end,
        }
    end
    if _quick_enabled("gallery") then
        items[#items + 1] = {
            text = _("图库"),
            icon = _PLUGIN_DIR .. "/assets/gallery.svg",
            callback = function() self:_enterGallery() end,
        }
    end
    if _quick_enabled("hide") then
        items[#items + 1] = {
            text = _("忽略此图片"),
            icon = _PLUGIN_DIR .. "/assets/hide.svg",
            callback = function() self:_hideCurrentImage() end,
        }
    end
    if _quick_enabled("mode") and not self.is_favorites and not self.is_cbz then
        items[#items + 1] = {
            -- scope switch: reflects the current view, tap flips it and reopens
            text = self.scope == "whole_book"
                and _("模式：所有图片")
                or (self.scope == "current_page"
                    and _("模式：仅显示已读到的图片")
                    or _("模式：仅当前章节之前")),
            icon = _PLUGIN_DIR .. "/assets/mode.svg",
            callback = function()
                if self.on_toggle_scope then self.on_toggle_scope() end
            end,
        }
    end
    if _quick_enabled("rotate") then
        items[#items + 1] = {
            text = _("旋转90°"),
            icon = _PLUGIN_DIR .. "/assets/rotate.svg",
            callback = function() self:_rotateCurrent() end,
        }
        -- Reset Rotation rides with Rotate, shown only while rotated
        if (self._cur_rotation or 0) ~= 0 then
            items[#items + 1] = {
                text = _("重置旋转"),
                icon = _PLUGIN_DIR .. "/assets/reset-rotation.svg",
                callback = function() self:_setRotation(0) end,
            }
        end
    end
    if self._fullscreen then
        -- 全屏填充模式三态（收纳于「右 ⋯」菜单）：单击切换、长按设为默认全屏看图模式。
        -- 拉伸首选用会弹出一次性变形确认（见 _setFullscreenFill）。
        items[#items + 1] = {
            text = _("全屏铺满（裁切溢出）"),
            checked_func = function() return self._fullscreen_fill == "cover" end,
            callback = function() self:_setFullscreenFill("cover") end,
            hold_callback = function() self:_setDefaultFill("cover") end,
            separator = true,
        }
        items[#items + 1] = {
            text = _("全屏适配（整图可见）"),
            checked_func = function() return self._fullscreen_fill == "contain" end,
            callback = function() self:_setFullscreenFill("contain") end,
            hold_callback = function() self:_setDefaultFill("contain") end,
        }
        items[#items + 1] = {
            text = _("全屏拉伸（填满不变形提示）"),
            checked_func = function() return self._fullscreen_fill == "stretch" end,
            callback = function() self:_setFullscreenFill("stretch") end,
            hold_callback = function() self:_setDefaultFill("stretch") end,
        }
    end
    if _quick_enabled("showinbook") and not self.is_favorites and not self.is_cbz then
        items[#items + 1] = {
            text = _("在书中定位"),
            icon = _PLUGIN_DIR .. "/assets/navigate.svg",
            callback = function() self:_showInBook() end,
        }
    end
    if _quick_enabled("restore") and self.hidden_count
            and self.hidden_count() > 0 then
        items[#items + 1] = {
            text = _("恢复被忽略的图片"),
            icon = _PLUGIN_DIR .. "/assets/restore.svg",
            callback = function()
                if self.on_restore_hidden then self.on_restore_hidden() end
            end,
        }
    end
    if _quick_enabled("prevnext") then
        items[#items + 1] = {
            text = _("显示导航按钮"),
            check = G_reader_settings:isTrue(NAV_BUTTONS_KEY),
            callback = function() self:_togglePrevNext() end,
        }
    end
    if _quick_enabled("captions") then
        items[#items + 1] = {
            text = _("显示图片标题"),
            check = G_reader_settings:nilOrTrue(CAPTIONS_KEY),
            callback = function() self:_toggleCaptions() end,
        }
    end
    if _quick_enabled("invert") then
        items[#items + 1] = {
            -- checkbox drawn in the icon column (see ArtGalleryMenuRow),
            -- so it lines up with the icons above it
            text = _("夜间模式反转图片"),
            check = G_reader_settings:isTrue(INVERT_KEY),
            callback = function() self:_toggleInvert() end,
        }
    end
    -- Defensive: with every Quick Action off the ⋯ button is hidden (see
    -- update()/_hasQuickActions), so this normally can't be reached empty.
    if #items == 0 then return end
    local menu
    menu = ArtGalleryPopupMenu:new{
        items = items,
        -- anchor to the ⋯ button (bottom row): right edge aligned to the
        -- button's right edge (MovableContainer left-aligns on the anchor,
        -- so shift left by our own width, known by the time ensureAnchor
        -- calls this). The button sits near the screen bottom, so the menu
        -- has no room below and pops UP — its bottom lands at the anchor's
        -- y. Lifting y by `gap` above the button top puts a real margin
        -- OUTSIDE the popup, between it and the button (an earlier attempt
        -- put padding INSIDE, under the last row, which was wrong).
        anchor = function()
            local d = self._more_frame and self._more_frame.dimen
            if not d then return end
            local mov = menu.movable
            local w = mov and mov.dimen and mov.dimen.w or 0
            local gap = Screen:scaleBySize(10)
            return Geom:new{ x = d.x + d.w - w, y = d.y - gap,
                w = 0, h = d.h }, true
        end,
    }
    -- when the menu closes, also repaint the ⋯ button so its pressed
    -- (inverted) state clears
    menu._restore_region = self._more_frame and self._more_frame.dimen
        and self._more_frame.dimen:copy()
    menu.on_dismiss = function()
        if self._more_frame then self._more_frame.inverted = nil end
    end
    -- region function: the anchored rect is only known after the
    -- MovableContainer paints, and a full-screen refresh flashes the map
    UIManager:show(menu, function()
        return "ui", menu.movable.dimen
    end)
end

-- ⋯ menu "Show in Book": close the drawer and jump the reader to the
-- chapter the current image lives in (the plugin hook does the jump and
-- pushes the previous location so Back returns to the reading position).
function ArtGalleryViewer:_showInBook()
    local meta = self.image_metas and self.image_metas[self._images_list_cur or 1]
    if meta and self.on_show_in_book then
        self:onClose()
        self.on_show_in_book(meta)
    end
end

function ArtGalleryViewer:_favKey()
    local im = self.image_metas and self.image_metas[self._images_list_cur or 1]
    if not im then return nil end
    if self.is_cbz and self._zip_path then
        return "cbz:" .. self._zip_path .. "#" .. im.path
    elseif self.artgallery and self.artgallery.ui and self.artgallery.ui.document then
        return self.artgallery.ui.document.file .. "#" .. im.path
    end
    return nil
end

function ArtGalleryViewer:_currentFavoriteState()
    if self.is_favorites then return true end
    return self.artgallery and self.artgallery:isFavoriteByKey(self:_favKey()) or false
end

function ArtGalleryViewer:_toggleFavorite()
    local im = self.image_metas and self.image_metas[self._images_list_cur or 1]
    if not im or not self.artgallery then return end
    if self.is_favorites then
        self.artgallery:removeFavoriteByFile(im.path)
        UIManager:show(InfoMessage:new{ text = _("已移出收藏。") })
        return
    end
    self.artgallery:addFavorite(im, self)
end

-- Each press turns the image a quarter-turn CLOCKWISE on screen (matching
-- the rotate icon's arrow); ImageWidget's rotation_angle is
-- counter-clockwise, so step by -90.
function ArtGalleryViewer:_rotateCurrent()
    self:_setRotation(((self._cur_rotation or 0) - 90) % 360)
end

function ArtGalleryViewer:_setRotation(rotation)
    self._cur_rotation = rotation
    self._fit_scale_factor = nil -- rotated image, different fit
    self._scale_factor_0 = nil
    local meta = self.image_metas and self.image_metas[self._images_list_cur]
    if meta and self.set_pref then
        self.set_pref(meta, "rotation",
            self._cur_rotation ~= 0 and self._cur_rotation or nil)
    end
    self:update()
end

function ArtGalleryViewer:_toggleInvert()
    local cur = self._images_list_cur or 1
    G_reader_settings:saveSetting(INVERT_KEY,
        not G_reader_settings:isTrue(INVERT_KEY))
    -- cached gallery thumbnails have the OLD polarity baked into their
    -- pixels — drop them so the gallery re-renders with the new setting
    if self._thumb_bbs then
        for _, t in pairs(self._thumb_bbs) do
            if t.bb then t.bb:free() end
        end
        self._thumb_bbs = nil
    end
    -- the cached full-res decode has the OLD polarity baked in — drop it so a
    -- later zoom re-decodes with the new setting
    self:_resetHiRes()
    -- re-render so the change is visible immediately (the render closure
    -- reads prefs and night mode live)
    if self.image and self.image_disposable and self.image.free then
        self.image:free()
    end
    self.image = self._images_list[cur]
    if type(self.image) == "function" then
        self.image = self.image()
    end
    self:update()
end

-- ⋯ toggle rows for the two viewer-appearance settings (also in the plugin
-- menu): flip the global setting and re-lay-out so the change shows at once.
function ArtGalleryViewer:_togglePrevNext()
    G_reader_settings:saveSetting(NAV_BUTTONS_KEY,
        not G_reader_settings:isTrue(NAV_BUTTONS_KEY))
    self:update()
end

function ArtGalleryViewer:_toggleCaptions()
    G_reader_settings:saveSetting(CAPTIONS_KEY,
        not G_reader_settings:nilOrTrue(CAPTIONS_KEY))
    self:update()
end

-- Manual double-tap detection from instant Tap events: a second tap close
-- in time and position counts as a double-tap. Only consulted where the
-- single tap would do nothing (middle area at fit, anywhere while zoomed),
-- so no single-tap action ever has to be delayed or undone.
function ArtGalleryViewer:_checkDoubleTap(ges)
    local now = time.now()
    local slop = Screen:scaleBySize(50)
    local lt = self._last_tap
    self._last_tap = { time = now, x = ges.pos.x, y = ges.pos.y }
    if lt and now - lt.time < time.ms(350)
       and math.abs(ges.pos.x - lt.x) <= slop
       and math.abs(ges.pos.y - lt.y) <= slop then
        self._last_tap = nil
        -- 取消挂起的「延迟隐藏」，改为双击缩放（避免隐藏与缩放打架）
        if self._chrome_hide_action then
            UIManager:unschedule(self._chrome_hide_action)
            self._chrome_hide_action = nil
        end
        self:onArtGalleryDoubleTap(nil, ges)
    end
end

-- Double-tap: toggle between best-fit and the max zoom (150% of native,
-- max_zoom_of_native), centered on the tapped point. From fit it jumps
-- straight to max — the full-res decode swaps in (see _new_image_wg) so it's
-- as sharp as the source allows; from any zoomed state it snaps back to fit.
-- Pinch covers everything in between, stepless. (For small images the max is
-- at or below fit, so double-tap just stays at the fit view.)
function ArtGalleryViewer:onArtGalleryDoubleTap(_, ges)
    -- 拉伸态双击放大已放开：逻辑与 cover 一致（0 ↔ _maxScale），见 _applyNewScaleFactor。
    local was_fit = self.scale_factor == 0
    -- re-center the zoom on the tapped point (harmless when we end up
    -- snapping back to fit — that path resets the center to the middle)
    local wg = self._image_wg
    if wg and ges and ges.pos then
        wg:getSize() -- pan math needs a rendered bb
        local d = wg.dimen
        local cx = d and (d.x + d.w / 2) or Screen:getWidth() / 2
        local cy = d and (d.y + d.h / 2) or Screen:getHeight() / 2
        self._center_x_ratio, self._center_y_ratio =
            wg:getPanByCenterRatio(ges.pos.x - cx, ges.pos.y - cy)
    end
    self:_refreshScaleFactor() -- resolve fit (scale 0) into a number
    if was_fit then
        -- jump to the max zoom (clamped to fit for small images by
        -- _applyNewScaleFactor, which also enforces the same ceiling)
        self:_applyNewScaleFactor(self:_maxScale() or self.scale_factor)
    else
        self.scale_factor = 0
        self._center_x_ratio, self._center_y_ratio = 0.5, 0.5
        self:update()
    end
    return true
end

-- 拉伸态从「非均匀填满」(scale_factor==0) 进入缩放：上游 onZoomIn 算
-- new_factor = scale_factor*(1+inc)，而 stretch fit 态 scale_factor 恒为 0
-- → 结果恒 0，双指张开/捏合从填满态根本进不了缩放（见方案第三节的 0 基数坑）。
-- 故此处以 cover 下限为基数放大；已缩放态（scale_factor~=0）委托上游继续连续缩放。
function ArtGalleryViewer:onZoomIn(inc)
    if self._fullscreen_fill == "stretch" and self.scale_factor == 0 then
        local floor = self:_computeFitScaleFactor() -- cover 均匀填满比例
        inc = inc or 0.2
        self:_applyNewScaleFactor(floor * (1 + inc))
        return true
    end
    return ImageViewer.onZoomIn(self, inc)
end

-- 拉伸态已在「非均匀填满」(scale_factor==0)：再缩小无意义（已是最满），停在填满。
-- 已缩放态委托上游，缩放回弹到 ≤ cover 下限时由 _applyNewScaleFactor 归 0 回到拉伸。
function ArtGalleryViewer:onZoomOut(dec)
    if self._fullscreen_fill == "stretch" and self.scale_factor == 0 then
        return true
    end
    return ImageViewer.onZoomOut(self, dec)
end

-- Press feedback for the nav buttons: paint the button inverted, then —
-- like upstream Button:onTapSelectButton — DRAIN the refresh queue and
-- yield to the EPDC before running the action. Just queueing the flash
-- refresh doesn't work: the action's own refresh follows milliseconds
-- later and supersedes it before the panel ever shows the flash. The
-- rebuilt button from the switch's update() clears the pressed state.
-- Disabled buttons consume the tap without flashing or acting.
function ArtGalleryViewer:_flashButton(frame, action)
    if frame.disabled then return end
    local d = frame.dimen
    frame.inverted = true
    UIManager:widgetRepaint(frame, d.x, d.y)
    UIManager:setDirty(nil, "fast", d)
    UIManager:forceRePaint()
    UIManager:yieldToEPDC()
    action()
end

-- KOReader's configurable top-menu tap zone (DTAP_ZONE_MENU, default the
-- top 1/8 of the screen, full width), as a screen rect. Falls back to the
-- default if the global defaults table isn't reachable for any reason.
function ArtGalleryViewer:_inTopMenuZone(pos)
    local z = { x = 0, y = 0, w = 1, h = 1 / 8 }
    if G_defaults then
        local zz = G_defaults:readSetting("DTAP_ZONE_MENU")
        if zz then z = zz end
    end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    return pos:intersectWith(Geom:new{
        x = z.x * sw, y = z.y * sh, w = z.w * sw, h = z.h * sh })
end

-- Tap: the top-menu zone opens KOReader's top menu (see onTap); a tap
-- elsewhere outside the drawer closes; on the ⋯ button opens the menu.
-- Image switching is swipe-only (or the optional buttons), which leaves
-- the rest of the image as a double-tap zoom surface.
function ArtGalleryViewer:onTap(_, ges)
    -- Respect KOReader's own top-of-screen menu trigger: a tap in that
    -- zone opens ONLY the top menu, over the still-open drawer (the ⋯
    -- button was moved to the bottom row precisely to keep this strip
    -- clear). We open the top menu directly rather than letting the tap
    -- fall through to ReaderMenu:onTapShowMenu, which would ALSO open the
    -- bottom config menu whenever the user's show_bottom_menu setting is
    -- on (the default) — here we never want that second menu.
    if self.on_show_menu and G_reader_settings:nilOrTrue(TOP_MENU_KEY)
       and self:_inTopMenuZone(ges.pos) then
        self.on_show_menu()
        return true
    end
    -- 全屏沉浸式：进入全屏即隐藏覆盖层（_toggleFullscreen 置 _chrome_hidden）。
    -- 隐藏态：底部点按恢复覆盖层、其余点按允许双击缩放；显示态：点按非按钮
    -- 区域延迟隐藏（延迟以兼容双击缩放，见 onTap 末尾与 _checkDoubleTap）。
    if self._fullscreen and self.scale_factor == 0 then
        if self._chrome_hidden then
            if self:_inBottomZone(ges.pos) then
                self:_setChrome(false)
            else
                self:_checkDoubleTap(ges)
            end
            return true
        end
        -- 显示态：后续按钮命中检测照常；未命中则在 onTap 末尾延迟隐藏
    end
    if ges.pos:notIntersectWith(self.main_frame.dimen) then
        self:onClose()
        return true
    end
    if self._gallery_mode and self._close_frame and self._close_frame.dimen
       and ges.pos:intersectWith(self._close_frame.dimen) then
        self:_flashButton(self._close_frame, function()
            self:_exitGallery()
        end)
        return true
    end
    -- gate on not-gallery: _more_frame keeps its stale dimen (same rect
    -- the Close button now occupies) from the last single-image paint
    if not self._gallery_mode and self._more_frame and self._more_frame.dimen
       and ges.pos:intersectWith(self._more_frame.dimen) then
        -- press feedback: repaint the button inverted (rounded, via its
        -- stencil mask); it stays inverted while the menu is open and
        -- repaints normal on dismiss, whose region covers the button
        local d = self._more_frame.dimen
        self._more_frame.inverted = true
        UIManager:widgetRepaint(self._more_frame, d.x, d.y)
        UIManager:setDirty(nil, "fast", d)
        self:_showMoreMenu()
        return true
    end
    if self._nav_prev_frame and self._nav_prev_frame.dimen
       and ges.pos:intersectWith(self._nav_prev_frame.dimen) then
        self:_flashButton(self._nav_prev_frame, function()
            if self._gallery_mode then self:_galleryGo(-1)
            else self:onShowPrevImage() end
        end)
        return true
    end
    if self._nav_next_frame and self._nav_next_frame.dimen
       and ges.pos:intersectWith(self._nav_next_frame.dimen) then
        self:_flashButton(self._nav_next_frame, function()
            if self._gallery_mode then self:_galleryGo(1)
            else self:onShowNextImage() end
        end)
        return true
    end
    -- ⤢ 全屏切换
    if self._fs_frame and self._fs_frame.dimen
       and ges.pos:intersectWith(self._fs_frame.dimen) then
        self:_flashButton(self._fs_frame, function()
            self:_toggleFullscreen()
        end)
        return true
    end
    if self._gallery_mode then
        -- the Shown/Ignored toggle (bottom-center pill)
        if self._pill_frame and self._pill_frame.dimen
           and ges.pos:intersectWith(self._pill_frame.dimen) then
            self:_flashButton(self._pill_frame, function()
                self:_switchGalleryTab(
                    self._gallery_tab == "ignored" and "shown" or "ignored")
            end)
            return true
        end
        -- thumbnail: tap opens it ONLY when this pool is what the single-image
        -- view shows (the primary/Gallery tab). A tap on an Ignored
        -- thumbnail does nothing — adding it back is a long-press (see onHold).
        local cell = self:_galleryHit(ges.pos)
        if cell and self._gallery_tab == (self.primary_tab or "shown") then
            self:_exitGallery(cell.idx)
        end
        return true -- no zoom surface in the gallery
    end
    -- dot indicator: tappable as a quick "jump near here" — precisely
    -- hitting an individual dot isn't the point, so the hitbox is padded
    -- well beyond the dots' own tiny paint area
    if self._pill_dots and self._pill_frame and self._pill_frame.dimen then
        local d = self._pill_frame.dimen
        local pad = Screen:scaleBySize(20)
        local hit = Geom:new{
            x = d.x - pad, y = d.y - pad,
            w = d.w + 2 * pad, h = d.h + 2 * pad,
        }
        if ges.pos:intersectWith(hit) then
            local dots = self._pill_dots
            local dd = dots.dimen or d
            local rel = ges.pos.x - dd.x - dots.dot_r
            local idx = math.floor(rel / dots.pitch + 0.5) + 1
            idx = math.min(math.max(idx, 1), dots.nb)
            if idx ~= (self._images_list_cur or 1) then
                self:switchToImageNum(idx)
            end
            return true
        end
    end
    if self.scale_factor ~= 0 then
        -- zoomed: the pill is a "Revert to 100%" button; single taps
        -- elsewhere do nothing (no image switching while zoomed), but a
        -- double-tap goes back to fit
        if self._pill_frame and self._pill_frame.dimen
           and ges.pos:intersectWith(self._pill_frame.dimen) then
            self.scale_factor = 0
            self._center_x_ratio, self._center_y_ratio = 0.5, 0.5
            self:update()
        else
            self:_checkDoubleTap(ges)
        end
        return true
    end
    -- 全屏显示态：点按图片（未命中按钮）延迟 350ms 隐藏覆盖层，以兼容双击缩放
    -- （双击时由 _checkDoubleTap 取消此挂起任务并改为缩放）
    if self._fullscreen and not self._chrome_hidden and self.scale_factor == 0 then
        if self._chrome_hide_action then
            UIManager:unschedule(self._chrome_hide_action)
            self._chrome_hide_action = nil
        end
        self._chrome_hide_action = function()
            self._chrome_hide_action = nil
            self:_setChrome(true)
        end
        UIManager:scheduleIn(0.35, self._chrome_hide_action)
    end
    self:_checkDoubleTap(ges)
    return true
end

-- Physical page-turn keys (upstream maps PgFwd/PgBack to these when the
-- image is a list): in the gallery they flip grid pages instead.
function ArtGalleryViewer:onShowNextImage()
    if self._gallery_mode then
        self:_galleryGo(1)
        return true
    end
    return ImageViewer.onShowNextImage(self)
end

function ArtGalleryViewer:onShowPrevImage()
    if self._gallery_mode then
        self:_galleryGo(-1)
        return true
    end
    return ImageViewer.onShowPrevImage(self)
end

function ArtGalleryViewer:switchToImageNum(image_num)
    if not self._images_list
       or image_num < 1 or image_num > self._images_list_nb then
        return
    end
    self._cur_rotation = self:_prefFor(image_num).rotation or 0
    self._fit_scale_factor = nil -- different image, different fit
    self._scale_factor_0 = nil
    -- new image: the outgoing image's full-res decode is no longer needed
    self:_resetHiRes()
    -- New image content: flash the panel region on the resulting refresh so
    -- the previous image doesn't ghost through (see the refresh policy in
    -- update()). switchToImageNum → ImageViewer.switchToImageNum → update().
    self._flash_switch = true
    ImageViewer.switchToImageNum(self, image_num)
    local meta = self.image_metas and self.image_metas[image_num]
    if meta and self.on_image_shown then
        self.on_image_shown(meta, image_num)
    end
end

-- In fit-to-screen mode panning is a no-op, so horizontal swipes act as
-- prev/next (feels like page turns) and other directions are swallowed —
-- upstream would close the viewer on swipe-south at fit, too easy to hit
-- accidentally now that switching is swipe-only (closing stays on
-- tap-outside). Zoomed in, delegate to upstream so swipes keep panning.
function ArtGalleryViewer:onSwipe(arg, ges)
    if self._gallery_mode then
        local d = ges.direction
        if d == "west" or d == "east" then
            local forward = d == "west"
            if BD.mirroredUILayout() then forward = not forward end
            self:_galleryGo(forward and 1 or -1)
        end
        return true
    end
    if self.scale_factor == 0 then
        local d = ges.direction
        if self._images_list and (d == "west" or d == "east") then
            local forward = d == "west"
            if BD.mirroredUILayout() then forward = not forward end
            if forward then
                self:onShowNextImage()
            else
                self:onShowPrevImage()
            end
        end
        return true
    end
    return ImageViewer.onSwipe(self, arg, ges)
end

-- Upstream ImageViewer closes on ANY multiswipe (a direction-changing
-- gesture). While panning a zoomed image, a curved or hooked drag is very
-- easily reclassified from a pan into a multiswipe, which would close the
-- drawer mid-pan — the "panning sometimes just closes ArtGallery" bug. ArtGallery
-- closes by tapping outside the panel instead, so swallow multiswipes here.
function ArtGalleryViewer:onMultiSwipe(_, ges)
    return true
end

-- Long-press a Gallery thumbnail opens a small anchored menu with the one
-- move action for that pool (Ignore this image / Add back to Gallery);
-- see _openMoveMenu. Outside the gallery, defer to upstream (long-press
-- starts a pan on a zoomed image).
function ArtGalleryViewer:onHold(_, ges)
    if self._gallery_mode then
        local cell = self:_galleryHit(ges.pos)
        if cell then self:_openMoveMenu(cell, ges.pos) end
        return true
    end
    return ImageViewer.onHold(self, _, ges)
end

-- On the SDL emulator, mouse wheel / two-finger trackpad scroll arrives as
-- a fake pan gesture tagged mousewheel_direction (real devices never send
-- it): treat it as zoom, so pinch can be tested without a touchscreen.
-- Safe with the follow-up pan_release: upstream's onPanRelease only acts
-- when a real pan set _panning.
function ArtGalleryViewer:onPan(arg, ges)
    if ges and ges.mousewheel_direction and ges.mousewheel_direction ~= 0 then
        if ges.mousewheel_direction > 0 then
            self:onZoomIn(0.2)
        else
            self:onZoomOut(0.2)
        end
        return true
    end
    return ImageViewer.onPan(self, arg, ges)
end

-- Zoom-out floor: never below best-fit. The fit factor is captured while
-- we're still in fit mode (scale_factor == 0 means "fit" upstream, and
-- _refreshScaleFactor is what resolves it to a number in every zoom path);
-- reaching it snaps back to fit mode proper, which recenters the image
-- and re-enables swipe navigation.
-- True only when the image is actually spilling past its fit size —
-- scale_factor ~= 0 alone isn't enough: a restored view can carry a
-- scale_factor equal to fit. Chrome (the "Fit" pill button) should only
-- appear when there's somewhere to revert TO.
function ArtGalleryViewer:_isOverFit()
    if self.scale_factor == 0 then return false end
    local fit = self._fit_scale_factor or self:_computeFitScaleFactor() or 1
    return self.scale_factor > fit + 0.001
end

-- Best-fit factor for the current image, computed from its dimensions the
-- same way the widget's render resolves scale 0. Used when the fit factor
-- is needed before the viewer has ever been in fit mode (e.g. a restored
-- zoomed view) or before the first render.
function ArtGalleryViewer:_computeFitScaleFactor()
    local iw = self.image and self.image.getWidth and self.image:getWidth()
    local ih = self.image and self.image.getHeight and self.image:getHeight()
    if iw and ih and iw > 0 and ih > 0 then
        if self._cur_rotation == 90 or self._cur_rotation == 270 then
            iw, ih = ih, iw
        end
        local w_scale = (self.width - self.image_padding * 2) / iw
        local h_scale = (self.img_container_h - self.image_padding * 2) / ih
        -- 全屏「铺满」模式（cover）：取较大比例，图片占满整屏、溢出部分裁切。
        -- 由 self._fullscreen_fill 决定（cover/contain/stretch 三态）。拉伸态
        -- 在 fit（非缩放）时由 _new_image_wg 直接走 ImageWidget 非均匀拉伸填满，
        -- 但其**缩放下限**同样取 cover 比例——即拉伸态进入缩放后（已缩放回弹到
        -- 下限）会停在均匀铺满，再往下即归 0 回到非均匀拉伸填满，与"填满意图"一致。
        -- 抽屉态恒为 contain（小屏不裁切）。
        -- 铺满/拉伸仅作用于全屏态；抽屉态恒为 contain（小屏不裁切、不变形），
        -- 与 _new_image_wg 的 _fullscreen 门控一致，共同守住"抽屉态恒为 contain"契约。
        local cover = self._fullscreen and (self._fullscreen_fill == "cover" or self._fullscreen_fill == "stretch")
        if cover then
            return math.max(w_scale, h_scale)
        end
        -- contain 适配：取较小比例——整图完整可见、不裁切（地图/示意图边缘
        -- 内容得以保留）。全屏态不封顶 1.5，让图片取到能完整显示的最大比例；
        -- 配合 update() 里的全屏黑色底，留白在墨水屏上隐形，视觉铺满整屏
        -- （与 Illustrations 的全屏做法一致）。抽屉态封顶 1.5，避免小图在
        -- 80% 抽屉里被无脑放大。这也同时是缩放下限。
        local fit = math.min(w_scale, h_scale)
        if self._fullscreen then
            return fit
        end
        return math.min(1.5, fit)
    end
end

-- 智能选向：比较图片在 0° / 90° 两种朝向下能铺满多少屏幕（取各自 contain
-- 比例），返回更大者对应的朝向（0 或 90）。屏幕宽高比决定哪种朝向更贴合——
-- 横图转到竖屏朝向后能填满整屏，竖图保持原朝向。仅当图片尚未被手动旋转时
-- 由 _new_image_wg 自动套用（不裁切，因仍是 contain 选向）。
function ArtGalleryViewer:_smartRotation()
    local iw = self.image and self.image.getWidth and self.image:getWidth()
    local ih = self.image and self.image.getHeight and self.image:getHeight()
    if not (iw and ih and iw > 0 and ih > 0) then return nil end
    local W, H = Screen:getWidth(), Screen:getHeight()
    local c0 = math.min(W / iw, H / ih)
    local c90 = math.min(W / ih, H / iw)
    return (c90 > c0) and 90 or 0
end

function ArtGalleryViewer:_refreshScaleFactor()
    if self._gallery_mode then
        -- no zoom in the gallery; also keeps upstream from resolving
        -- scale_factor 0 into a number while no image widget exists
        return
    end
    -- 拉伸填满态恒为 fit（scale_factor 保持 0）：不参与缩放解析，避免上游把 0
    -- 改写成具体数值，导致 onTap 误判"已放大"分支（pill 变还原、禁切图、沉浸
    -- 显隐失效）。但缩放已放开（双击 / 双指手势可进缩放），此处需缓存 cover 下限
    -- 供 _applyNewScaleFactor 使用；不变量"0=拉伸填满"仍靠早返回维持。
    if self._fullscreen_fill == "stretch" then
        -- 缓存 cover 均匀铺满比例作为缩放下限（_computeFitScaleFactor 对 stretch
        -- 现已返回 cover 比例）；不解析 scale_factor，保持其 0。
        self._fit_scale_factor = self:_computeFitScaleFactor()
        return
    end
    if self.scale_factor == 0 then
        if self._image_wg then
            self._image_wg:getSize() -- force a render: resolves 0 → fit
        end
        local fit = self._image_wg and self._image_wg:getScaleFactor()
        if not fit or fit <= 0 then
            -- the widget only resolves 0 → fit on its first render; when a
            -- zoom arrives before that (e.g. wheel events in one UI tick),
            -- compute best-fit the same way its render does
            fit = self:_computeFitScaleFactor()
        end
        if fit and fit > 0 then
            self._fit_scale_factor = fit
            self._scale_factor_0 = fit -- lets upstream resolve 0 pre-render
        end
    end
    ImageViewer._refreshScaleFactor(self)
end

function ArtGalleryViewer:_applyNewScaleFactor(new_factor)
    if self._gallery_mode then return end
    -- 缩放已对拉伸态放开：双击放大 / 滚轮 / 双指张开捏合均可进缩放，缩放下限
    -- 为 cover 均匀铺满（见 _computeFitScaleFactor）；缩放回弹到 ≤ 下限即归 0
    -- 回到非均匀拉伸填满（见下方 new_factor <= fit 分支），不破"0=拉伸填满"不变量。
    self._fast_refresh = true -- mid-gesture zoom step: skip dithering
    if self._image_wg then
        -- upstream reads the widget's extrema, which need a rendered bb
        self._image_wg:getSize()
    end
    local fit = self._fit_scale_factor
    if not fit then
        -- a restored view opens already zoomed, never passing through fit
        -- mode where the floor is normally captured — compute it now so
        -- zooming out can't escape below best-fit
        fit = self:_computeFitScaleFactor()
        self._fit_scale_factor = fit
    end
    -- Ceiling: pinch may push a little past 100% (up to max_zoom_of_native)
    -- for readability, but no further — beyond that it's pure upscaling with
    -- no new detail. Bounds both pinch and any programmatic zoom.
    local ceil = self:_maxScale()
    if ceil and new_factor > ceil then new_factor = ceil end
    if fit and new_factor <= fit then
        if self.scale_factor ~= 0 then
            self.scale_factor = 0
            self._center_x_ratio, self._center_y_ratio = 0.5, 0.5
            self:update()
        end
        return
    end
    ImageViewer._applyNewScaleFactor(self, new_factor)
end

-- The scale_factor (in capped-bitmap units) at which the image shows at
-- exactly 100% — 1 native image pixel per screen pixel. Native dimensions
-- come from the scanner's header sniff (meta.width); when the resting bitmap
-- was never capped (small/medium images) 100% is just 1.0. Rotation doesn't
-- affect the ratio (both widths are pre-rotation). Returns nil if we can't
-- tell, leaving the memory-based extrema as the only ceiling.
function ArtGalleryViewer:_nativeScale()
    local lo = self.image
    if not lo or not lo.getWidth then return nil end
    local lo_w = lo:getWidth()
    if lo_w <= 0 then return nil end
    local meta = self.image_metas and self.image_metas[self._images_list_cur or 1]
    local nat_w = meta and meta.width
    if not nat_w or nat_w <= lo_w then return 1.0 end
    return nat_w / lo_w
end

-- Zoom ceiling in capped-bitmap units: native size × the readability
-- multiplier (max_zoom_of_native). Both the pinch clamp and the double-tap
-- target land here.
function ArtGalleryViewer:_maxScale()
    local nat = self:_nativeScale()
    local m = self.max_zoom_of_native
    -- 全屏 cover 的基准可能超过 1.5（横图按高度铺满时），放宽缩放上限，
    -- 避免「放大手势反而把图片缩小」的怪异表现。
    if self._fullscreen then m = m * 2 end
    return nat and nat * m
end

-- Forked from ImageWidget:panBy — the same crop-offset math on the
-- already rendered bitmap, minus its UIManager:setDirty("all", ...):
-- "all" marks every window dirty, so each pan step repainted the whole
-- book page below the drawer (a full-screen per-pixel Lua blit on
-- SW-invert night devices) and re-blended the shadow. Panning changes
-- nothing outside the image, so repaint the drawer only, undithered.
function ArtGalleryViewer:panBy(x, y)
    local wg = self._image_wg
    if not wg or not wg._bb then return end
    local cx = (x + wg._offset_x + wg.width / 2) / wg._bb_w
    local cy = (y + wg._offset_y + wg.height / 2) / wg._bb_h
    cx = math.min(math.max(cx, 0.5 - wg._max_off_center_x_ratio),
        0.5 + wg._max_off_center_x_ratio)
    cy = math.min(math.max(cy, 0.5 - wg._max_off_center_y_ratio),
        0.5 + wg._max_off_center_y_ratio)
    local ox = math.floor(cx * wg._bb_w - wg.width / 2)
    local oy = math.floor(cy * wg._bb_h - wg.height / 2)
    if ox == wg._offset_x and oy == wg._offset_y then return end
    wg._offset_x, wg._offset_y = ox, oy
    wg.center_x_ratio, wg.center_y_ratio = cx, cy
    -- keep the viewer's ratios in sync (zoom math and the saved view
    -- state read these, like upstream panBy does)
    self._center_x_ratio, self._center_y_ratio = cx, cy
    self._skip_shadow_paint = true
    self.dithered = false -- mid-gesture step: skip dithering
    local alpha = self.alpha
    self.alpha = false -- see update(): nil would fall back to the class 0.25
    UIManager:setDirty(self, function()
        return "ui", wg.dimen or self.main_frame.dimen, false
    end)
    self.alpha = alpha
end

function ArtGalleryViewer:_hideCurrentImage()
    local cur = self._images_list_cur
    local meta = self.image_metas and self.image_metas[cur]
    if meta and self.on_hide then
        self.on_hide(meta)
    end
    table.remove(self._images_list, cur)
    if self.image_metas then
        table.remove(self.image_metas, cur)
    end
    local nb = self._images_list_nb - 1
    self._images_list_nb = nb
    if nb < 1 then
        self:onClose()
        UIManager:show(Notification:new{
            text = _("图片已忽略。"),
        })
        return
    end
    if self.image and self.image_disposable and self.image.free then
        self.image:free()
        self.image = nil
    end
    self:_resetHiRes() -- the removed image's full-res decode is done with
    local new_cur = math.min(cur, nb)
    self._cur_rotation = self:_prefFor(new_cur).rotation or 0
    self.image = self._images_list[new_cur]
    if type(self.image) == "function" then
        self.image = self.image()
    end
    self._images_list_cur = new_cur
    self:update()
    UIManager:show(Notification:new{
        text = _("图片已忽略。"),
    })
    local meta2 = self.image_metas and self.image_metas[new_cur]
    if meta2 and self.on_image_shown then
        self.on_image_shown(meta2, new_cur)
    end
end

-- ── plugin ──────────────────────────────────────────────────────────────────

local ArtGallery = WidgetContainer:extend{
    name = "artgallery",
    -- also load in the file manager, so the Tools menu entry (and Check
    -- for updates) is always there; book-dependent actions answer with
    -- "No book is open." via _supportedReason
    is_doc_only = false,
    -- GitHub repo the in-plugin updater checks (class field so tests can
    -- point it at a repo with known releases)
    github_repo = "ksaMask123/artgallery.koplugin",
}

function ArtGallery:onDispatcherRegisterActions()
    Dispatcher:registerAction("artgallery_show", {
        category = "none",
        event = "ArtGalleryShow",
        title = _("打开美术馆"),
        reader = true,
    })
    Dispatcher:registerAction("artgallery_show_favorites", {
        category = "none",
        event = "ArtGalleryShowFavorites",
        title = _("显示美术馆收藏"),
        reader = true,
        filemanager = true,
    })
end

function ArtGallery:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function ArtGallery:onArtGalleryShow()
    self:showViewer()
    return true
end

function ArtGallery:onArtGalleryShowFavorites()
    self:showFavorites()
    return true
end

function ArtGallery:onCloseDocument()
    -- the decoded-bitmap cache slot (see showViewer) is per book
    if self._bb_cache then
        if self._bb_cache.bb then self._bb_cache.bb:free() end
        self._bb_cache = nil
    end
end

-- ── settings ────────────────────────────────────────────────────────────────

function ArtGallery:getScope()
    return G_reader_settings:readSetting(SCOPE_KEY) or "read_so_far"
end

-- 用户在某本书的空状态点了「搜索全书」后，按书记住该选择（存于本书
-- doc_settings），使后续打开此书直接以全书范围显示，不再每次弹出
-- 「搜索全书」。范围偏好（SCOPE_KEY）是全局的，故用独立的按书记忆区分。
function ArtGallery:_wholeBookRemembered()
    if self.ui and self.ui.doc_settings then
        local ok, v = pcall(self.ui.doc_settings.readSetting,
            self.ui.doc_settings, "artgallery_whole_book")
        if ok and v then return true end
    end
    return false
end

function ArtGallery:_rememberWholeBook()
    if self.ui and self.ui.doc_settings then
        pcall(self.ui.doc_settings.saveSetting,
            self.ui.doc_settings, "artgallery_whole_book", true)
    end
end

function ArtGallery:_forgetWholeBook()
    if self.ui and self.ui.doc_settings then
        pcall(self.ui.doc_settings.delSetting,
            self.ui.doc_settings, "artgallery_whole_book")
    end
end

function ArtGallery:getFilterLevel()
    return G_reader_settings:readSetting(FILTER_KEY) == "all"
        and "all" or "balanced"
end

function ArtGallery:_hiddenPaths()
    return (self.ui.doc_settings and
            self.ui.doc_settings:readSetting("artgallery_hidden")) or {}
end

-- Images the user has explicitly pulled back INTO the collection from the
-- Gallery's "Ignored" tab (the filter dropped them, or they were hidden).
-- The inverse of artgallery_hidden; a path in both means "shown" wins via the
-- partition in showViewer (add-back clears hidden and sets forced together).
function ArtGallery:_forcedPaths()
    return (self.ui.doc_settings and
            self.ui.doc_settings:readSetting("artgallery_forced")) or {}
end

-- Per-image, per-book viewer preferences: { [path] = {rotation=90} }
function ArtGallery:_imgPrefs()
    return (self.ui.doc_settings and
            self.ui.doc_settings:readSetting("artgallery_img_prefs")) or {}
end

function ArtGallery:_setImgPref(path, key, value)
    local all = self:_imgPrefs()
    local p = all[path] or {}
    p[key] = value
    local has = false
    for _ in pairs(p) do has = true break end
    all[path] = has and p or nil
    if self.ui and self.ui.doc_settings then
        self.ui.doc_settings:saveSetting("artgallery_img_prefs", all)
        -- Flush now so a per-image rotation survives even an unclean shutdown
        -- (sleep/battery-pull on an e-reader) rather than waiting for KOReader's
        -- next autosave or a clean book close. Cheap: rotation is a rare,
        -- user-initiated action, never a hot path. pcall 包裹：只读挂载时
        -- 落盘失败不应炸掉「旋转」这一用户操作。
        self:_safeFlush(self.ui.doc_settings)
    end
end

function ArtGallery:_hiddenCount()
    local n = 0
    for _ in pairs(self:_hiddenPaths()) do n = n + 1 end
    return n
end

-- ── document access ─────────────────────────────────────────────────────────

function ArtGallery:_supportedReason()
    local doc = self.ui and self.ui.document
    if not doc or not doc.file then
        return false, _("没有打开的书本。")
    end
    if not scanner then
        return false, _("美术馆未能加载扫描模块，请尝试重新安装插件。")
    end
    -- crengine documents expose getDocumentFileContent; paged formats
    -- (PDF/DjVu) do not, and their APIs must not be touched at all
    if type(doc.getDocumentFileContent) ~= "function" then
        return false, _("美术馆仅支持 EPUB 格式（当前文档格式不支持）。")
    end
    return true
end

-- Returns read_file(path) -> data|nil, plus a close() for the fallback
-- archive handle. Primary path is crengine's own archive access; libarchive
-- is the fallback for entries crengine won't hand over.
function ArtGallery:_makeReader()
    local doc = self.ui.document
    local arc
    local function read_file(path)
        local ok, data = pcall(doc.getDocumentFileContent, doc, path)
        if ok and type(data) == "string" and #data > 0 then
            return data
        end
        if arc == nil then
            local ok2, Archiver = pcall(require, "ffi/archiver")
            if ok2 and Archiver and Archiver.Reader then
                local r = Archiver.Reader:new()
                arc = r:open(doc.file) and r or false
            else
                arc = false
            end
        end
        if arc then
            local ok3, d = pcall(arc.extractToMemory, arc, path)
            if ok3 and type(d) == "string" and #d > 0 then
                return d
            end
        end
        return nil
    end
    local function close()
        if arc then pcall(arc.close, arc) end
        arc = nil
    end
    return read_file, close
end

-- 1-based spine position of the reading position, from the xpointer's
-- DocFragment index (crengine maps spine items to DocFragments in order).
-- Chapter granularity is deliberate: an image in the chapter you are
-- currently reading should be visible.
function ArtGallery:_currentSpineIndex()
    local doc = self.ui.document
    if type(doc.getXPointer) ~= "function" then return nil end
    local ok, xp = pcall(doc.getXPointer, doc)
    if ok and type(xp) == "string" then
        local n = xp:match("DocFragment%[(%d+)%]")
        if n then return tonumber(n) end
    end
    return nil
end

-- Page number of an image's DOM position within the given spine document,
-- used by the "current_page" spoiler scope to hide images after the reading
-- position. Builds the crengine xpointer from the scanner's node_path and
-- asks crengine for the page. Returns nil when it can't be resolved (the
-- caller then falls back to showing the whole current chapter).
function ArtGallery:_imagePage(meta, spine_index)
    local doc = self.ui and self.ui.document
    if not doc or not meta or not meta.node_path then return nil end
    local xp = string.format("/body/DocFragment[%d]/body/%s",
        spine_index, meta.node_path)
    local ok, page = pcall(doc.getPageFromXPointer, doc, xp)
    if ok and type(page) == "number" then return page end
    return nil
end

-- 看图同步阅读进度：在美术馆中浏览到某张图时，把底层书籍的阅读位置推进到
-- 该图对应的位置（漫画场景：看完最后一页漫画，书本身进度也到最后一页）。
-- 分页文档（CBZ/DjVu/PDF）走 ReaderPaging:onGotoPage（页码）；滚动文档
-- （EPUB 等）走 ReaderRolling:onGotoXPointer（xpointer），复用「在书中显示」
-- 的已校验 xpointer 构造。两类各自独立开关（SYNC_PROGRESS_KEY /
-- SYNC_PROGRESS_EPUB_KEY），均默认开。都只在「更靠后」时推进，回看早图不倒退。
-- 翻页/跳转均更新 live 阅读位置并触发自动落盘；关闭书本时 KOReader 的
-- onSaveSettings 据 live 位置写 last_page / last_xpointer，进度才真正持久化。
function ArtGallery:_syncReadingProgress(meta)
    if not meta or type(meta.spine_index) ~= "number" or meta.spine_index < 1 then
        return
    end
    local doc = self.ui and self.ui.document
    if not doc then return end

    -- 注意判别顺序：滚动文档（EPUB）下 self.ui.paging 仍非 nil（ReaderPaging
    -- 同时管理两类文档），故须先判 self.ui.rolling 才能正确分流，否则 EPUB 会被
    -- 错当成分页文档、拿 spine_index 当页码翻页。

    -- 滚动文档：EPUB 等 —— 用 xpointer 同步（独立开关）
    if self.ui.rolling then
        if G_reader_settings:isFalse(SYNC_PROGRESS_EPUB_KEY) then return end
        local rolling = self.ui.rolling
        if type(rolling.onGotoXPointer) ~= "function" then return end
        -- 复用与「在书中显示」相同的已校验 xpointer 构造：拼出精确节点位置，
        -- 校验其 HTML 的确含本图文件名，否则回退到章节开头（DocFragment 顶层）。
        local target = string.format("/body/DocFragment[%d]", meta.spine_index)
        if meta.node_path and doc.isXPointerInDocument then
            local xp = string.format("/body/DocFragment[%d]/body/%s",
                meta.spine_index, meta.node_path)
            local ok = pcall(function() return doc:isXPointerInDocument(xp) end)
                and doc:isXPointerInDocument(xp)
            if ok then
                local fname = meta.path and meta.path:match("[^/]+$")
                local ok2, html = pcall(function()
                    return doc:getHTMLFromXPointer(xp, 0)
                end)
                if ok2 and html and fname and html:find(fname, 1, true) then
                    target = xp
                end
            end
        end
        -- 前向判定：target 落点页码 > 当前页 才推进（回看早图不倒退）
        local okc, cur = pcall(function() return self.ui:getCurrentPage() end)
        if not (okc and type(cur) == "number") then return end
        local okp, tp = pcall(doc.getPageFromXPointer, doc, target)
        if not (okp and type(tp) == "number") then return end
        if tp <= cur then return end
        if pcall(rolling.onGotoXPointer, rolling, target) then
            self._sync_advanced = true
        end
        return
    end

    -- 分页文档：CBZ/DjVu/PDF —— 用页码同步
    if self.ui.paging then
        if G_reader_settings:isFalse(SYNC_PROGRESS_KEY) then return end
        local paging = self.ui.paging
        if type(paging.onGotoPage) ~= "function" then return end
        local ok, cur = pcall(function() return self.ui:getCurrentPage() end)
        if not (ok and type(cur) == "number") then return end
        local target = meta.spine_index
        if target <= cur then return end  -- 只前进不倒退
        if pcall(paging.onGotoPage, paging, target) then
            self._sync_advanced = true
        end
        return
    end
end

-- ── scan + sidecar cache ────────────────────────────────────────────────────

-- 安全落盘：所有 doc_settings / scan 缓存 / 收藏的 flush() 统一走 pcall，
-- 避免在只读挂载（受保护 EPUB、SD 卡锁、掉盘）时 io.open 失败直接抛异常
-- 炸掉调用链（典型：只读书里点「旋转」「忽略图片」即崩）。失败仅记日志。
function ArtGallery:_safeFlush(settings)
    if settings then
        pcall(settings.flush, settings)
    end
end

function ArtGallery:_cachePath()
    -- Live in the book's own sidecar (.sdr) folder, next to KOReader's
    -- metadata, so the scan travels with the book when it's copied between
    -- devices (getSidecarDir honours the user's metadata-location setting:
    -- doc/dir/hash — the cache follows wherever the metadata lives). Older
    -- builds kept a central koreader/artgallery/<key>.lua; those files are now
    -- orphaned and simply re-scanned into the sidecar on next open.
    local dir = DocSettings:getSidecarDir(self.ui.document.file)
    lfs.mkdir(dir)
    return dir .. "/artgallery.scan.lua"
end

-- cache_only: return an in-memory or valid on-disk cached scan (or nil) WITHOUT
-- running a fresh scan. showViewer uses this to open silently on a cache hit,
-- and only put up the "Scanning…" message (a visible e-ink double refresh) when
-- a real scan is actually needed.
function ArtGallery:_getScan(force, cache_only)
    if self._scan and not force then
        return self._scan
    end
    local doc = self.ui.document
    local a = lfs.attributes(doc.file)
    -- record mtime as read here and compare by equality later (never compare
    -- against the cache file's own mtime: clock skew on shared mounts)
    local mtime = a and a.modification or 0
    local size = a and a.size or 0
    local cache = LuaSettings:open(self:_cachePath())

    if not force then
        local c = cache:readSetting("scan")
        if c and c.version == scanner.VERSION
           and cache:readSetting("mtime") == mtime
           and cache:readSetting("size") == size then
            -- 结构完整性校验：缓存文件可能被截断/旧格式，version 虽匹配但
            -- 缺 images 表——宁可当作未命中重新扫描，也不把畸形结构喂给下游。
            if type(c.images) == "table" then
                self._scan = c
                return c
            end
            logger.warn("ArtGallery: cached scan missing 'images', rescanning")
        end
    end
    if cache_only then return nil end

    local read_file, close = self:_makeReader()
    local ok, result, err = pcall(scanner.scan, read_file)
    close()
    if not ok then
        logger.warn("ArtGallery: scan failed:", result)
        self._scan_err = "error"
        return nil
    end
    if not result then
        self._scan_err = err or "error"
        return nil
    end
    self._scan = result
    self._scan_err = nil
    cache:saveSetting("mtime", mtime)
    cache:saveSetting("size", size)
    cache:saveSetting("scan", result)
    self:_safeFlush(cache)
    return result
end

-- 删除本书的图片扫描缓存（位于本书 .sdr 侧边目录下的 artgallery.scan.lua），
-- 并清空内存中的缓存。下次打开本书会自动重新扫描。不影响原始书籍文件，
-- 也不影响收藏。按书籍分别清理——缓存本就随书存储在各自 .sdr 中。
function ArtGallery:_clearBookCache()
    self._scan = nil
    local ok, path = pcall(self._cachePath, self)
    if ok and path then
        os.remove(path)
    end
end

-- ── rendering ───────────────────────────────────────────────────────────────

-- Flatten a rendered image onto opaque white. PNGs (and SVGs) with a
-- transparent background are usually black line art meant to sit on the page;
-- left transparent they vanish in night mode (black lines over the black
-- backdrop) and their anti-aliased edges invert into jaggies. Compositing onto
-- white makes every pixel opaque, so night-mode framebuffer inversion turns it
-- into clean white-on-black. A no-op for images that carry no alpha channel.
local function _flatten_on_white(bb)
    if not bb then return bb end
    local ok, btype = pcall(function() return bb:getType() end)
    if not ok then return bb end
    if btype ~= Blitbuffer.TYPE_BB8A and btype ~= Blitbuffer.TYPE_BBRGB32 then
        return bb  -- no alpha channel, nothing to flatten
    end
    local w, h = bb:getWidth(), bb:getHeight()
    -- opaque target of a matching family (colour stays colour, gray stays gray)
    local out_type = (btype == Blitbuffer.TYPE_BBRGB32)
        and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8
    local flat = Blitbuffer.new(w, h, out_type)
    flat:fill(Blitbuffer.COLOR_WHITE)
    flat:alphablitFrom(bb, 0, 0, 0, 0, w, h)
    bb:free()
    return flat
end

function ArtGallery:_render(read_file, im)
    local data = read_file(im.path)
    if not data and im.raw_path and im.raw_path ~= im.path then
        data = read_file(im.raw_path)
    end
    local bb
    if data then
        if im.format == "svg" or im.is_svg_doc then
            local ok, res = pcall(RenderImage.renderSVGImageDataWithCRengine,
                                  RenderImage, data, #data)
            if ok then bb = res end
        end
        if not bb then
            local ok, res = pcall(RenderImage.renderImageData,
                                  RenderImage, data, #data)
            if ok then bb = res end
        end
    end
    if not bb then
        logger.warn("ArtGallery: could not render image", im.path)
        bb = RenderImage:renderCheckerboard(
            math.floor(Screen:getWidth() / 2),
            math.floor(Screen:getHeight() / 2),
            Screen.bb:getType())
    end
    return _flatten_on_white(bb)
end

-- ── the viewer flow ─────────────────────────────────────────────────────────

-- whole_book_once: bypass the read-so-far scope for this one opening
-- (the empty state's "Search whole book" offer) without touching the
-- user's scope setting.
-- ── 全局收藏（脱离书本可用） ───────────────────────────────────────────────
-- Favorites are stored as COPIES of the image bytes under
-- DataStorage:getDataDir()/artgallery/favorites/, tracked in a LuaSettings file
-- there. Copying (rather than referencing the source archive entry) keeps a
-- favorite readable even after the book is deleted, and avoids shelling out
-- to `cp`/`rm -rf`. The record also keeps width/height/caption so the
-- gallery can show them without reopening the book.

function ArtGallery:_favSettings()
    return LuaSettings:open(DataStorage:getDataDir() .. "/artgallery/favorites.lua")
end

function ArtGallery:_favRecords()
    return self:_favSettings():readSetting("favorites") or {}
end

function ArtGallery:_saveFavRecords(t)
    local s = self:_favSettings()
    s:saveSetting("favorites", t)
    self:_safeFlush(s)
end

function ArtGallery:getFavorites()
    local out = {}
    for _, r in ipairs(self:_favRecords()) do
        if r.file and lfs.attributes(r.file) then
            out[#out + 1] = r
        end
    end
    return out
end

function ArtGallery:isFavoriteByKey(key)
    if not key then return false end
    for _, r in ipairs(self:_favRecords()) do
        if r.key == key then return true end
    end
    return false
end

function ArtGallery:_favFileName(im)
    local book = (self.ui and self.ui.document) and self.ui.document.file or "disk"
    local bbook = (book:match("([^/\\]+)$") or "disk"):gsub("[^%w%.%-]", "_")
    local bentry = ((im.path or "img"):match("([^/\\]+)$") or "img"):gsub("[^%w%.%-]", "_")
    local dir = DataStorage:getDataDir() .. "/artgallery/favorites"
    local cand = bbook .. "_" .. bentry
    local i = 1
    while lfs.attributes(dir .. "/" .. cand) do
        cand = bbook .. "_" .. i .. "_" .. bentry
        i = i + 1
    end
    return cand
end

function ArtGallery:addFavorite(im, viewer)
    local key
    if viewer and viewer.is_cbz and viewer._zip_path then
        key = "cbz:" .. viewer._zip_path .. "#" .. im.path
    elseif self.ui and self.ui.document then
        key = self.ui.document.file .. "#" .. im.path
    else
        UIManager:show(InfoMessage:new{ text = _("无法收藏此图片。") })
        return
    end
    if self:isFavoriteByKey(key) then
        UIManager:show(InfoMessage:new{ text = _("已在收藏中。") })
        return
    end
    local read_file, close = nil, nil
    if viewer and viewer.is_cbz and viewer._zip_path then
        read_file, close = self:_makeZipReader(viewer._zip_path)
    elseif self.ui and self.ui.document then
        read_file, close = self:_makeReader()
    end
    if not read_file then
        UIManager:show(InfoMessage:new{ text = _("无法读取该图片。") })
        return
    end
    local data = read_file(im.path)
    if close then pcall(close) end
    if not data then
        UIManager:show(InfoMessage:new{ text = _("无法读取该图片。") })
        return
    end
    local dir = DataStorage:getDataDir() .. "/artgallery/favorites"
    if not lfs.attributes(dir) then lfs.mkdir(dir) end
    local dest = dir .. "/" .. self:_favFileName(im)
    local f = io.open(dest, "wb")
    if not f then
        UIManager:show(InfoMessage:new{ text = _("无法写入收藏。") })
        return
    end
    if not f:write(data) then
        f:close()
        pcall(os.remove, dest)
        UIManager:show(InfoMessage:new{ text = _("无法写入收藏。") })
        return
    end
    local ok_close = f:close()
    if not ok_close then
        -- 落盘失败（磁盘满/只读）：删掉可能不完整的文件，且不写记录
        pcall(os.remove, dest)
        UIManager:show(InfoMessage:new{ text = _("无法写入收藏。") })
        return
    end
    -- 写入前先剔除已失效（源文件已删除）的收藏记录，避免 favorites.lua 无限增长
    local t = self:_favRecords()
    local live = {}
    for _, r in ipairs(t) do
        if r.file and lfs.attributes(r.file) then
            live[#live + 1] = r
        end
    end
    t = live
    t[#t + 1] = {
        file = dest,
        key = key,
        width = im.width or 0,
        height = im.height or 0,
        caption = im.caption,
    }
    self:_saveFavRecords(t)
    UIManager:show(InfoMessage:new{ text = _("已加入收藏。") })
end

function ArtGallery:removeFavoriteByKey(key)
    local t = self:_favRecords()
    local out = {}
    for _, r in ipairs(t) do
        if r.key == key then
            if r.file then pcall(os.remove, r.file) end
        else
            out[#out + 1] = r
        end
    end
    self:_saveFavRecords(out)
end

function ArtGallery:removeFavoriteByFile(path)
    local t = self:_favRecords()
    local out = {}
    for _, r in ipairs(t) do
        if r.file == path then
            if r.file then pcall(os.remove, r.file) end
        else
            out[#out + 1] = r
        end
    end
    self:_saveFavRecords(out)
end

function ArtGallery:clearFavorites()
    for _, r in ipairs(self:_favRecords()) do
        if r.file then pcall(os.remove, r.file) end
    end
    self:_saveFavRecords({})
end

-- ── 外部画廊（收藏 / CBZ）：不依赖当前书本，从文件管理器也可用 ──────────
function ArtGallery:_makeDiskReader()
    local function read_file(path)
        local f = io.open(path, "rb")
        if not f then return nil end
        local d = f:read("*a")
        f:close()
        return d
    end
    return read_file, function() end
end

function ArtGallery:_makeZipReader(zip_path)
    local ok, Archiver = pcall(require, "ffi/archiver")
    if not (ok and Archiver and Archiver.Reader) then
        return nil, function() end
    end
    local arc = Archiver.Reader:new()
    if not arc:open(zip_path) then
        return nil, function() end
    end
    local function read_file(path)
        local ok2, data = pcall(arc.extractToMemory, arc, path)
        if ok2 and type(data) == "string" and #data > 0 then return data end
        return nil
    end
    local function close()
        pcall(arc.close, arc)
    end
    return read_file, close
end

function ArtGallery:_showExternalGallery(imgs, read_file, close, opts)
    opts = opts or {}
    local cap_w = 2 * math.floor(Screen:getWidth() * ArtGalleryViewer.panel_ratio)
    local cap_h = 2 * Screen:getHeight()
    local function decode(im, hires)
        local bb = self:_render(read_file, im)
        if bb and not hires then
            local w, h = bb:getWidth(), bb:getHeight()
            local s = math.min(1, cap_w / w, cap_h / h)
            if s < 1 then
                local ok_scale, scaled = pcall(RenderImage.scaleBlitBuffer, RenderImage, bb,
                    math.floor(w * s + 0.5), math.floor(h * s + 0.5), true)
                if ok_scale and scaled then bb = scaled end
            end
        end
        local night = Screen.night_mode
        local checked = G_reader_settings:isTrue(INVERT_KEY)
        if bb and night and not checked then
            pcall(bb.invertRect, bb, 0, 0, bb:getWidth(), bb:getHeight())
        end
        return bb
    end
    local function make_list(metas)
        local list = { image_disposable = true }
        for i, im in ipairs(metas) do
            list[i] = function()
                local night = Screen.night_mode
                local checked = G_reader_settings:isTrue(INVERT_KEY)
                local key = im.path .. "|" .. tostring(night) .. tostring(checked)
                local slot = self._bb_cache
                if slot and slot.key == key and slot.bb then
                    return slot.bb:copy()
                end
                local bb = decode(im, false)
                if bb then
                    if slot and slot.bb then slot.bb:free() end
                    self._bb_cache = { key = key, bb = bb:copy() }
                end
                return bb
            end
        end
        return list
    end
    local render = make_list(imgs)
    local viewer
    viewer = ArtGalleryViewer:new{
        image = render,
        image_metas = imgs,
        hires_decode = function(index)
            local im = imgs[index]
            if not im then return nil end
            return decode(im, true)
        end,
        shown_metas = imgs,
        shown_list = render,
        ignored_metas = {},
        ignored_list = { image_disposable = true },
        primary_tab = "shown",
        gallery_hidden_count = 0,
        images_keep_pan_and_zoom = false,
        _suppress_refresh = true,
        artgallery = self,
        is_favorites = opts.is_favorites,
        is_cbz = opts.is_cbz,
        _zip_path = opts.zip_path,
        on_image_shown = function(meta) end,
        on_hide = opts.on_hide or function(meta) end,
        get_pref = function(meta) return {} end,
        set_pref = function(meta, key, value) end,
        on_show_in_book = function(meta) end,
        on_rotate = function(rotation) end,
        on_show_menu = function()
            if self.ui then self.ui:handleEvent(Event:new("ShowMenu")) end
        end,
        scope = "whole_book",
        on_toggle_scope = function() end,
        hidden_count = function() return 0 end,
        on_restore_hidden = function() end,
        on_ignore = function(meta, tab, page) end,
        on_unignore = function(meta, tab, page) end,
        on_external_close = close,
    }
    self._viewer = viewer
    local orig_close = viewer.onCloseWidget
    viewer.onCloseWidget = function(v)
        self._viewer = nil
        if viewer.on_external_close then
            pcall(viewer.on_external_close)
        end
        if orig_close then return orig_close(v) end
    end
    viewer:_enterGallery(1, "shown")
    viewer._suppress_refresh = nil
    viewer.alpha = false
    UIManager:show(viewer)
end

-- ── 旧版 Illustrations 收藏迁移（一次性提示） ──────────────────────────────
-- Illustrations 把收藏以「裸文件」形式存在
--   <cache_dir>/illustrations/Favorites/
-- 其中 cache_dir = DataStorage:getCacheDir() 或 settings_dir 的 /cache 推导。
-- ArtGallery 改用 LuaSettings 索引 + artgallery/favorites/ 字节副本。升级用户首次
-- 打开空收藏时，若检测到旧目录，提供一次性迁移（复制字节 + 登记索引），
-- 原文件保持不变；用户选择「忽略」后用设置键屏蔽，不再打扰。
local LEGACY_MIGRATED_KEY = "artgallery_legacy_fav_migrated"

function ArtGallery:_legacyFavoritesDir()
    local settings_dir = DataStorage:getSettingsDir()
    local cache_dir = (DataStorage.getCacheDir and DataStorage:getCacheDir())
        or settings_dir:gsub("/settings$", "/cache")
    if cache_dir == settings_dir then cache_dir = settings_dir .. "/../cache" end
    return cache_dir .. "/illustrations/Favorites"
end

function ArtGallery:_legacyFavoritesFiles()
    local dir = self:_legacyFavoritesDir()
    if not lfs.attributes(dir) then return nil end
    local files = {}
    for f in lfs.dir(dir) do
        if f ~= "." and f ~= ".." then
            local p = dir .. "/" .. f
            local a = lfs.attributes(p)
            if a and a.mode == "file" then
                local lower = f:lower()
                if lower:match("%.jpe?g$") or lower:match("%.png$")
                   or lower:match("%.gif$") or lower:match("%.webp$")
                   or lower:match("%.svg$") or lower:match("%.bmp$") then
                    files[#files + 1] = f
                end
            end
        end
    end
    if #files == 0 then return nil end
    return files
end

local function _copy_file_bytes(src, dest)
    local f = io.open(src, "rb")
    if not f then return false end
    local d = f:read("*a")
    f:close()
    if not d then return false end
    local g = io.open(dest, "wb")
    if not g then return false end
    g:write(d)
    g:close()
    return true
end

function ArtGallery:_migrateLegacyFavorites(files)
    local src_dir = self:_legacyFavoritesDir()
    local dest_dir = DataStorage:getDataDir() .. "/artgallery/favorites"
    if not lfs.attributes(dest_dir) then lfs.mkdir(dest_dir) end
    local records = self:_favRecords()
    local taken = {}
    for _, r in ipairs(records) do taken[r.key] = true end
    local moved = 0
    for _, f in ipairs(files) do
        local dest = dest_dir .. "/" .. f
        -- 避免覆盖同名文件（不同书可能撞名），追加 _legacyN 后缀
        if lfs.attributes(dest) then
            local base, ext = f:match("^(.*)(%.%w+)$")
            base = base or f
            local i = 1
            repeat
                dest = dest_dir .. "/" .. base .. "_legacy" .. i .. (ext or "")
                i = i + 1
            until not lfs.attributes(dest)
        end
        if _copy_file_bytes(src_dir .. "/" .. f, dest) then
            local key = "legacy:" .. f
            if not taken[key] then
                records[#records + 1] = {
                    file = dest,
                    key = key,
                    width = 0,
                    height = 0,
                    caption = f,
                    legacy = true,
                }
                taken[key] = true
                moved = moved + 1
            end
        end
    end
    self:_saveFavRecords(records)
    return moved
end

function ArtGallery:_offerLegacyMigration(files)
    UIManager:show(ConfirmBox:new{
        text = T(_("发现旧版 Illustrations 插件的收藏（%1 张图片）。是否迁移到 ArtGallery 收藏？"), #files)
            .. "\n\n" .. _("迁移会复制这些图片到 ArtGallery 的收藏目录，原文件保持不变。"),
        ok_text = _("迁移"),
        cancel_text = _("忽略"),
        ok_callback = function()
            G_reader_settings:makeTrue(LEGACY_MIGRATED_KEY)
            local n = self:_migrateLegacyFavorites(files)
            if n > 0 then
                self:showFavorites()
            else
                UIManager:show(InfoMessage:new{ text = _("没有可迁移的收藏。") })
            end
        end,
        cancel_callback = function()
            G_reader_settings:makeTrue(LEGACY_MIGRATED_KEY)
        end,
    })
end

function ArtGallery:showFavorites()
    if self._viewer then self._viewer:onClose(); return end
    local recs = self:getFavorites()
    if #recs == 0 then
        -- 升级自 Illustrations：首次打开空收藏时，若旧目录仍在，提供一次性迁移；
        -- 用户「忽略」后用设置键屏蔽，避免每次打开空收藏都打扰。
        local legacy = self:_legacyFavoritesFiles()
        if legacy and #legacy > 0
           and not G_reader_settings:isTrue(LEGACY_MIGRATED_KEY) then
            self:_offerLegacyMigration(legacy)
            return
        end
        UIManager:show(InfoMessage:new{ text = _("没有收藏。") })
        return
    end
    local imgs = {}
    for _, r in ipairs(recs) do
        imgs[#imgs + 1] = {
            path = r.file,
            width = r.width or 0,
            height = r.height or 0,
            spine_index = 0,
            node_path = nil,
            caption = r.caption,
        }
    end
    local read_file, close = self:_makeDiskReader()
    self:_showExternalGallery(imgs, read_file, close, {
        is_favorites = true,
        on_hide = function(meta) self:removeFavoriteByFile(meta.path) end,
    })
end

function ArtGallery:showCbz(zip_path)
    if self._viewer then self._viewer:onClose(); return end
    local ok, Archiver = pcall(require, "ffi/archiver")
    if not (ok and Archiver and Archiver.Reader) then
        UIManager:show(InfoMessage:new{ text = _("设备不支持打开 CBZ。") })
        return
    end
    local arc = Archiver.Reader:new()
    if not arc:open(zip_path) then
        UIManager:show(InfoMessage:new{ text = _("无法打开 CBZ 文件。") })
        return
    end
    -- CBZ 漫画：每一页都是正文，不应用 relevance 最小尺寸过滤（会让合法页被误删）；
    -- 故直接把全部页面交给画廊，与 EPUB 走 scanner.filter 的路径在此刻意分流。
    local scan = scanner.scan_cbz(arc)
    pcall(arc.close, arc)
    if not scan or not scan.images or #scan.images == 0 then
        UIManager:show(InfoMessage:new{ text = _("此 CBZ 中没有找到图片。") })
        return
    end
    local vreader, vclose = self:_makeZipReader(zip_path)
    self:_showExternalGallery(scan.images, vreader, vclose, {
        is_cbz = true,
        zip_path = zip_path,
    })
end

function ArtGallery:showViewer(whole_book_once)
    -- a second trigger while the drawer is open (the same gesture again,
    -- or the menu entry) toggles it closed instead of stacking viewers
    if self._viewer then
        self._viewer:onClose()
        return
    end
    -- 按书记住的「搜索全书」选择：本次及其后的重开（on_rotate / on_ignore
    -- 等回调再次调用 showViewer 时）都直接以全书范围显示，跳过空状态提示。
    if not whole_book_once and self:_wholeBookRemembered() then
        whole_book_once = true
    end
    local ok, msg = self:_supportedReason()
    if not ok then
        UIManager:show(InfoMessage:new{ text = msg })
        return
    end

    -- Try an in-memory or valid on-disk cached scan silently first: a cache
    -- hit opens with a single refresh. Only a genuine (slow) scan puts up the
    -- "Scanning…" message — whose show+close forceRePaints read as a double
    -- refresh/flash on e-ink, and used to fire on the FIRST open of every book
    -- even when the scan was already cached.
    local scan = self:_getScan(false, true)
    if not scan then
        local info = InfoMessage:new{ text = _("正在扫描书本中的图片…") }
        UIManager:show(info)
        UIManager:forceRePaint()
        scan = self:_getScan()
        UIManager:close(info)
        -- repaint the page below NOW: the viewer is translucent (shadow,
        -- corner notches), and without this the message's outline stays
        -- visible through those areas until the next full repaint
        UIManager:forceRePaint()
    end
    if not scan then
        local why
        if self._scan_err == "no_container" or self._scan_err == "no_opf" then
            why = _("ArtGallery 仅支持 EPUB 格式。")
        else
            why = _("无法扫描此书中的图片。")
        end
        UIManager:show(InfoMessage:new{ text = why })
        return
    end

    local level = self:getFilterLevel()
    local kept_list = scanner.filter(scan.images, level)
    local kept_paths = {}
    for _, im in ipairs(kept_list) do kept_paths[im.path] = true end
    local forced = self:_forcedPaths()
    local hidden = self:_hiddenPaths()

    -- Partition every scanned image (kept in reading order) into the
    -- collection the user sees ("shown") and the pool the Gallery's Ignored
    -- tab offers ("ignored"). Shown = kept by the relevance filter OR
    -- force-added by the user, and not hidden. Ignored = everything else:
    -- images the filter dropped (and the user hasn't re-added) plus images
    -- the user hid. Long-pressing a thumbnail in the Gallery moves an image
    -- between the two (see on_ignore/on_unignore); the paths persist per book.
    local shown_metas, ignored_metas = {}, {}
    for _, im in ipairs(scan.images) do
        local is_shown = (kept_paths[im.path] or forced[im.path])
            and not hidden[im.path]
        if is_shown then
            shown_metas[#shown_metas + 1] = im
        else
            ignored_metas[#ignored_metas + 1] = im
        end
    end

    -- scope: drop images beyond the reading position from BOTH pools (the
    -- Ignored tab respects spoiler scope too). scope_hidden counts what the
    -- chapter scope holds back from the shown collection (gallery heading).
    local scope_hidden = 0
    local scope = self:getScope()
    if scope ~= "whole_book" and not whole_book_once then
        local cur = self:_currentSpineIndex()
        if cur then
            -- "current_page" spoiler mode also hides images in the current
            -- chapter that sit AFTER the reading position: compare each
            -- image's DOM xpointer page to the current one.
            local cur_page
            if scope == "current_page" and self.ui.document then
                local okp, xp = pcall(self.ui.document.getXPointer, self.ui.document)
                if okp and type(xp) == "string" then
                    local ok2, p = pcall(self.ui.document.getPageFromXPointer,
                        self.ui.document, xp)
                    if ok2 and type(p) == "number" then cur_page = p end
                end
            end
            local function clip(list)
                local kept = {}
                for _, im in ipairs(list) do
                    if im.spine_index < cur then
                        kept[#kept + 1] = im
                    elseif im.spine_index == cur then
                        if scope == "read_so_far" then
                            kept[#kept + 1] = im
                        elseif cur_page ~= nil then
                            local ip = self:_imagePage(im, cur)
                            if ip == nil or ip <= cur_page then
                                kept[#kept + 1] = im
                            end
                        else
                            -- can't resolve page: fall back to showing the
                            -- whole current chapter (same as read_so_far)
                            kept[#kept + 1] = im
                        end
                    end
                    -- spine_index > cur → held back (spoiler protection)
                end
                return kept
            end
            local before = #shown_metas
            shown_metas = clip(shown_metas)
            scope_hidden = before - #shown_metas
            ignored_metas = clip(ignored_metas)
        end
    end

    -- The single-image viewer works on the shown collection. When the filter
    -- has left nothing shown but there ARE ignored images, opening is opt-in:
    -- the empty state offers "Review filtered-out", which reopens with the
    -- ignored pool as primary (a long-press reopen — _pending_gallery — does
    -- the same). Otherwise the common decorative-only book (every image
    -- correctly filtered) lands on the plain "No images" state instead of
    -- suddenly displaying its ornaments.
    local want_ignored_primary = self._review_ignored
        or (self._pending_gallery ~= nil)
    local primary_tab = "shown"
    if #shown_metas == 0 and want_ignored_primary and #ignored_metas > 0 then
        primary_tab = "ignored"
    end
    local imgs = (primary_tab == "shown") and shown_metas or ignored_metas

    if #imgs == 0 then
        -- Only offer "Search whole book" when the read-so-far scope is
        -- actually holding images back (scope_hidden > 0) — i.e. the search
        -- WILL return something. Offering it when the whole book has none
        -- (scope_hidden == 0) misleads: it implies images exist, then finds
        -- nothing. In that case just say so plainly.
        if (self:getScope() ~= "whole_book") and not whole_book_once
                and scope_hidden > 0 then
            local msg = scope_hidden == 1
                and _("当前章节之前没有图片——全书还有 1 张。")
                or T(_("当前章节之前没有图片——全书还有 %1 张。"),
                    scope_hidden)
            UIManager:show(ConfirmBox:new{
                text = msg,
                ok_text = _("搜索全书"),
                ok_callback = function()
                    self:_rememberWholeBook()
                    self:showViewer(true)
                end,
            })
        elseif #ignored_metas > 0 then
            -- everything in scope was filtered out (the #4 case): let the
            -- user review and re-add from the Gallery's Ignored tab
            local msg = #ignored_metas == 1
                and _("没有可显示的图片——有 1 张被过滤为不相关。")
                or T(_("没有可显示的图片——有 %1 张被过滤为不相关。"),
                    #ignored_metas)
            UIManager:show(ConfirmBox:new{
                text = msg,
                ok_text = _("查看被过滤的"),
                ok_callback = function()
                    self._review_ignored = true
                    self:showViewer(whole_book_once)
                end,
            })
        else
            UIManager:show(InfoMessage:new{ text = _("没有可显示的图片。") })
        end
        return
    end
    self._review_ignored = nil -- consumed once we're actually opening

    -- lazy render functions: one image decoded at a time, freed on switch;
    -- "invert in night mode" (a global setting) is applied here so
    -- re-renders pick up setting and night-mode changes live.
    -- Night handling (device-agnostic): whenever night mode is on and the
    -- user has NOT ticked "Invert in Night Mode", pre-invert the image pixels
    -- so the screen's own global night inversion brings them back to their
    -- ORIGINAL colours — exactly what KOReader's ImageWidget does for every
    -- image (original_in_nightmode), just baked once here instead of per
    -- paint. Ticking the box skips the pre-invert, so the image ends up
    -- inverted (negative) on screen. Crucially this depends only on the
    -- SAME Screen.night_mode flag ImageWidget keys off (not getInverse() nor
    -- the persisted setting) so our pre-invert is always paired with the
    -- screen's actual inversion state — the old code keyed off getInverse()
    -- and the setting, which could disagree with it and reversed the image on
    -- some devices ("Invert in Night Mode reversed").
    local read_file, close_reader = self:_makeReader()
    -- The RESTING (fit) view decodes each image capped at 2× the drawer's
    -- content box (one C-speed, aspect-preserving downscale): ImageWidget
    -- rescales from the source on EVERY zoom/pan render, so browsing and
    -- swiping off a capped bitmap stays fast even for multi-megapixel maps.
    -- Zooming in past fit trades that for sharpness: ArtGalleryViewer lazily
    -- re-decodes THAT ONE image at full resolution (see _getHiRes /
    -- _new_image_wg), so magnifying shows real detail instead of upscaling
    -- the cap. The capped bitmap is only ever shown at/near fit.
    local cap_w = 2 * math.floor(Screen:getWidth() * ArtGalleryViewer.panel_ratio)
    local cap_h = 2 * Screen:getHeight()
    -- Decode + night/invert-bake one image. hires=false applies the resting
    -- cap; hires=true keeps native resolution. The night baking is identical
    -- both ways, so the sharp copy matches the resting copy where they overlap.
    local function decode(im, hires)
        local night = Screen.night_mode
        local checked = G_reader_settings:isTrue(INVERT_KEY)
        local bb = self:_render(read_file, im)
        if bb and not hires then
            local w, h = bb:getWidth(), bb:getHeight()
            local s = math.min(1, cap_w / w, cap_h / h)
            if s < 1 then
                local ok_scale, scaled = pcall(RenderImage.scaleBlitBuffer, RenderImage, bb,
                    math.floor(w * s + 0.5), math.floor(h * s + 0.5), true)
                if ok_scale and scaled then bb = scaled end
            end
        end
        -- pre-invert so the screen's night inversion restores the original,
        -- unless the user asked for an inverted (negative) image
        if bb and night and not checked then
            pcall(bb.invertRect, bb, 0, 0, bb:getWidth(), bb:getHeight())
        end
        return bb
    end
    -- Build a lazy render-closure list (parallel to a metas list) — one for
    -- the shown collection, one for the ignored pool (the Gallery tabs). Both
    -- share the single-slot decoded-bitmap cache below, keyed by path, so a
    -- thumbnail and the full view of the same image hit the same slot.
    local function make_list(metas)
        local list = { image_disposable = true }
        for i, im in ipairs(metas) do
            list[i] = function()
                local night = Screen.night_mode
                local checked = G_reader_settings:isTrue(INVERT_KEY)
                -- single-slot decoded-bitmap cache: reopening on the image
                -- you left (the common "peek at the map again" flow) skips
                -- the decode and cap-scale — on device that is most of the
                -- open time. The key bakes in everything baked into pixels.
                local key = im.path .. "|" .. tostring(night) .. tostring(checked)
                local slot = self._bb_cache
                if slot and slot.key == key and slot.bb then
                    -- hand out a copy: the viewer owns and frees what we return
                    return slot.bb:copy()
                end
                local bb = decode(im, false)
                if bb then
                    if slot and slot.bb then slot.bb:free() end
                    self._bb_cache = { key = key, bb = bb:copy() }
                end
                return bb
            end
        end
        return list
    end
    local shown_render = make_list(shown_metas)
    local ignored_render = make_list(ignored_metas)
    local images_list = (primary_tab == "shown") and shown_render or ignored_render
    -- Full-resolution decode for the zoomed view, called on demand by the
    -- viewer (one image at a time). read_file stays valid after close_reader()
    -- — it just reopens the libarchive fallback if the primary path misses.
    local hires_decode = function(index)
        local im = imgs[index]
        if not im then return nil end
        return decode(im, true)
    end

    -- reopen on the image viewed last time (per book), if still in the list
    local start = 1
    local last = self.ui.doc_settings:readSetting("artgallery_last")
    if last then
        for i, im in ipairs(imgs) do
            if im.path == last then
                start = i
                break
            end
        end
    end

    -- effective scope of THIS opening: whole_book_once (the empty-state
    -- "search whole book" path) shows everything even while the setting
    -- stays read_so_far, so the viewer's scope label must reflect that.
    local s = self:getScope()
    local effective_scope = (s ~= "whole_book" and not whole_book_once)
        and s or "whole_book"

    local viewer
    local first_shown = true  -- 跳过「刚打开」这次，避免一开就跳进度
    viewer = ArtGalleryViewer:new{
        image = images_list,
        image_metas = imgs,
        -- lazily supplies the full-res decode of the zoomed image (sharp zoom)
        hires_decode = hires_decode,
        -- Gallery tabs: the two pools, independent of which one is primary
        -- (the single-image view uses `image`/`image_metas` = the primary).
        shown_metas = shown_metas,
        shown_list = shown_render,
        ignored_metas = ignored_metas,
        ignored_list = ignored_render,
        primary_tab = primary_tab,
        -- for the gallery heading: images the chapter scope holds back
        gallery_hidden_count = scope_hidden,
        images_keep_pan_and_zoom = false,
        artgallery = self,
        -- hold refreshes until the initial state is fully built (see below)
        _suppress_refresh = true,
        on_image_shown = function(meta)
            self.ui.doc_settings:saveSetting("artgallery_last", meta.path)
            -- 看图同步阅读进度：跳过「刚打开」这一次（避免一开就跳进度），
            -- 仅在实际翻到新图时推进底层书籍阅读位置（漫画场景必需）。
            if first_shown then
                first_shown = false
                return
            end
            self:_syncReadingProgress(meta)
        end,
        on_hide = function(meta)
            local h = self:_hiddenPaths()
            h[meta.path] = true
            self.ui.doc_settings:saveSetting("artgallery_hidden", h)
        end,
        get_pref = function(meta)
            return self:_imgPrefs()[meta.path] or {}
        end,
        set_pref = function(meta, key, value)
            self:_setImgPref(meta.path, key, value)
        end,
        on_show_in_book = function(meta)
            if not meta.spine_index or not self.ui.rolling then return end
            if self.ui.link then
                self.ui.link:addCurrentLocationToStack()
            end
            -- Chapter-level target is always available; try to refine it to
            -- the exact image first. The scanner's node_path is derived from
            -- raw HTML, so crengine's normalized DOM can disagree — validate
            -- the built xpointer resolves to THIS image (its filename appears
            -- in the element's HTML) before trusting it, else fall back to the
            -- chapter top (the pre-fix behaviour).
            local target = string.format("/body/DocFragment[%d]", meta.spine_index)
            local doc = self.ui.document
            if meta.node_path and doc and doc.isXPointerInDocument then
                local xp = string.format("/body/DocFragment[%d]/body/%s",
                    meta.spine_index, meta.node_path)
                local ok = pcall(function() return doc:isXPointerInDocument(xp) end)
                    and doc:isXPointerInDocument(xp)
                if ok then
                    local fname = meta.path and meta.path:match("[^/]+$")
                    local ok2, html = pcall(function()
                        return doc:getHTMLFromXPointer(xp, 0)
                    end)
                    if ok2 and html and fname
                            and html:find(fname, 1, true) then
                        target = xp
                    end
                end
            end
            self.ui.rolling:onGotoXPointer(target)
        end,
        -- the viewer closed itself on a G-sensor rotation: re-layout the
        -- reader, then reopen (zoom/pan persistence restores the view)
        on_rotate = function(rotation)
            self.ui.view:onSetRotationMode(rotation)
            self:showViewer(whole_book_once)
        end,
        -- a tap in KOReader's top-menu zone opens ONLY the top menu, over
        -- the still-open drawer (ShowMenu, not onTapShowMenu, so the
        -- bottom config menu never tags along regardless of show_bottom_menu)
        on_show_menu = function()
            self.ui:handleEvent(Event:new("ShowMenu"))
        end,
        scope = effective_scope,
        -- ⋯ → "Showing: …": flip the persistent scope to the opposite of
        -- what's on screen, then close and reopen so the image list rebuilds
        -- (onClose runs onCloseWidget synchronously, clearing self._viewer,
        -- so showViewer opens fresh rather than toggling itself shut).
        -- artgallery_last lands us on the same image when it's still in scope.
        on_toggle_scope = function()
            -- cycle: whole_book → read_so_far → current_page → whole_book
            local order = { whole_book = "read_so_far",
                            read_so_far = "current_page",
                            current_page = "whole_book" }
            local new_scope = order[effective_scope] or "whole_book"
            G_reader_settings:saveSetting(SCOPE_KEY, new_scope)
            self:_forgetWholeBook()
            if self._viewer then self._viewer:onClose() end
            self:showViewer()
            -- name the mode the user just switched to (Quick Actions ⋯ row)
            local label = new_scope == "whole_book"
                and _("模式：所有图片")
                or new_scope == "read_so_far"
                and _("模式：仅当前章节之前")
                or _("模式：仅显示已读到的图片")
            UIManager:show(Notification:new{ text = label })
        end,
        -- ⋯ → Restore hidden images (only offered when some are hidden):
        -- clear the per-book hide list, then close+reopen so they return.
        hidden_count = function() return self:_hiddenCount() end,
        on_restore_hidden = function()
            self.ui.doc_settings:delSetting("artgallery_hidden")
            if self._viewer then self._viewer:onClose() end
            self:showViewer()
        end,
        -- Gallery long-press, Shown tab: move this image to Ignored (hide it
        -- and drop any force-add). Persist, then reopen back into the Gallery
        -- on the same tab/page (the scan is cached, so the reopen is cheap).
        on_ignore = function(meta, tab, page)
            local h = self:_hiddenPaths(); h[meta.path] = true
            local f = self:_forcedPaths(); f[meta.path] = nil
            self.ui.doc_settings:saveSetting("artgallery_hidden", h)
            self.ui.doc_settings:saveSetting("artgallery_forced", next(f) and f or nil)
            self:_safeFlush(self.ui.doc_settings)
            self._pending_gallery = { tab = tab, page = page }
            if self._viewer then self._viewer:onClose() end
            self:showViewer(whole_book_once)
            UIManager:show(Notification:new{ text = _("已移动到忽略列表") })
        end,
        -- Gallery long-press, Ignored tab: add this image back to Shown
        -- (force-include it and clear any hide). Same reopen-into-gallery.
        on_unignore = function(meta, tab, page)
            local f = self:_forcedPaths(); f[meta.path] = true
            local h = self:_hiddenPaths(); h[meta.path] = nil
            self.ui.doc_settings:saveSetting("artgallery_forced", f)
            self.ui.doc_settings:saveSetting("artgallery_hidden", next(h) and h or nil)
            self:_safeFlush(self.ui.doc_settings)
            self._pending_gallery = { tab = tab, page = page }
            if self._viewer then self._viewer:onClose() end
            self:showViewer(whole_book_once)
            UIManager:show(Notification:new{ text = _("已添加回图库") })
        end,
    }
    self._viewer = viewer
    -- release the fallback archive handle together with the viewer; also
    -- remember the view as it was left (zoom level and pan position of
    -- the image on display) so reopening puts the user right back there.
    -- At fit the entry is cleared — the image itself is already restored
    -- via artgallery_last.
    local orig_close_widget = viewer.onCloseWidget
    viewer.onCloseWidget = function(v)
        local meta = v.image_metas and v.image_metas[v._images_list_cur or 1]
        local view
        if meta and v.scale_factor ~= 0 then
            view = {
                path = meta.path,
                scale = v.scale_factor,
                cx = v._center_x_ratio,
                cy = v._center_y_ratio,
            }
        end
        self.ui.doc_settings:saveSetting("artgallery_view", view)
        self._viewer = nil
        -- 看图期间若推进了书籍阅读进度（漫画翻页），关闭画廊时立即落盘，
        -- 以免 KOReader 在关书前被杀导致进度未保存（onGotoPage 已触发自动落盘，
        -- 此处仅作双保险）。
        if self._sync_advanced then
            self._sync_advanced = nil
            pcall(function() self.ui:saveSettings() end)
        end
        close_reader()
        return orig_close_widget(v)
    end

    -- Build the complete initial state (remembered image, restored zoom)
    -- BEFORE showing: every update() is otherwise its own e-ink refresh,
    -- making the drawer visibly repaint up to three times on open.
    if start > 1 then
        viewer:switchToImageNum(start)
    end
    self.ui.doc_settings:saveSetting("artgallery_last", imgs[start].path)
    local view = self.ui.doc_settings:readSetting("artgallery_view")
    if view and view.path == imgs[start].path
            and type(view.scale) == "number" and view.scale ~= 0 then
        viewer.scale_factor = view.scale
        viewer._center_x_ratio = view.cx or 0.5
        viewer._center_y_ratio = view.cy or 0.5
        viewer:update()
    end
    -- Land directly in the Gallery when this open is a long-press move
    -- reopen (return to the tab/page the user was on) or the "Review
    -- filtered-out" path (open on the Ignored tab). Done before the first
    -- show so it paints as the gallery, not a flash from single view.
    if self._pending_gallery then
        local pg = self._pending_gallery
        self._pending_gallery = nil
        local tab = pg.tab
        -- if the tab we were on emptied out (moved its last image), show
        -- the other one instead of a blank grid
        local n = (tab == "ignored") and #ignored_metas or #shown_metas
        if n == 0 then tab = (tab == "ignored") and "shown" or "ignored" end
        viewer:_enterGallery(pg.page, tab)
    elseif primary_tab == "ignored" then
        -- opened via "Review filtered-out": land in the Ignored grid
        viewer:_enterGallery(1, "ignored")
    end
    viewer._suppress_refresh = nil
    -- The framebuffer already shows the page exactly as-is, so skip the
    -- numeric-alpha below-repaint on open (a full crengine redraw — and
    -- a full-screen per-pixel Lua blit on SW-invert night devices): the
    -- shadow blends over the live fb instead. If a below repaint IS
    -- already queued (menu close, rotation, ConfirmBox), stack order
    -- still paints it before us, so the blend stays accumulation-free.
    -- false, not nil: nil falls back to the class alpha via the metatable.
    viewer.alpha = false
    -- one dithered refresh covering the drawer (plus its gradient shadow when
    -- the shadow is on — it falls onto the page). With the shadow OFF, refresh
    -- ONLY the drawer, so the book area to its right is never in the region:
    -- otherwise KOReader's periodic promotion of this refresh to a flashing
    -- full flashes the page black even though nothing there changed.
    local open_w = viewer._panel_w + 2
    if not G_reader_settings:isTrue(SHADOW_KEY) then
        open_w = viewer._panel_w
            + 2 * viewer.shadow_width - viewer.shadow_overlap + 1
    end
    -- Refresh isolation: ArtGallery lives in its own refresh world. Snapshot the
    -- reader's ghost-clear counter and reset it to 0 for the session, so the
    -- reader's accumulated count can't promote a ArtGallery refresh into a
    -- full-screen flash, and ArtGallery's own refreshes don't push the reader
    -- toward its periodic flash. The count is restored on close (onCloseWidget).
    viewer._reader_refresh_count = UIManager.refresh_count
    UIManager.refresh_count = 0
    UIManager:show(viewer, Device:hasKaleidoWfm() and "partial" or "ui",
        Geom:new{
            x = 0, y = 0,
            w = math.min(Screen:getWidth(), open_w),
            h = Screen:getHeight(),
        }, nil, nil, true)
    viewer.alpha = nil -- back to the class default for later paths
end

-- ── GitHub auto-update ──────────────────────────────────────────────────────
-- Ported from Footcream. Checks the repo's releases, downloads the attached
-- .zip and installs it over this plugin folder (with backup + rollback).
-- Additions over Footcream:
--   * optional GitHub token (GH_TOKEN_KEY): lets the updater read a PRIVATE
--     repo — release info via the API, assets via the API asset URL with
--     Accept: application/octet-stream. The Authorization header is only
--     ever sent to api.github.com — GitHub's CDN rejects requests that
--     carry both auth and the signed redirect URL.
--   * pre-release channel (PRERELEASE_KEY): /releases/latest NEVER returns
--     releases marked "pre-release", so those form a test channel invisible
--     to normal update checks; the toggle opts this device in.
local GH_TOKEN_KEY = "artgallery_github_token"
local PRERELEASE_KEY = "artgallery_update_prerelease"

local function _installed_version()
    local ok, meta = pcall(dofile, _PLUGIN_DIR .. "/_meta.lua")
    if ok and type(meta) == "table" and meta.version then
        return tostring(meta.version)
    end
    return "0"
end

-- "v1.2" / "1.2.0" → {1,2,(0)}; numeric, dot-separated, leading v optional.
local function _parse_ver(s)
    local t = {}
    for n in tostring(s):gsub("^[vV]", ""):gmatch("%d+") do
        t[#t + 1] = tonumber(n)
    end
    return t
end

local function _ver_gt(a, b) -- is version a strictly newer than b?
    local va, vb = _parse_ver(a), _parse_ver(b)
    for i = 1, math.max(#va, #vb) do
        local x, y = va[i] or 0, vb[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

local function _json_decode(s)
    local ok, rj = pcall(require, "rapidjson")
    if ok and rj and rj.decode then
        local ok2, t = pcall(rj.decode, s)
        if ok2 then return t end
    end
    local ok3, J = pcall(require, "json") -- fallback if rapidjson is missing
    if ok3 and J and J.decode then
        local ok4, t = pcall(J.decode, s)
        if ok4 then return t end
    end
    return nil
end

local function _file_exists(path)
    local f = io.open(path)
    if f then f:close() return true end
    return false
end

-- HTTPS GET. With dest_path, streams the body to that file (for the zip);
-- otherwise returns the body string. Follows redirects manually (GitHub
-- asset URLs 302 to a CDN host, which luasec won't re-handshake for).
local function _http_fetch(url, dest_path, accept, depth)
    depth = depth or 0
    if depth > 6 then return nil, "too many redirects" end
    local ltn12      = require("ltn12")
    local socketutil = require("socketutil")
    local socket_url = require("socket.url")
    local requester  = url:match("^https:") and require("ssl.https")
                                             or require("socket.http")

    local body, fh, sink = {}, nil, nil
    if dest_path then
        fh = io.open(dest_path, "wb")
        if not fh then return nil, "cannot write " .. dest_path end
        sink = ltn12.sink.file(fh)
    else
        sink = ltn12.sink.table(body)
    end

    local headers = { ["User-Agent"] = "artgallery-updater" }
    if accept then headers["Accept"] = accept end
    local token = G_reader_settings:readSetting(GH_TOKEN_KEY)
    if token and token ~= "" and url:match("^https://api%.github%.com/") then
        headers["Authorization"] = "token " .. token
    end

    -- KOReader's standard short timeouts (10s/op, 30s total): socketutil
    -- has globally overridden socket.tcp, so these bound connect/read.
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT,
        socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, code, resp_headers = requester.request{
        url      = url,
        method   = "GET",
        headers  = headers,
        sink     = sink,
        redirect = false, -- handled below
    }
    socketutil:reset_timeout()

    if not ok then
        local msg = tostring(code)
        if msg:find("host or service", 1, true)
           or msg:find("not known", 1, true) then
            msg = "couldn't reach GitHub (network/DNS) — check WiFi and try again"
        end
        return nil, "network error: " .. msg
    end
    code = tonumber(code)
    if code and code >= 300 and code < 400 then
        local loc = resp_headers and (resp_headers.location or resp_headers.Location)
        if not loc then return nil, "redirect without Location" end
        return _http_fetch(socket_url.absolute(url, loc), dest_path, accept, depth + 1)
    end
    if not code or code >= 400 then return nil, "HTTP " .. tostring(code) end
    if dest_path then return true end
    return table.concat(body)
end

-- After unzipping, find the directory that holds both main.lua and
-- _meta.lua, wherever it sits in the archive (asset-zip root,
-- "artgallery.koplugin/", or a source zip's "<repo>-<tag>/plugin/").
local function _find_plugin_root(dir)
    local p = io.popen('find "' .. dir .. '" -name main.lua 2>/dev/null')
    if not p then return nil end
    for line in p:lines() do
        local d = line:match("^(.*)/[^/]*$")
        local mf = d and io.open(d .. "/_meta.lua")
        if mf then mf:close() p:close() return d end
    end
    p:close()
    return nil
end

function ArtGallery._confirm(text, ok_text, ok_callback, cancel_text)
    -- Headless test driver: accept every confirmation without showing the
    -- dialog. Set only by VM verification runs — never exists on a device.
    if os.getenv("GLIMPSE_AUTOCONFIRM") == "1" then
        logger.info("ArtGallery: auto-confirmed — " .. (ok_text or "?"))
        ok_callback()
        return
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title       = text,
        title_align = "left",
        buttons = {{
            {
                text = cancel_text or _("取消"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = ok_text,
                callback = function()
                    UIManager:close(dialog)
                    ok_callback()
                end,
            },
        }},
    }
    UIManager:show(dialog)
end

-- Entry point (menu callback): ensure we're online, then check releases.
-- Wrapped in Trapper so the network wait shows a dismissable spinner.
function ArtGallery:_checkForUpdate()
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local Trapper = require("ui/trapper")
        Trapper:wrap(function() self:_runUpdateCheck(Trapper) end)
    end)
end

function ArtGallery:_runUpdateCheck(Trapper)
    local pre = G_reader_settings:isTrue(PRERELEASE_KEY)
    local api = "https://api.github.com/repos/" .. self.github_repo
        .. (pre and "/releases?per_page=10" or "/releases/latest")
    -- fetch in a subprocess so the UI stays responsive and dismissable
    local completed, body = Trapper:dismissableRunInSubprocess(function()
        local b, err = _http_fetch(api)
        return b or ("ERR:" .. tostring(err))
    end, _("正在检查更新…"), true)
    if not completed then return end -- dismissed by the user
    if not body or body:match("^ERR:") then
        UIManager:show(InfoMessage:new{
            text = _("更新检查失败：") .. "\n"
                .. ((body or "无响应"):gsub("^ERR:", "")) })
        return
    end
    local rel
    if pre then
        -- the release LIST includes pre-releases; take the newest non-draft
        local list = _json_decode(body)
        if type(list) == "table" then
            for _, r in ipairs(list) do
                if type(r) == "table" and not r.draft then
                    rel = r
                    break
                end
            end
        end
    else
        rel = _json_decode(body)
    end
    if not rel or not rel.tag_name then
        UIManager:show(InfoMessage:new{
            text = _("无法读取最新的发布信息。") })
        return
    end
    local installed = _installed_version()
    if not _ver_gt(rel.tag_name, installed) then
        UIManager:show(InfoMessage:new{
            text = T(_("您已是最新版本 (v%1)。"), installed) })
        return
    end
    -- prefer an attached .zip asset; private repos must download it through
    -- the API asset URL (browser_download_url needs a browser session)
    local browser_url, api_asset_url
    for _, a in ipairs(rel.assets or {}) do
        if a.name and a.name:match("%.zip$") then
            browser_url = a.browser_download_url
            api_asset_url = a.url
            break
        end
    end
    local token = G_reader_settings:readSetting(GH_TOKEN_KEY)
    local dl_url, dl_accept
    if api_asset_url and token and token ~= "" then
        dl_url, dl_accept = api_asset_url, "application/octet-stream"
    else
        dl_url = browser_url or rel.zipball_url
    end
    if not dl_url then
        UIManager:show(InfoMessage:new{
            text = _("没有找到可下载的发布包。") })
        return
    end
    local label = rel.tag_name .. (rel.prerelease and " (预发布)" or "")
    ArtGallery._confirm(
        T(_("发现更新：%1\n(当前版本：v%2)\n\n现在下载安装吗？"),
            label, installed),
        _("更新"), function()
            local Trapper2 = require("ui/trapper")
            Trapper2:wrap(function()
                self:_installUpdate(Trapper2, dl_url, dl_accept, rel.tag_name)
            end)
        end)
end

function ArtGallery:_installUpdate(Trapper, dl_url, dl_accept, tag)
    local base = DataStorage:getDataDir() .. "/artgallery"
    lfs.mkdir(base)
    local tmp_zip    = base .. "/update.zip"
    local tmp_dir    = base .. "/update"
    local plugin_dir = _PLUGIN_DIR
    local backup     = plugin_dir .. ".bak"

    -- download → unzip → install in ONE subprocess so the UI never freezes
    -- and the message stays dismissable; returns "OK" or "ERR:<reason>".
    -- (No UIManager use inside — not allowed in the subprocess.)
    local completed, result = Trapper:dismissableRunInSubprocess(function()
        os.execute('rm -rf "' .. tmp_dir .. '" "' .. tmp_zip .. '" "' .. backup .. '"')
        local ok, err = _http_fetch(dl_url, tmp_zip, dl_accept)
        if not ok then return "ERR:下载失败: " .. tostring(err) end
        os.execute('mkdir -p "' .. tmp_dir .. '"')
        os.execute('unzip -o "' .. tmp_zip .. '" -d "' .. tmp_dir .. '" >/dev/null 2>&1')
        local src = _find_plugin_root(tmp_dir)
        if not src then return "ERR:更新包中未包含插件文件。" end
        os.execute('cp -rf "' .. plugin_dir .. '" "' .. backup .. '"')
        os.execute('cp -rf "' .. src .. '/." "' .. plugin_dir .. '/"')
        if not _file_exists(plugin_dir .. "/main.lua") then
            os.execute('rm -rf "' .. plugin_dir .. '" && mv "' .. backup .. '" "' .. plugin_dir .. '"')
            os.execute('rm -rf "' .. tmp_dir .. '" "' .. tmp_zip .. '"')
            return "ERR:安装失败 — 已恢复之前的版本。"
        end
        os.execute('rm -rf "' .. backup .. '" "' .. tmp_dir .. '" "' .. tmp_zip .. '"')
        return "OK"
    end, T(_("正在更新到 %1…"), tag), true)

    if not completed then
        -- dismissed → the subprocess was SIGKILLed; if it died mid-copy,
        -- restore from the backup so we never leave a broken plugin
        if _file_exists(backup .. "/main.lua")
           and not _file_exists(plugin_dir .. "/main.lua") then
            os.execute('rm -rf "' .. plugin_dir .. '" && mv "' .. backup .. '" "' .. plugin_dir .. '"')
        end
        os.execute('rm -rf "' .. backup .. '" "' .. tmp_dir .. '" "' .. tmp_zip .. '"')
        return
    end
    if result == "OK" then
        ArtGallery._confirm(
            T(_("已更新到 %1。\n现在重启 KOReader 以加载新版本？"), tag),
            _("重启"), function() UIManager:restartKOReader() end,
            _("稍后"))
    else
        UIManager:show(InfoMessage:new{
            text = (type(result) == "string" and result:gsub("^ERR:", ""))
                or _("更新失败。") })
    end
end

-- ── menu ────────────────────────────────────────────────────────────────────

function ArtGallery:addToMainMenu(menu_items, file)
    self._menu_file = file -- FileManager passes the selected file; nil in Reader
    menu_items.artgallery = {
        text = _("美术馆"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:_menuItems()
        end,
    }
end

-- Which gesture (if any) currently triggers ArtGallery in this context —
-- read from the gestures plugin's live table for the current mode
-- (reader vs file manager). Keys are prettified ("hold_top_left_corner"
-- → "Hold top left corner"); the friendly-name table is a local of the
-- gestures plugin and not reachable.
-- Is any gesture in the current context bound to open ArtGallery? Used to
-- gate the one-time "bind a gesture" nudge (no point nagging someone who
-- already has one).
function ArtGallery:_hasGesture()
    local g = self.ui and self.ui.gestures
    if g and type(g.gestures) == "table" then
        for _, actions in pairs(g.gestures) do
            if type(actions) == "table" and actions.artgallery_show then
                return true
            end
        end
    end
    return false
end

function ArtGallery:_gestureLabel()
    local g = self.ui and self.ui.gestures
    local found = {}
    if g and type(g.gestures) == "table" then
        for ges, actions in pairs(g.gestures) do
            if type(actions) == "table" and actions.artgallery_show then
                found[#found + 1] = ges
            end
        end
    end
    if #found == 0 then return _("手势：未设置") end
    table.sort(found)
    for i, ges in ipairs(found) do
        found[i] = ges:gsub("_", " "):gsub("^%l", string.upper)
    end
    return T(_("手势：%1"), table.concat(found, ", "))
end

function ArtGallery:_menuItems()
    local function scope_item(value, text, help)
        return {
            text = text,
            help_text = help,
            radio = true,
            checked_func = function() return self:getScope() == value end,
            callback = function()
                G_reader_settings:saveSetting(SCOPE_KEY, value)
                self:_forgetWholeBook()
            end,
        }
    end
    return {
        {
            -- which gesture opens ArtGallery here; tap for the how-to (KOReader
            -- has no API to deep-link the gesture manager, so we spell out
            -- the path). This is the plugin's main onboarding affordance —
            -- one-touch access is the whole point — so it's an action, not a
            -- dimmed label.
            text_func = function() return self:_gestureLabel() end,
            keep_menu_open = true,
            help_text = _("在「点按与手势」→「手势管理」中分配或更改手势。"),
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = _("要使用单手势打开美术馆：\n\n设置 → 点按与手势 → 手势管理 → 选择手势 → 阅读器 →「打开美术馆」。"),
                })
            end,
        },
        {
            text = _("打开美术馆"),
            help_text = _("浏览本书中的地图、族谱和其他参考图片，而不丢失阅读位置。提示：绑定「打开美术馆」手势实现一键访问。"),
            -- greyed out with no book open (e.g. from the file manager)
            enabled_func = function() return self.ui and self.ui.document ~= nil end,
            callback = function(touchmenu_instance)
                if touchmenu_instance then
                    touchmenu_instance:closeMenu()
                end
                local ag_doc = self.ui and self.ui.document
                local ag_file = ag_doc and ag_doc.file
                -- let the menu-close animation finish, or the page repaint
                -- lands on top of the viewer
                UIManager:scheduleIn(0.3, function()
                    -- 0.3s 内若书籍已关闭/切换，self.ui.document 已变——绝不对
                    -- 新文档或空文档打开查看器，避免串档或空文档崩溃。
                    if not (self.ui and self.ui.document == ag_doc
                            and self.ui.document.file == ag_file) then
                        return
                    end
                    self:showViewer()
                    -- first menu-open without a gesture bound: nudge once,
                    -- on top of the now-open drawer (gated on the viewer
                    -- actually opening, so unsupported/empty books don't tip)
                    if self._viewer and not self:_hasGesture()
                            and not G_reader_settings:isTrue(GESTURE_TIP_KEY) then
                        G_reader_settings:saveSetting(GESTURE_TIP_KEY, true)
                        UIManager:show(InfoMessage:new{
                            text = _("提示：使用手势即时打开美术馆。\n\n在「设置 → 点按与手势 → 手势管理」中设置 — 选择手势 → 阅读器 →「打开美术馆」。\n\n（此提示仅显示一次。）"),
                        })
                    end
                end)
            end,
        },
        {
            -- the full option name, not an abbreviation, so the current
            -- mode is unambiguous at a glance
            text_func = function()
                local s = self:getScope()
                return s == "whole_book"
                    and _("模式：显示所有图片")
                    or s == "current_page"
                    and _("模式：仅显示已读到的图片")
                    or _("模式：仅显示当前章节前的图片")
            end,
            sub_item_table = {
                scope_item("read_so_far", _("仅显示当前章节前的图片"),
                    _("超出当前位置的图片保持隐藏，避免剧透。粒度以章节为单位：当前阅读的章节中的图片会显示。")),
                scope_item("current_page", _("仅显示已读到的图片"),
                    _("剧透保护：仅显示已经读到的位置之前的图片，当前章节中尚未翻到的图片也会被隐藏。")),
                scope_item("whole_book", _("显示所有图片"),
                    _("显示书中任何位置的参考图片，包括尚未读到的部分。")),
            },
            separator = true,
        },
        {
            text = _("夜间模式反转图片"),
            help_text = _("当 KOReader 夜间模式启用时，图片显示为亮色线条在深色背景上。也可在查看器的 ⋯ 菜单中切换。"),
            checked_func = function()
                return G_reader_settings:isTrue(INVERT_KEY)
            end,
            callback = function()
                G_reader_settings:saveSetting(INVERT_KEY,
                    not G_reader_settings:isTrue(INVERT_KEY))
            end,
        },
        {
            text = _("显示导航按钮"),
            help_text = _("在查看器中显示 ‹ 和 › 按钮用于切换图片，作为滑动操作的替代。到达两端时按钮会变灰。"),
            checked_func = function()
                return G_reader_settings:isTrue(NAV_BUTTONS_KEY)
            end,
            callback = function()
                G_reader_settings:saveSetting(NAV_BUTTONS_KEY,
                    not G_reader_settings:isTrue(NAV_BUTTONS_KEY))
            end,
        },
        {
            text = _("看图同步阅读进度（分页文档）"),
            help_text = _("在美术馆中浏览分页文档（如 CBZ 漫画）的图片时，把书籍本身的阅读进度同步推进到对应页面，避免看完漫画后书本仍停在第一页。"),
            checked_func = function()
                return not G_reader_settings:isFalse(SYNC_PROGRESS_KEY)
            end,
            callback = function()
                G_reader_settings:saveSetting(SYNC_PROGRESS_KEY,
                    G_reader_settings:isFalse(SYNC_PROGRESS_KEY))
            end,
        },
        {
            text = _("看图同步阅读进度（EPUB）"),
            help_text = _("在美术馆中浏览滚动文档（EPUB 漫画）的图片时，把书籍本身的阅读进度同步推进到对应图片位置，避免看完漫画后书本仍停在第一页。普通带插图的文字书若因此被错误跳进度，可单独关闭本项。"),
            checked_func = function()
                return not G_reader_settings:isFalse(SYNC_PROGRESS_EPUB_KEY)
            end,
            callback = function()
                G_reader_settings:saveSetting(SYNC_PROGRESS_EPUB_KEY,
                    G_reader_settings:isFalse(SYNC_PROGRESS_EPUB_KEY))
            end,
        },
        {
            text = _("快速操作"),
            help_text = _("选择查看器的 ⋯ 菜单中显示哪些操作。重置旋转在图片旋转后自动显示，恢复忽略仅在有忽略图片时出现。"),
            sub_item_table = (function()
                local t = {}
                for _, d in ipairs(QUICK_ACTIONS) do
                    local key = d.key
                    t[#t + 1] = {
                        text = _quick_label(key),
                        checked_func = function() return _quick_enabled(key) end,
                        keep_menu_open = true,
                        callback = function()
                            local cfg = G_reader_settings:readSetting(QUICK_ACTIONS_KEY)
                            if type(cfg) ~= "table" then cfg = {} end
                            cfg[key] = not _quick_enabled(key)
                            G_reader_settings:saveSetting(QUICK_ACTIONS_KEY, cfg)
                        end,
                    }
                end
                return t
            end)(),
        },
        {
            text_func = function()
                local n = self:_hiddenCount()
                if n > 0 then
                    return T(_("恢复被忽略的图片 (%1)"), n)
                end
                return _("恢复被忽略的图片")
            end,
            help_text = _("恢复您通过查看器 ⋯ 菜单（或在图库中长按）忽略的图片。按书籍记忆。被相关性过滤移除的图片可通过图库的「已忽略」选项卡逐张添加回来。"),
            enabled_func = function() return self:_hiddenCount() > 0 end,
            keep_menu_open = true,
            separator = true,
            callback = function(touchmenu_instance)
                self.ui.doc_settings:delSetting("artgallery_hidden")
                UIManager:show(Notification:new{ text = _("已恢复被忽略的图片。") })
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end,
        },
        {
            -- 按当前书籍清理其图片扫描缓存（缓存存于本书 .sdr 侧边目录）
            text = _("清除本书图片缓存"),
            help_text = _("删除本书的图片扫描缓存，下次打开时重新扫描。不会删除原始书籍文件或收藏。"),
            enabled_func = function()
                return self.ui and self.ui.document ~= nil
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:_clearBookCache()
                UIManager:show(Notification:new{
                    text = _("已清除本书图片缓存，下次打开将重新扫描。") })
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end,
        },
        {
            text = _("高级"),
            sub_item_table = {
                {
                    text = _("忽略不相关图片"),
                    help_text = _("过滤掉封面、出版商徽标、装饰性元素等，只保留地图、族谱、示意图和插图。关闭则显示书中所有图片。误过滤的图片可从图库的「已忽略」选项卡添加回来。"),
                    checked_func = function()
                        return self:getFilterLevel() ~= "all"
                    end,
                    callback = function()
                        local now_on = self:getFilterLevel() ~= "all"
                        G_reader_settings:saveSetting(FILTER_KEY,
                            now_on and "all" or "balanced")
                    end,
                },
                {
                    text = _("显示图片标题（测试）"),
                    help_text = _("在查看器的左上角显示图片的标题（来自书籍）。"),
                    checked_func = function()
                        return G_reader_settings:nilOrTrue(CAPTIONS_KEY)
                    end,
                    callback = function()
                        G_reader_settings:flipNilOrTrue(CAPTIONS_KEY)
                    end,
                },
                {
                    text = _("启用顶部菜单触摸区"),
                    help_text = _("查看器打开时，点击屏幕顶部区域会打开 KOReader 的顶部菜单（仅顶部菜单，不打开底部菜单），覆盖在抽屉之上。关闭则顶部区域无反应。"),
                    checked_func = function()
                        return G_reader_settings:nilOrTrue(TOP_MENU_KEY)
                    end,
                    callback = function()
                        G_reader_settings:flipNilOrTrue(TOP_MENU_KEY)
                    end,
                    separator = true,
                },
                {
                    text = _("禁用阴影"),
                    help_text = _("移除抽屉的投影。阴影是抖动渐变 — 主要是导致 ArtGallery 关闭后残留鬼影的原因，若关闭后仍有残影可开启此选项。在 LCD 屏幕上无可见效果。"),
                    checked_func = function()
                        return G_reader_settings:isTrue(SHADOW_KEY)
                    end,
                    callback = function()
                        G_reader_settings:saveSetting(SHADOW_KEY,
                            not G_reader_settings:isTrue(SHADOW_KEY))
                    end,
                    separator = true,
                },
                {
                    -- rarely needed, so tucked in here rather than the main list
                    text = _("重新扫描本书"),
                    help_text = _("ArtGallery 会缓存本书的扫描结果。若书籍文件被替换或图片过时可使用此选项。"),
                    keep_menu_open = true,
                    callback = function()
                        local okay = self:_supportedReason()
                        if not okay then return end
                        self._scan = nil
                        local info = InfoMessage:new{ text = _("正在扫描书本中的图片…") }
                        UIManager:show(info)
                        UIManager:forceRePaint()
                        local scan = self:_getScan(true)
                        UIManager:close(info)
                        if scan then
                            UIManager:show(Notification:new{
                                text = T(_("找到 %1 张图片。"), #scan.images),
                            })
                        else
                            UIManager:show(Notification:new{ text = _("扫描失败。") })
                        end
                    end,
                },
            },
        },
        {
            text = _("更新"),
            sub_item_table = {
                {
                    text_func = function()
                        return T(_("检查更新 (v%1)"), _installed_version())
                    end,
                    callback = function() self:_checkForUpdate() end,
                },
                {
                    text = _("包含预发布版本"),
                    help_text = _("也提供 GitHub 上标记为预发布的版本 — 正式发布前的测试版。常规更新检查不会提供这些版本。"),
                    checked_func = function()
                        return G_reader_settings:isTrue(PRERELEASE_KEY)
                    end,
                    callback = function()
                        G_reader_settings:saveSetting(PRERELEASE_KEY,
                            not G_reader_settings:isTrue(PRERELEASE_KEY))
                    end,
                },
            },
        },
        {
            text = _("收藏"),
            sub_item_table = {
                {
                    text = _("显示收藏"),
                    help_text = _("查看您收藏的图片——全局可用，即使没有打开任何书也能浏览。"),
                    callback = function() self:showFavorites() end,
                },
                {
                    text = _("清除收藏"),
                    help_text = _("移除所有收藏的图片（不会删除原始书籍文件）。"),
                    callback = function()
                        UIManager:show(ConfirmBox:new{
                            text = _("确定要清除所有收藏吗？"),
                            ok_text = _("清除"),
                            ok_callback = function()
                                self:clearFavorites()
                                UIManager:show(Notification:new{
                                    text = _("已清除收藏。") })
                            end,
                        })
                    end,
                },
            },
            separator = true,
        },
        {
            text = _("浏览 CBZ 漫画"),
            help_text = _("从文件管理器中选择一个 .cbz 漫画压缩包，用美术馆全屏翻阅其中的页面图片。"),
            enabled_func = function()
                return self.ui and not self.ui.document
                    and self._menu_file
                    and self._menu_file:lower():match("%.cbz$") ~= nil
            end,
            callback = function() self:showCbz(self._menu_file) end,
        },
        {
            text = _("关于 美术馆"),
            help_text = _("基于 Glimpse 合并 Illustrations 的全屏看图能力。"),
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = T(_("美术馆 / ArtGallery v%1\n\n基于 Glimpse 合并 Illustrations 的全屏看图能力。\n作者：ksaMask123\n更新：GitHub ksaMask123/artgallery.koplugin"),
                        _installed_version()),
                })
            end,
        },
    }
end

return ArtGallery