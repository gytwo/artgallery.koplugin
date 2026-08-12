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
local TextViewer = require("ui/widget/textviewer")
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
local FILTER_KEY = "artgallery_filter"
local INVERT_KEY = "artgallery_invert_night"
local NAV_BUTTONS_KEY = "artgallery_nav_buttons"
local SYNC_PROGRESS_KEY = "artgallery_sync_progress"
local SYNC_PROGRESS_EPUB_KEY = "artgallery_sync_progress_epub"
local CAPTIONS_KEY = "artgallery_captions"
local TOP_MENU_KEY = "artgallery_top_menu_zone"
local SMART_ROTATION_KEY = "artgallery_smart_rotation"
local SHADOW_KEY = "artgallery_disable_shadow"
local DARK_BG_KEY = "artgallery_dark_background"
local GESTURE_TIP_KEY = "artgallery_gesture_tip_shown"
local NO_RESIDUE_KEY = "artgallery_no_residue"
local NOTE_KEY = "artgallery_note"

-- 面板比例配置（3种比例可供选择）
local PANEL_RATIO_KEY = "artgallery_panel_ratio"
local PANEL_RATIO_DEFAULT = 0.8
local PANEL_RATIO_OPTIONS = {0.5, 0.8, 1.0}    

local QUICK_ACTIONS_KEY = "artgallery_quick_actions"
local QUICK_ACTIONS = {
    { key = "gallery",    default = true  },
    { key = "mode",       default = true  },
    { key = "rotate",     default = true  },
    { key = "showinbook", default = true  },
    { key = "noresidue",  default = true },
    { key = "smartrotate", default = true },
    { key = "restore",    default = true },
    { key = "prevnext",   default = true },
    { key = "captions",   default = true },
    { key = "invert",     default = true  },
    { key = "darkbg",     default = true },
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
        mode       = _("模式切换"),
        rotate     = _("旋转90°"),
        showinbook = _("在书中定位"),
        noresidue  = _("切换比例无残留模式"),
        smartrotate = _("智能自动旋转"),
        restore    = _("恢复被忽略的图片"),
        prevnext   = _("显示导航按钮开关"),
        captions   = _("显示图片标题开关"),
        invert     = _("夜间模式反转图片"),
        darkbg     = _("抽屉黑色背景"),
    })[key] or key
end

-- ── overlay chrome: dot pill and ⋯ button ──────────────────────────────────

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

local ArtGalleryPill = WidgetContainer:extend{
    inner = nil,
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

local ArtGalleryBadge = Widget:extend{
    num = 1,
    glyph = nil,
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

local function _cornerLuma(bb, x, y)
    local ok, c = pcall(function() return bb:getPixel(x, y) end)
    if not (ok and c) then return 255 end
    local ok8, g = pcall(function() return c:getColor8() end)
    if ok8 and g then return g.a or 255 end
    local ok32, rgb = pcall(function() return c:getColorRGB32() end)
    if ok32 and rgb then return math.floor((rgb.r + rgb.g + rgb.b) / 3) end
    return 255
end

local ArtGalleryCornerBadge = Widget:extend{
    icon = nil,
    size = Screen:scaleBySize(18),
}
function ArtGalleryCornerBadge:getSize()
    return Geom:new{ w = self.size, h = self.size }
end
function ArtGalleryCornerBadge:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.size, h = self.size }
    if self.icon then
        bb:alphablitFrom(self.icon, x, y, 0, 0, self.size, self.size)
    end
end
function ArtGalleryCornerBadge:free() end

local ArtGalleryMoreButton = Widget:extend{
    size = Screen:scaleBySize(42),
    radius = Screen:scaleBySize(8),
    stroke = Screen:scaleBySize(2),
    icon = nil,
    icon_size = Screen:scaleBySize(18),
    disabled = nil,
    disabled_gray = 0xB4,
}

function ArtGalleryMoreButton:getSize()
    return Geom:new{ w = self.size, h = self.size }
end

function ArtGalleryMoreButton:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.size, h = self.size }
    if not self._bg_bb then
        local fill = 0xFF
        if self.disabled then fill = nil end
        self._bg_bb = make_rounded_stencil(self.size, self.size,
            self.radius, self.stroke, fill,
            self.disabled and self.disabled_gray or 0x00)
    end
    bb:alphablitFrom(self._bg_bb, x, y, 0, 0, self.size, self.size)
    if self.icon and not self._icon_bb then
        local ok, ibb = pcall(RenderImage.renderSVGImageFile, RenderImage,
            self.icon, self.icon_size, self.icon_size)
        if ok and ibb then
            if self.disabled then
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

local ArtGalleryCaption = Widget:extend{
    text = "",
    max_width = 0,
    pad_left = Screen:scaleBySize(6),
    pad_right = Screen:scaleBySize(8),
    pad_top = 0,
    pad_bottom = Screen:scaleBySize(2),
    radius = Screen:scaleBySize(10),
}

function ArtGalleryCaption:init()
    local face = Font:getFace("cfont", 12)
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
    }
end

function ArtGalleryCaption:getSize()
    local s = self._text:getSize()
    return Geom:new{
        w = s.w + self.pad_left + self.pad_right,
        h = s.h + self.pad_top + self.pad_bottom,
    }
end

function ArtGalleryCaption:_buildBg(w, h)
    self._bg_bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
    self._bg_bb:fill(Blitbuffer.ColorRGB32(255, 255, 255, 255))
    self._text:paintTo(self._bg_bb, self.pad_left, self.pad_top)
    local r = self.radius
    if r > 0 then
        local cx, cy = w - r, h - r
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

local ArtGalleryTextButton = Widget:extend{
    text = "",
    bold = false,
    icon = nil,
    icon_size = Screen:scaleBySize(16),
    icon_gap = Screen:scaleBySize(7),
    height = Screen:scaleBySize(42),
    radius = Screen:scaleBySize(8),
    stroke = Screen:scaleBySize(2),
    padding_h = Screen:scaleBySize(14),
    inverted = nil,
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

local ArtGalleryMenuRow = Widget:extend{
    text = "",
    icon_bb = nil,
    lead_wg = nil,
    width = 0,
    height = Screen:scaleBySize(44),
    icon_col = 0,
    icon_size = Screen:scaleBySize(18),
    pad_left = Screen:scaleBySize(16),
    enabled = true,
}

function ArtGalleryMenuRow:init()
    self._enabled = (self.enabled ~= false)
    self._text_wg = TextWidget:new{
        text = self.text,
        face = Font:getFace("cfont", 15),
        bold = true,
        fgcolor = self._enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
    }
end

function ArtGalleryMenuRow:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function ArtGalleryMenuRow:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    if self.icon_bb then
        bb:alphablitFrom(self.icon_bb,
            x + self.pad_left + math.floor((self.icon_size - self.icon_bb:getWidth()) / 2),
            y + math.floor((self.height - self.icon_bb:getHeight()) / 2),
            0, 0, self.icon_bb:getWidth(), self.icon_bb:getHeight())
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

local ArtGalleryCard = WidgetContainer:extend{
    radius = Screen:scaleBySize(9),
    stroke = Screen:scaleBySize(2),
    outline = 0x00,
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
        self._fill_bb = make_rounded_stencil(sz.w, sz.h,
            self.radius, self.stroke, 0xFF, 0xFF)
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

local ArtGalleryPopupMenu = InputContainer:extend{
    items = nil,
    anchor = nil,
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
            enabled = (it.enabled ~= false),
        }
        row._callback = it.callback
        row._enabled = (it.enabled ~= false)
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
            if row._enabled then
                local cb = row._callback
                self:dismiss()
                if cb then cb() end
            end
            return true
        end
    end
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

local ArtGalleryViewer = ImageViewer:extend{
    image_metas = nil,
    gallery_hidden_count = 0,
    on_image_shown = nil,
    on_hide = nil,
    on_show_in_book = nil,
    on_rotate = nil,
    on_show_menu = nil,
    scope = nil,
    on_toggle_scope = nil,
    hidden_count = nil,
    on_restore_hidden = nil,
    get_pref = nil,
    set_pref = nil,
    shown_metas = nil,
    shown_list = nil,
    ignored_metas = nil,
    ignored_list = nil,
    primary_tab = "shown",
    on_ignore = nil,
    on_unignore = nil,
    gallery_cols = 3,
    with_title_bar = false,
    max_zoom_of_native = 1.5,
    panel_ratio = PANEL_RATIO_DEFAULT,
    panel_vgap = 0,
    panel_border = Screen:scaleBySize(2),
    panel_radius = Screen:scaleBySize(24),
    shadow_width = Screen:scaleBySize(131),
    shadow_overlap = Screen:scaleBySize(66),
    image_right_gap = Screen:scaleBySize(12),
    image_padding = Screen:scaleBySize(2),
    alpha = 0.25,
    disable_double_tap = true,
}

function ArtGalleryViewer:_getCornerIcon(svg_path, size, dark)
    self._corner_icons = self._corner_icons or {}
    local entry = self._corner_icons[svg_path]
    if not entry then
        local ok, ibb = pcall(RenderImage.renderSVGImageFile, RenderImage,
            svg_path, size, size)
        if not (ok and ibb) then return nil end
        entry = { black = ibb }
        local w, h = ibb:getWidth(), ibb:getHeight()
        local inv = ibb:copy()
        pcall(inv.invertRect, inv, 0, 0, w, h)
        entry.white = inv
        self._corner_icons[svg_path] = entry
    end
    return dark and entry.white or entry.black
end

function ArtGalleryViewer:_galleryFilterLabel()
    local f = self._gallery_filter or "all"
    if f == "all" then return _("图库（全部）") end
    if f == "shown" then return _("图库（过滤后）") end
    if f == "favorites" then return _("图库（已收藏）") end
    if f == "ignored" then return _("图库（已忽略）") end
    return _("图库（全部）")
end

function ArtGalleryViewer:init()
    self._cur_rotation = self:_prefFor(1).rotation or 0
    self._fullscreen_fill = G_reader_settings:readSetting("artgallery_default_fill") or "cover"
    local saved = G_reader_settings:readSetting(PANEL_RATIO_KEY)
    self.panel_ratio = saved or PANEL_RATIO_DEFAULT
    self._auto_rotated_for = nil
    self._smart_failed_for = {}
    self._thumb_keys = {}
    self._chrome_hidden = true
    ImageViewer.init(self)
    self:_buildMoreButton()
    self:update()
end

function ArtGalleryViewer:_cyclePanelRatio()
    if self._gallery_mode then return end

    local options = PANEL_RATIO_OPTIONS
    local current = self.panel_ratio or PANEL_RATIO_DEFAULT
    local idx = 1
    for i, v in ipairs(options) do
        if math.abs(v - current) < 0.01 then idx = i; break end
    end
    local next_idx = idx % #options + 1
    local new_ratio = options[next_idx]
    local old_ratio = self.panel_ratio
    self.panel_ratio = new_ratio
    
    G_reader_settings:saveSetting(PANEL_RATIO_KEY, self.panel_ratio)

    -- 无残留模式：从大比例切小比例时，关闭重开
    local no_residue = G_reader_settings:isTrue(NO_RESIDUE_KEY)
    if no_residue and new_ratio < old_ratio then
        if self.on_rotate then
            self:onClose()
            self.on_rotate(nil, true)
        end
        return
    end

    -- 其他情况：原地更新
    if self.scale_factor and self.scale_factor ~= 0 then
        self.scale_factor = 0
        self._center_x_ratio, self._center_y_ratio = 0.5, 0.5
    end
    self._fit_scale_factor = nil
    self._scale_factor_0 = nil
    self:update()
end

function ArtGalleryViewer:_setChrome(hidden)
    if self._chrome_hide_action then
        UIManager:unschedule(self._chrome_hide_action)
        self._chrome_hide_action = nil
    end
    if self._chrome_hidden == hidden then return end
    self._chrome_hidden = hidden
    self:update()
end

function ArtGalleryViewer:_inBottomZone(pos)
    local zh = Screen:scaleBySize(56)
    local sh = Screen:getHeight()
    return pos.y >= sh - zh
end

function ArtGalleryViewer:_fillLabel(mode)
    if mode == "contain" then return _("适配") end
    if mode == "stretch" then return _("拉伸") end
    return _("铺满")
end

function ArtGalleryViewer:_cycleFullscreenFill()
    local order = { cover = "contain", contain = "stretch", stretch = "cover" }
    local next_mode = order[self._fullscreen_fill or "cover"] or "contain"
    self:_setFullscreenFill(next_mode)
end

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
                G_reader_settings:makeTrue("artgallery_stretch_warned")
                self:_applyFullscreenFill("stretch")
            end,
        })
        return
    end
    self:_applyFullscreenFill(mode)
end

function ArtGalleryViewer:_applyFullscreenFill(mode)
    self._fullscreen_fill = mode
    if self.scale_factor and self.scale_factor ~= 0 then
        self.scale_factor = 0
        self._center_x_ratio, self._center_y_ratio = 0.5, 0.5
    end
    self._fit_scale_factor = nil
    self._scale_factor_0 = nil
    self:update()
end

function ArtGalleryViewer:_setDefaultFill(mode)
    G_reader_settings:saveSetting("artgallery_default_fill", mode)
    UIManager:show(InfoMessage:new{
        text = _("已将“" .. self:_fillLabel(mode) .. "”设为默认看图模式"),
        timeout = 1,
    })
end

function ArtGalleryViewer:_setDefaultRatio(ratio)
    G_reader_settings:saveSetting(PANEL_RATIO_KEY, ratio)
    UIManager:show(InfoMessage:new{
        text = _("已将比例设为默认：" .. ratio),
        timeout = 1,
    })
end

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

function ArtGalleryViewer:update()
    self:_clean_image_wg()
    local orig_dimen = self.main_frame.dimen
    -- 丢弃 main_frame 被 paint 缓存的旧尺寸：FrameContainer:paintTo 只在首次
    -- paint 时按当前子节点算出 w/h 存进 self.dimen，之后每次 paint 只更新
    -- x/y、不重算 w/h（见 frontend/ui/widget/container/framecontainer.lua:104）。
    -- 面板比例变化时会改变面板宽度并重排子节点，若不清除，main_frame.dimen
    -- 会停在旧宽度，导致刷新区不正确。置 nil 让下次 paintTo 按新子节点
    -- 重算正确尺寸。
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

    -- 先创建 _smart_frame（让 _pillAvailWidth 能读到宽度），位置稍后计算
    if self._smart_frame then self._smart_frame:free(); self._smart_frame = nil end
    if not self._gallery_mode and not self._chrome_hidden then
        local is_on = G_reader_settings:nilOrTrue(SMART_ROTATION_KEY)
        self._smart_frame = ArtGalleryMoreButton:new{
            icon = _PLUGIN_DIR .. "/assets/rotate.svg",
            inverted = is_on,
        }
    end

    -- 关闭按钮（单图模式，只有图标）
    if self._close_btn then self._close_btn:free(); self._close_btn = nil end
    if not self._gallery_mode and not self._chrome_hidden then
        self._close_btn = ArtGalleryMoreButton:new{
            icon = _PLUGIN_DIR .. "/assets/close.svg",
        }
        -- 位置在 _more_frame 分支中计算
    end

    -- Explicit day-white backing behind the image area. KOReader's night mode
    -- inverts the framebuffer when compositing, so this shows black in dark
    -- mode (issue #9) rather than leaving a light gap around the image; in day
    -- mode it just matches the white card. Logical/day polarity, flag 0.
    local is_dark_bg = G_reader_settings:isTrue(DARK_BG_KEY)
    local image_layer = FrameContainer:new{
        background = (is_dark_bg and not self._gallery_mode)
            and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
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
    local btn_size = ArtGalleryMoreButton.size

    -- 计算所有按钮的宽度
    local nav_btn_width = btn_size
    local ratio_btn_width = self.panel_ratio and string.format("%.1f", self.panel_ratio):len() * 12 + 40 or 60
    local gallery_btn_width = btn_size
    local fill_btn_width = self:_fillLabel(self._fullscreen_fill):len() * 12 + 40
    local fav_btn_width = btn_size
    local smart_btn_width = btn_size
    local more_btn_width = btn_size
    local close_btn_width = btn_size
    local pill_width = 0
    
    -- 计算页码需要的宽度
    local need_pill = false
    if self._gallery_mode then
        -- 画廊模式：永远显示过滤切换按钮
        need_pill = true
        pill_width = 120
    elseif not self._gallery_mode and self._images_list and self._images_list_nb > 1 then
        local nb = self._images_list_nb
        local dot_r = ArtGalleryDots.dot_r
        local natural_pitch = ArtGalleryDots.pitch
        local min_pitch = 2 * dot_r + Screen:scaleBySize(2)
        local budget = image_area_w - 4 * btn_inset - 2 * btn_gap
        local pitch = math.min(natural_pitch, (budget - 2 * dot_r) / (nb - 1))
        if pitch >= min_pitch then
            pill_width = (nb - 1) * pitch + 2 * dot_r + 2 * ArtGalleryPill.padding_h
        else
            pill_width = 60
        end
        need_pill = true
    end

    -- 判断哪些按钮显示（从高优先级到低优先级隐藏）
    -- 必须保留：填充模式、更多菜单
    local show_fill = true
    local show_more = true
    
    -- 导航按钮用户是否启用
    local nav_enabled = G_reader_settings:isTrue(NAV_BUTTONS_KEY) 
        and self._images_list and (self._images_list_nb or 1) > 1
    
    -- 关闭按钮只在比例=1时显示
    local is_fullscreen_like = (self.panel_ratio or 0) >= 0.99
    
    -- 所有按钮默认显示（除了必须保留的已经设为 true）
    local show_pill = need_pill
    local show_close = is_fullscreen_like
    local show_nav_left = nav_enabled
    local show_nav_right = nav_enabled
    local show_ratio = true
    local show_smart = true
    local show_gallery = true
    local show_fav = true
    
    -- 计算左侧按钮总宽度（从左到右：◀ 比例 图库 填充）
    local left_width = 0
    if show_nav_left then left_width = left_width + nav_btn_width + btn_gap end
    if show_ratio then left_width = left_width + ratio_btn_width + btn_gap end
    if show_gallery then left_width = left_width + gallery_btn_width + btn_gap end
    if show_fill then left_width = left_width + fill_btn_width + btn_gap end
    
    -- 计算右侧按钮总宽度（从右到左：关闭 ▶ ⋯ 智能旋转 收藏）
    local right_width = 0
    if show_close then right_width = right_width + close_btn_width + btn_gap end
    if show_nav_right then right_width = right_width + nav_btn_width + btn_gap end
    if show_more then right_width = right_width + more_btn_width + btn_gap end
    if show_smart then right_width = right_width + smart_btn_width + btn_gap end
    if show_fav then right_width = right_width + fav_btn_width + btn_gap end
    
    -- 页码宽度
    local pill_w = show_pill and pill_width or 0
    
    -- 可用宽度
    local avail_width = image_area_w - 2 * btn_inset
    
    -- 总需求宽度
    local total_needed = left_width + pill_w + right_width + 2 * btn_inset
    
    -- 安全边距：预留 10px 避免按钮重叠
    local safety_margin = 10
    
    -- 如果空间不够，按优先级从高到低逐个隐藏
    -- 优先级0：关闭按钮
    if total_needed > avail_width - safety_margin and show_close then
        show_close = false
        right_width = right_width - close_btn_width - btn_gap
        total_needed = total_needed - close_btn_width - btn_gap
    end

    -- 优先级1：导航按钮
    if total_needed > avail_width - safety_margin and show_nav_left then
        show_nav_left = false
        show_nav_right = false
        left_width = left_width - nav_btn_width - btn_gap
        right_width = right_width - nav_btn_width - btn_gap
        total_needed = total_needed - nav_btn_width * 2 - btn_gap * 2
    end

    -- 优先级2：中间页码
    if total_needed > avail_width - safety_margin and show_pill then
        show_pill = false
        total_needed = total_needed - pill_width - btn_gap
    end
    
    -- 优先级3：图库
    if total_needed > avail_width - safety_margin and show_gallery then
        show_gallery = false
        left_width = left_width - gallery_btn_width - btn_gap
        total_needed = total_needed - gallery_btn_width - btn_gap
    end
    
    -- 优先级4：智能旋转
    if total_needed > avail_width - safety_margin and show_smart then
        show_smart = false
        right_width = right_width - smart_btn_width - btn_gap
        total_needed = total_needed - smart_btn_width - btn_gap
    end
    
    -- 优先级5：比例切换
    if total_needed > avail_width - safety_margin and show_ratio then
        show_ratio = false
        left_width = left_width - ratio_btn_width - btn_gap
        total_needed = total_needed - ratio_btn_width - btn_gap
    end
    
    -- 优先级6：收藏（最后隐藏）
    if total_needed > avail_width - safety_margin and show_fav then
        show_fav = false
        right_width = right_width - fav_btn_width - btn_gap
        total_needed = total_needed - fav_btn_width - btn_gap
    end

    -- optional prev/next buttons: always shown while the toggle is on
    -- (zoomed too — switching lands the next image at fit); at the ends
    -- of the list the dead-end button stays visible but grayed out, so
    -- the layout never jumps. Next sits at the right edge; ⋯ moves left
    -- of it whenever the buttons are enabled.
    if self._nav_prev_frame then self._nav_prev_frame:free() end
    if self._nav_next_frame then self._nav_next_frame:free() end
    self._nav_prev_frame, self._nav_next_frame = nil, nil
    local nav = show_nav_left or show_nav_right
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
    
    -- 根据计算结果创建按钮
    -- 导航按钮（左侧）
    if show_nav_left and not self._gallery_mode and not self._chrome_hidden then
        self._nav_prev_frame = ArtGalleryMoreButton:new{
            icon = _PLUGIN_DIR .. "/assets/prev.svg",
            disabled = cur <= 1 or nil,
        }
        self._nav_prev_frame.overlap_offset = {
            btn_inset,
            self.height - self._nav_prev_frame.size - btn_inset,
        }
        table.insert(overlay, self._nav_prev_frame)
    end
    
    -- 面板比例切换按钮：显示当前比例值（图标+文字）
    if self._fs_frame then self._fs_frame:free(); self._fs_frame = nil end
    if show_ratio and not self._gallery_mode and not self._chrome_hidden then
        local ratio_text = string.format("%.1f", self.panel_ratio or PANEL_RATIO_DEFAULT)
        self._fs_frame = ArtGalleryTextButton:new{
            text = ratio_text,
            bold = true,
        }
        local fs_x = btn_inset
        if self._nav_prev_frame and self._nav_prev_frame.overlap_offset then
            fs_x = self._nav_prev_frame.overlap_offset[1]
                + self._nav_prev_frame.size + btn_gap
        end
        self._fs_frame.overlap_offset = {
            fs_x, self.height - self._fs_frame:getSize().h - btn_inset,
        }
        table.insert(overlay, self._fs_frame)
    end

    -- 图库按钮（左侧，在填充模式按钮前面）
    if self._gallery_btn_frame then self._gallery_btn_frame:free(); self._gallery_btn_frame = nil end
    if show_gallery and not self._gallery_mode and not self._chrome_hidden then
        self._gallery_btn_frame = ArtGalleryMoreButton:new{
            icon = _PLUGIN_DIR .. "/assets/gallery.svg",
        }
        local gallery_x = btn_inset
        if self._fs_frame and self._fs_frame.overlap_offset then
            gallery_x = self._fs_frame.overlap_offset[1]
                + self._fs_frame:getSize().w + btn_gap
        elseif self._nav_prev_frame and self._nav_prev_frame.overlap_offset then
            gallery_x = self._nav_prev_frame.overlap_offset[1]
                + self._nav_prev_frame.size + btn_gap
        end
        self._gallery_btn_frame.overlap_offset = {
            gallery_x, self.height - self._gallery_btn_frame.size - btn_inset,
        }
        table.insert(overlay, self._gallery_btn_frame)
    end

    -- 全屏填充模式三态循环按钮（铺满 / 适配 / 拉伸）：短按循环切换并即时套用，
    -- 长按设为默认全屏看图模式（见 onTap / onHold）。仅单图态显示；沉浸式隐藏态一同隐藏。
    -- 每次 update() 重建以刷新当前模式文案；先释放旧实例避免泄漏。
    if self._fill_frame then self._fill_frame:free(); self._fill_frame = nil end
    if show_fill and not self._gallery_mode and not self._chrome_hidden then
        self._fill_frame = ArtGalleryTextButton:new{
            text = self:_fillLabel(self._fullscreen_fill),
            bold = true,
            -- 三态（铺满/适配/拉伸）共用同一「图像适配」图标：外框+山脊+太阳，
            -- 仅标记这是「全屏填充模式」选择器；具体模式由右侧文字标明。
        }
        local fill_x = btn_inset
        if self._gallery_btn_frame and self._gallery_btn_frame.overlap_offset then
            fill_x = self._gallery_btn_frame.overlap_offset[1]
                + self._gallery_btn_frame.size + btn_gap
        elseif self._fs_frame and self._fs_frame.overlap_offset then
            fill_x = self._fs_frame.overlap_offset[1]
                + self._fs_frame:getSize().w + btn_gap
        elseif self._nav_prev_frame and self._nav_prev_frame.overlap_offset then
            fill_x = self._nav_prev_frame.overlap_offset[1]
                + self._nav_prev_frame.size + btn_gap
        end
        self._fill_frame.overlap_offset = {
            fill_x, self.height - self._fill_frame:getSize().h - btn_inset,
        }
        table.insert(overlay, self._fill_frame)
    end

    -- 收藏按钮（右侧，在更多按钮左侧，智能按钮右侧）
    if self._fav_btn_frame then self._fav_btn_frame:free(); self._fav_btn_frame = nil end
    if show_fav and not self._gallery_mode and not self._chrome_hidden then
        local is_fav = self:_currentFavoriteState()
        self._fav_btn_frame = ArtGalleryMoreButton:new{
            icon = _PLUGIN_DIR .. (is_fav and "/assets/favorite_on.svg" or "/assets/favorite_off.svg"),
            inverted = is_fav,
        }
    end

    -- 画廊模式：返回按钮
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
    else
        -- 单图模式：从右往左构建右侧按钮组
        -- 1. 先创建 _nav_next_frame（最右边）
        if show_nav_right and not self._gallery_mode and not self._chrome_hidden then
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

        -- 2. _more_frame 在 _nav_next_frame 左边
        if self._more_frame then self._more_frame:free(); self._more_frame = nil end
        if show_more and not self._gallery_mode and not self._chrome_hidden then
            self._more_frame = ArtGalleryMoreButton:new{}
            local more_size = self._more_frame:getSize()
            local more_x, more_y
            if self._nav_next_frame and self._nav_next_frame.overlap_offset then
                more_x = self._nav_next_frame.overlap_offset[1] - btn_gap - more_size.w
                more_y = self._nav_next_frame.overlap_offset[2]
            else
                more_x = image_area_w - more_size.w
                more_y = self.height - more_size.h - btn_inset
            end
            self._more_frame.overlap_offset = { more_x, more_y }
            table.insert(overlay, self._more_frame)

            -- 3. 收藏按钮在 more 按钮左边
            if self._fav_btn_frame then
                local fav_size = self._fav_btn_frame:getSize()
                self._fav_btn_frame.overlap_offset = {
                    more_x - btn_gap - fav_size.w,
                    more_y,
                }
                table.insert(overlay, self._fav_btn_frame)
            end

            -- 4. 智能旋转按钮在收藏按钮左边
            if show_smart and self._smart_frame then
                local smart_size = self._smart_frame:getSize()
                local fav_size = self._fav_btn_frame and self._fav_btn_frame:getSize()
                local fav_w = fav_size and fav_size.w or 0
                self._smart_frame.overlap_offset = {
                    more_x - btn_gap - fav_w - btn_gap - smart_size.w,
                    more_y,
                }
                table.insert(overlay, self._smart_frame)
            end

            -- 5. 关闭按钮在智能旋转按钮左边
            if show_close and self._close_btn then
                local close_size = self._close_btn:getSize()
                local smart_size = self._smart_frame and self._smart_frame:getSize()
                local fav_size = self._fav_btn_frame and self._fav_btn_frame:getSize()
                local smart_w = smart_size and smart_size.w or 0
                local fav_w = fav_size and fav_size.w or 0
                self._close_btn.overlap_offset = {
                    more_x - btn_gap - fav_w - btn_gap - smart_w - btn_gap - close_size.w,
                    more_y,
                }
                table.insert(overlay, self._close_btn)
            end
        elseif self._more_frame then
            -- every Quick Action turned off: hide the ⋯ button entirely.
            self._more_frame.overlap_offset = nil
            self._more_frame.dimen = nil

            -- 如果没有更多按钮，关闭按钮、智能旋转按钮和收藏按钮放在右下角
            if show_close and self._close_btn then
                local close_size = self._close_btn:getSize()
                self._close_btn.overlap_offset = {
                    image_area_w - close_size.w,
                    self.height - close_size.h - btn_inset,
                }
                table.insert(overlay, self._close_btn)
            end
            if show_smart and self._smart_frame then
                local smart_size = self._smart_frame:getSize()
                local close_size = self._close_btn and self._close_btn:getSize() or 0
                self._smart_frame.overlap_offset = {
                    image_area_w - smart_size.w - (close_size > 0 and (close_size + btn_gap) or 0),
                    self.height - smart_size.h - btn_inset,
                }
                table.insert(overlay, self._smart_frame)
            end
            if show_fav and self._fav_btn_frame then
                local fav_size = self._fav_btn_frame:getSize()
                local close_size = self._close_btn and self._close_btn:getSize() or 0
                local smart_size = self._smart_frame and self._smart_frame:getSize() or 0
                local offset = (close_size > 0 and (close_size + btn_gap) or 0) +
                               (smart_size > 0 and (smart_size + btn_gap) or 0)
                self._fav_btn_frame.overlap_offset = {
                    image_area_w - fav_size.w - offset,
                    self.height - fav_size.h - btn_inset,
                }
                table.insert(overlay, self._fav_btn_frame)
            end
        end
    end

    -- 声明 left_bound 和 right_bound（gallery_mode 需要）
    -- 注意：这里在 _more_frame 分支之后执行，此时所有按钮的 overlap_offset 已经设置好了
    local left_bound = btn_inset
    if self._nav_prev_frame and self._nav_prev_frame.overlap_offset then
        left_bound = self._nav_prev_frame.overlap_offset[1]
            + self._nav_prev_frame.size
    end
    if self._fs_frame and self._fs_frame.overlap_offset then
        left_bound = math.max(left_bound,
            self._fs_frame.overlap_offset[1] + self._fs_frame:getSize().w)
    end
    if self._gallery_btn_frame and self._gallery_btn_frame.overlap_offset then
        left_bound = math.max(left_bound,
            self._gallery_btn_frame.overlap_offset[1] + self._gallery_btn_frame.size)
    end
    if self._fill_frame and self._fill_frame.overlap_offset then
        left_bound = math.max(left_bound,
            self._fill_frame.overlap_offset[1] + self._fill_frame:getSize().w)
    end

    local right_bound = image_area_w
    if self._more_frame and self._more_frame.overlap_offset then
        right_bound = math.min(right_bound, self._more_frame.overlap_offset[1])
    end
    if self._close_frame and self._close_frame.overlap_offset then
        right_bound = math.min(right_bound, self._close_frame.overlap_offset[1])
    end
    if self._nav_next_frame and self._nav_next_frame.overlap_offset then
        right_bound = math.min(right_bound, self._nav_next_frame.overlap_offset[1])
    end
    if self._fav_btn_frame and self._fav_btn_frame.overlap_offset then
        right_bound = math.min(right_bound, self._fav_btn_frame.overlap_offset[1])
    end
    if self._smart_frame and self._smart_frame.overlap_offset then
        right_bound = math.min(right_bound, self._smart_frame.overlap_offset[1])
    end
    if self._close_btn and self._close_btn.overlap_offset then
        right_bound = math.min(right_bound, self._close_btn.overlap_offset[1])
    end

    -- 页码：根据 show_pill 决定是否显示
    if self._gallery_mode then
        -- 画廊模式：永远显示过滤切换按钮
        self:_buildPill()
    else
        -- 单图模式：根据 show_pill 决定
        if show_pill then
            self:_buildPill()
        else
            if self._pill_frame then
                self._pill_frame:free()
                self._pill_frame = nil
            end
            self._pill_dots = nil
        end
    end

    if self._pill_frame and not self._chrome_hidden then
        -- the revert button and the gallery Shown/Ignored toggle are the
        -- same height as the ⋯ button, so share its bottom inset to sit on
        -- the same baseline; the shorter dots pill uses a larger inset so
        -- its centre still lines up
        local bottom_inset = (self:_isOverFit() or self._gallery_mode)
            and btn_inset or Screen:scaleBySize(25)

        if self._gallery_mode and self._pill_frame.setWidth then
            -- gallery mode: keep original behavior
            local pill_left = self._nav_prev_frame
                and (left_bound + btn_gap) or left_bound
            local pill_right = right_bound - btn_gap
            self._pill_frame:setWidth(pill_right - pill_left)
            self._pill_frame.overlap_offset = {
                pill_left, self.height - self._pill_frame:getSize().h - bottom_inset,
            }
        else
            -- single image mode: center the pill between left_bound and right_bound
            local pill_size = self._pill_frame:getSize()
            local available_width = right_bound - left_bound
            if pill_size.w > available_width then
                self._pill_frame.overlap_offset = {
                    left_bound,
                    self.height - pill_size.h - bottom_inset,
                }
            else
                self._pill_frame.overlap_offset = {
                    math.floor(left_bound + (available_width - pill_size.w) / 2),
                    self.height - pill_size.h - bottom_inset,
                }
            end
        end
        table.insert(overlay, self._pill_frame)
    end
    -- caption overlay, top-left on the image (toggleable, on by default)
    if self._caption_wg then
        self._caption_wg:free()
        self._caption_wg = nil
    end
    if self._note_wg then
        self._note_wg:free()
        self._note_wg = nil
    end
    if G_reader_settings:nilOrTrue(CAPTIONS_KEY) and not self._gallery_mode
        and not self._chrome_hidden then
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
    -- 显示备注（在 caption 下方）
    if not self._gallery_mode and not self._chrome_hidden then
        local meta = self.image_metas and self.image_metas[self._images_list_cur or 1]
        if meta then
            local note = self:_getNoteFromFav(meta.path)
            if note and note ~= "" then
                if self._note_wg then
                    self._note_wg:free()
                    self._note_wg = nil
                end
                self._note_wg = ArtGalleryCaption:new{
                    text = note,
                    max_width = image_area_w - 2 * Screen:scaleBySize(16),
                }
                local y_offset = 0
                if self._caption_wg then
                    y_offset = self._caption_wg:getSize().h
                end
                self._note_wg.overlap_offset = { 0, y_offset }
                table.insert(overlay, self._note_wg)
            end
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

function ArtGalleryViewer:_paintPanel(bb, x, y)
    local w, h = self._panel_w, self._panel_h
    local py = y + self.panel_vgap

    local night = Screen.night_mode
    local inv = bb.getInverse and bb:getInverse() == 1
    local render_inv = inv
        and not (night and Device.isAndroid and Device:isAndroid())
    local skey = tostring(night) .. tostring(render_inv)

    local is_fullscreen_like = (self.panel_ratio or 0) >= 0.99
    local shadow_disabled = G_reader_settings:isTrue(SHADOW_KEY) or is_fullscreen_like

    local shadow_h = h + 2 * self.panel_vgap
    local sv = render_inv and 0x00 or (night and 0xFF or 0x00)
    local speak = night and 1.0 or 0.5
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
                return tt < 0.5 and (1 - 0.8 * tt)
                    or 0.6 * (1 - (tt - 0.5) * 2) ^ 2
            else
                return 1 - tt
            end
        end
        local vis0 = self.shadow_overlap / swidth
        local peak_level = night and 1.0 or 0.62
        local bump_width = 0.18
        for i = 0, swidth - 1 do
            local t = (i + 0.5) / swidth
            local orig_level = speak * origFrac(t)
            local bump
            if t <= vis0 then
                bump = 1
            else
                local dist = (t - vis0) / bump_width
                bump = dist < 1 and 0.5 * (1 + math.cos(math.pi * dist)) or 0
            end
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
    local skip_shadow = self._skip_shadow_paint
    self._skip_shadow_paint = nil
    if not skip_shadow and not shadow_disabled then
        bb:alphablitFrom(self._shadow_bb, x + w - self.shadow_overlap, y,
            0, 0, swidth, shadow_h)
    end

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
        local body = render_inv and 0x00 or 0xFF
        local edge = render_inv and 0xFF or 0x00
        local c_body = Blitbuffer.ColorRGB32(body, body, body, 0xFF)
        local c_edge = Blitbuffer.ColorRGB32(edge, edge, edge, 0xFF)
        local bw = night and math.max(2, Screen:scaleBySize(1))
            or self.panel_border
        local is_fullscreen_like = (self.panel_ratio or 0) >= 0.99
        local r = is_fullscreen_like and 0 or self.panel_radius
        self._panel_bb:paintRectRGB32(0, 0, w, h, c_body)
        self._panel_bb:paintRectRGB32(0, 0, w, bw, c_edge)
        self._panel_bb:paintRectRGB32(0, h - bw, w, bw, c_edge)
        self._panel_bb:paintRectRGB32(w - bw, 0, bw, h, c_edge)
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

function ArtGalleryViewer:_saveCorners(bb, x, py)
    local is_fullscreen_like = (self.panel_ratio or 0) >= 0.99
    if is_fullscreen_like then return end
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
    local is_fullscreen_like = (self.panel_ratio or 0) >= 0.99
    if is_fullscreen_like then return end
    if not self._corner_bbs then return end
    local w, h = self._panel_w, self._panel_h
    local py = y + self.panel_vgap
    local is_fullscreen_like = (self.panel_ratio or 0) >= 0.99
    local r = is_fullscreen_like and 0 or self.panel_radius
    bb:alphablitFrom(self._corner_bbs[1], x + w - r, py, 0, 0, r, r)
    bb:alphablitFrom(self._corner_bbs[2], x + w - r, py + h - r, 0, 0, r, r)
end

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
    if self._fill_frame then self._fill_frame:free() end
    if self._gallery_btn_frame then self._gallery_btn_frame:free() end
    if self._fav_btn_frame then self._fav_btn_frame:free() end
    if self._smart_frame then self._smart_frame:free() end
    if self._close_btn then self._close_btn:free() end
    if self._close_frame then self._close_frame:free() end
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
    self:_resetHiRes()
    ImageViewer.onCloseWidget(self)
    table.remove(UIManager._refresh_func_stack)
    UIManager:setDirty(nil, function()
        if not self.main_frame.dimen then return end
        local d = self.main_frame.dimen:copy()
        if not G_reader_settings:isTrue(SHADOW_KEY) then
            d.w = math.min(Screen:getWidth() - d.x,
                d.w + 2 * self.shadow_width - self.shadow_overlap + 1)
        end
        return "full", d, true
    end)
    if self._reader_refresh_count ~= nil then
        local saved = self._reader_refresh_count
        self._reader_refresh_count = nil
        UIManager:nextTick(function() UIManager.refresh_count = saved end)
    end
end

function ArtGalleryViewer:_new_image_wg()
    if G_reader_settings:nilOrTrue(SMART_ROTATION_KEY) and self._images_list_cur and self._auto_rotated_for ~= self._images_list_cur
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
                self._smart_failed_for[self._images_list_cur] = true
            end
        end
    end
    local avail_w = self.width
    local max_image_h = self.img_container_h - self.image_padding * 2
    local max_image_w = avail_w - self.image_padding * 2
    local wg_scale = self.scale_factor
    local src = self.image
    if self._fullscreen_fill == "stretch" and self.scale_factor == 0 then
        wg_scale = nil
    elseif wg_scale == 0 then
        local fit = self:_computeFitScaleFactor()
        if fit then
            wg_scale = fit
        end
    elseif wg_scale > 1 then
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
        image_disposable = false,
        alpha = true,
        width = max_image_w,
        height = max_image_h,
        rotation_angle = self._cur_rotation or 0,
        scale_factor = wg_scale,
        center_x_ratio = self._center_x_ratio,
        center_y_ratio = self._center_y_ratio,
        original_in_nightmode = false,
    }
    self.image_container = CenterContainer:new{
        dimen = Geom:new{ w = avail_w, h = self.img_container_h },
        self._image_wg,
    }
end

function ArtGalleryViewer:_getHiRes()
    if not self.hires_decode then return nil end
    if self._hi_bb == false then return nil end
    if self._hi_bb then return self._hi_bb end
    local hi = self.hires_decode(self._images_list_cur or 1)
    if not hi then self._hi_bb = false; return nil end
    if self.image and hi:getWidth() <= self.image:getWidth() * 1.05 then
        if hi.free then hi:free() end
        self._hi_bb = false
        return nil
    end
    self._hi_bb = hi
    return hi
end

function ArtGalleryViewer:_resetHiRes()
    if self._hi_bb and self._hi_bb ~= false and self._hi_bb.free then
        self._hi_bb:free()
    end
    self._hi_bb = nil
end

function ArtGalleryViewer:_buildPill()
    if self._pill_frame then
        self._pill_frame:free()
        self._pill_frame = nil
    end
    self._pill_dots = nil
    if self._gallery_mode then
        self._pill_frame = ArtGalleryTextButton:new{
            text = self:_galleryFilterLabel(), bold = true }
        return
    end
    if self:_isOverFit() then
        self._pill_frame = ArtGalleryTextButton:new{
            text = _("重置"),
            bold = true,
            icon = _PLUGIN_DIR .. "/assets/zoom.svg",
        }
        return
    end
    if not (self._images_list and self._images_list_nb > 1) then return end
    local nb = self._images_list_nb
    local dot_r = ArtGalleryDots.dot_r
    local natural_pitch = ArtGalleryDots.pitch
    local min_pitch = 2 * dot_r + Screen:scaleBySize(2)
    local budget = self:_pillAvailWidth() - 2 * ArtGalleryPill.padding_h
    local pitch = natural_pitch
    if nb > 1 then
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

function ArtGalleryViewer:_pillAvailWidth()
    local image_area_w = self.width - self.image_right_gap
    local btn_inset = Screen:scaleBySize(16)
    local btn_gap = Screen:scaleBySize(10)
    local btn_size = ArtGalleryMoreButton.size
    local nav = G_reader_settings:isTrue(NAV_BUTTONS_KEY)
        and self._images_list and (self._images_list_nb or 1) > 1

    local right_bound = image_area_w
    if nav then
        right_bound = right_bound - btn_size - btn_gap
    end
    if self:_hasQuickActions() then
        right_bound = right_bound - btn_size - btn_gap
    end
    if self._smart_frame then
        right_bound = right_bound - self._smart_frame:getSize().w - btn_gap
    end
    if self._fav_btn_frame then
        right_bound = right_bound - self._fav_btn_frame:getSize().w - btn_gap
    end
    if self._close_btn then
        right_bound = right_bound - self._close_btn:getSize().w - btn_gap
    end

    local left_bound = btn_inset
    if self._fs_frame then
        left_bound = left_bound + self._fs_frame:getSize().w + btn_gap
    end
    if self._fill_frame then
        left_bound = left_bound + self._fill_frame:getSize().w + btn_gap
    end
    if self._gallery_btn_frame then
        left_bound = left_bound + self._gallery_btn_frame:getSize().w + btn_gap
    end

    return right_bound - left_bound - 2 * btn_gap
end

function ArtGalleryViewer:_buildMoreButton()
    self._more_frame = ArtGalleryMoreButton:new{}
end

-- ── gallery ────────────────────────────────────────────────────────────────

function ArtGalleryViewer:_tabList()
    local f = self._gallery_filter or "all"
    if f == "ignored" then
        return self.ignored_list, self.ignored_metas, #self.ignored_metas
    elseif f == "favorites" then
        local list, metas = self:_favoritesLists()
        return list, metas, #metas
    elseif f == "shown" then
        return self.shown_list, self.shown_metas, #self.shown_metas
    end
    -- all
    local list, metas = self:_allLists()
    return list, metas, #metas
end

function ArtGalleryViewer:_ignoredCount()
    return self.ignored_metas and #self.ignored_metas or 0
end

function ArtGalleryViewer:_hasIgnoredTab()
    return self:_ignoredCount() > 0
end

function ArtGalleryViewer:_ensureDerived()
    if self._derived_ok then return end
    self._render_of = {}
    if self.shown_metas and self.shown_list then
        for i, im in ipairs(self.shown_metas) do
            self._render_of[im] = self.shown_list[i]
        end
    end
    if self.ignored_metas and self.ignored_list then
        for i, im in ipairs(self.ignored_metas) do
            self._render_of[im] = self.ignored_list[i]
        end
    end
    self._ignored_set = {}
    if self.ignored_metas then
        for _, im in ipairs(self.ignored_metas) do
            self._ignored_set[im] = true
        end
    end
    self._derived_ok = true
end

function ArtGalleryViewer:_allLists()
    self:_ensureDerived()
    if self._all_cache then return self._all_cache.list, self._all_cache.metas end
    local metas = {}
    if self.shown_metas then
        for _, im in ipairs(self.shown_metas) do metas[#metas + 1] = im end
    end
    if self.ignored_metas then
        for _, im in ipairs(self.ignored_metas) do metas[#metas + 1] = im end
    end
    table.sort(metas, function(a, b)
        return (a.spine_index or 0) < (b.spine_index or 0) end)
    local list = { image_disposable = true }
    for i, im in ipairs(metas) do list[i] = self._render_of[im] end
    self._all_cache = { list = list, metas = metas }
    return list, metas
end

function ArtGalleryViewer:_favoritesLists()
    self:_ensureDerived()
    if self._fav_cache then return self._fav_cache.list, self._fav_cache.metas end
    local doc = self.doc_ref
        or (self.artgallery and self.artgallery.ui and self.artgallery.ui.document)
    local zip = self.is_cbz and self._zip_path
    local metas = {}
    local function consider(im)
        local key
        if zip then key = "cbz:" .. zip .. "#" .. im.path
        elseif doc then key = doc.file .. "#" .. im.path
        else return end
        if self.artgallery and self.artgallery:isFavoriteByKey(key) then
            metas[#metas + 1] = im
        end
    end
    if self.shown_metas then
        for _, im in ipairs(self.shown_metas) do consider(im) end
    end
    if self.ignored_metas then
        for _, im in ipairs(self.ignored_metas) do consider(im) end
    end
    table.sort(metas, function(a, b)
        return (a.spine_index or 0) < (b.spine_index or 0) end)
    local list = { image_disposable = true }
    for i, im in ipairs(metas) do list[i] = self._render_of[im] end
    self._fav_cache = { list = list, metas = metas }
    return list, metas
end

function ArtGalleryViewer:_invalidateGalleryCaches()
    self._all_cache = nil
    self._fav_cache = nil
    self._derived_ok = nil
    self._gallery_layouts = nil
    if self._thumb_bbs then
        for _, t in pairs(self._thumb_bbs) do
            if t.bb then t.bb:free() end
        end
        self._thumb_bbs = nil
    end
end

function ArtGalleryViewer:_cycleGalleryFilter()
    local order = { all = "shown", shown = "favorites", favorites = "ignored", ignored = "all" }
    local next_f = order[self._gallery_filter or "all"] or "all"
    if self._gallery_mode then
        self._gallery_filter = next_f
        self:_invalidateGalleryCaches()
        self._gallery_page = 1
        self:update()
    else
        self:_enterGallery(nil, next_f)
    end
end

function ArtGalleryViewer:_enterGallery(page, filter)
    self._gallery_mode = true
    self._gallery_filter = filter or self._gallery_filter or "all"
    self:_invalidateGalleryCaches()
    local layout = self:_galleryLayout()
    if page then
        self._gallery_page = math.min(math.max(page, 1), #layout.pages)
    else
        self._gallery_page = layout.page_of[self._images_list_cur or 1] or 1
    end
    self.scale_factor = 0
    self._center_x_ratio, self._center_y_ratio = 0.5, 0.5
    self:update()
end

function ArtGalleryViewer:_exitGallery(idx)
    self._gallery_mode = false
    if idx and idx ~= (self._images_list_cur or 1) then
        self:switchToImageNum(idx)
    else
        self:update()
    end
end

function ArtGalleryViewer:_galleryPages()
    return #self:_galleryLayout().pages
end

function ArtGalleryViewer:_contentOrigin()
    local mf = self.main_frame.dimen
    return mf.x, mf.y + self.panel_vgap + self.panel_border
end

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

function ArtGalleryViewer:_openImageActionMenu(meta, pos)
    if not meta then return end
    self:_ensureDerived()
    local key = self:_favKeyFor(meta)
    local fav = self.is_favorites or (
        key and self.artgallery
        and self.artgallery:isFavoriteByKey(key) or false)
    local ignored = self._ignored_set[meta] or false
    local note = self:_getNoteFromFav(meta.path)
    local has_note = note ~= nil and note ~= ""
    local items = {}
    -- 新增：备注选项
    items[#items + 1] = {
        text = has_note and _("编辑备注") or _("添加备注"),
        enabled = true,
        callback = function()
            self:_addNote()
        end,
    }
    items[#items + 1] = {
        text = _("删除备注"),
        enabled = has_note,
        callback = function()
            self:_removeNoteFromFav(meta)
            self:_afterCollectionChange()
        end,
    }
    items[#items + 1] = {
        text = _("收藏图片"),
        enabled = not fav,
        callback = function()
            if self.artgallery then self.artgallery:addFavorite(meta, self) end
            self:_afterCollectionChange()
        end,
    }
    items[#items + 1] = {
        text = _("取消收藏"),
        enabled = fav,
        callback = function()
            if self.is_favorites then
                if self.artgallery then
                    self.artgallery:removeFavoriteByFile(meta.path)
                end
            elseif key and self.artgallery then
                self.artgallery:removeFavoriteByKey(key)
            end
            self:_afterCollectionChange()
        end,
    }
    items[#items + 1] = {
        text = _("忽略图片"),
        enabled = (not ignored) and (not fav) and (not self.is_favorites),
        callback = function()
            if self._gallery_mode then
                if self.on_ignore then
                    self.on_ignore(meta, "shown", self._gallery_page)
                end
            else
                self:_hideCurrentImage()
            end
        end,
    }
    items[#items + 1] = {
        text = _("取消忽略"),
        enabled = ignored,
        callback = function()
            if self.on_unignore then
                self.on_unignore(meta, "ignored", self._gallery_page)
            end
        end,
    }
    local menu
    menu = ArtGalleryPopupMenu:new{
        items = items,
        row_h = Screen:scaleBySize(38),
        pad_left = Screen:scaleBySize(12),
        pad_right = Screen:scaleBySize(12),
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

function ArtGalleryViewer:_afterCollectionChange()
    self:_invalidateGalleryCaches()
    self:update()
end

function ArtGalleryViewer:_primaryIndexForMeta(meta)
    if not self.image_metas then return nil end
    for i, im in ipairs(self.image_metas) do
        if im == meta then return i end
    end
    return nil
end

function ArtGalleryViewer:_galleryLayout()
    local tab = self._gallery_filter or "all"
    self._gallery_layouts = self._gallery_layouts or {}
    if self._gallery_layouts[tab] then return self._gallery_layouts[tab] end
    local _list, metas, nb = self:_tabList()
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
        local scale = math.min(thumb_w / iw, 1)
        local th = math.floor(ih * scale + 0.5)
        th = math.min(th, m.grid_h - 2 * m.inset)
        th = math.max(th, Screen:scaleBySize(24))
        local cell_h = th + 2 * m.inset
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

function ArtGalleryViewer:_headMetrics()
    if self._head_metrics then return self._head_metrics end
    local t = TextWidget:new{
        text = "Gy", face = Font:getFace("cfont", 16), bold = true }
    local s = TextWidget:new{
        text = "Gy", face = Font:getFace("cfont", 12), bold = true }
    local th1, th2 = t:getSize().h, s:getSize().h
    t:free(); s:free()
    local band_top = Screen:scaleBySize(3) + math.floor(th1 / 4)
    local gap = 0
    local below = Screen:scaleBySize(6)
    self._head_metrics = {
        band_top = band_top, th1 = th1, gap = gap,
        content_top = band_top + th1 + gap + th2 + below,
    }
    return self._head_metrics
end

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

function ArtGalleryViewer:_thumb(i, w, h)
    local THUMB_CACHE_CAP = 256
    self._thumb_bbs = self._thumb_bbs or {}
    self._thumb_keys = self._thumb_keys or {}
    local ckey = (self._gallery_filter or "all") .. ":" .. i
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
        own = true
    end
    if not src then return nil end
    local bw, bh = src:getWidth(), src:getHeight()
    local s = math.min(w / bw, h / bh, 1)
    local bb
    if s < 1 then
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

function ArtGalleryViewer:_buildGallery()
    local layout = self:_galleryLayout()
    local pages = #layout.pages
    self._gallery_page = math.min(math.max(self._gallery_page or 1, 1), pages)
    local m = self:_galleryMetrics()
    local grid = OverlapGroup:new{
        dimen = Geom:new{ w = self.width, h = self.img_container_h },
    }
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
    self:_ensureDerived()
    local f = self._gallery_filter or "all"
    local view_is_primary = (f ~= "ignored")
    local show_corner = (f == "all")
    local cur_meta = self.image_metas
        and self.image_metas[self._images_list_cur or 1]
    local band_top = self:_headMetrics().band_top
    local _list, metas, count = self:_tabList()
    local title_wg = TextWidget:new{
        text = self:_galleryFilterLabel(),
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
    local csize = Screen:scaleBySize(36)
    local off = m.inset + Screen:scaleBySize(2)
    for _, c in ipairs(layout.pages[self._gallery_page] or {}) do
        local bb = self:_thumb(c.idx,
            c.w - 2 * m.inset, c.h - 2 * m.inset)
        if bb then
            local meta = metas and metas[c.idx]
            local is_cur = view_is_primary and (meta == cur_meta)
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
                        image_disposable = false,
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
            if view_is_primary then
                local badge = ArtGalleryBadge:new{ num = c.idx }
                badge.overlap_offset = {
                    c.x + m.inset + Screen:scaleBySize(3),
                    c.y + m.inset + Screen:scaleBySize(3),
                }
                table.insert(grid, badge)
                table.insert(self._gallery_badges, badge)
            end
            if show_corner and meta then
                local fav = self.artgallery
                    and self.artgallery:isFavoriteByKey(self:_favKeyFor(meta))
                    or false
                local ign = self._ignored_set[meta] or false
                local svg
                if fav then
                    svg = _PLUGIN_DIR .. "/assets/favorite_on.svg"
                elseif ign then
                    svg = _PLUGIN_DIR .. "/assets/eyeclosed.svg"
                end
                if svg then
                    local luma = _cornerLuma(bb,
                        bb:getWidth() - 1, bb:getHeight() - 1)
                    local icon = self:_getCornerIcon(svg, csize, luma < 128)
                    if icon then
                        local corner = ArtGalleryCornerBadge:new{
                            icon = icon, size = csize }
                        corner.overlap_offset = {
                            c.x + c.w - off - csize,
                            c.y + c.h - off - csize,
                        }
                        table.insert(grid, corner)
                        table.insert(self._gallery_badges, corner)
                    end
                end
            end
        end
    end
    self.image_container = grid
end

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

function ArtGalleryViewer:_showMoreMenu()
    local items = {}
    if not self._gallery_mode then
        local ratio_text = string.format("%.1f", self.panel_ratio or PANEL_RATIO_DEFAULT)
        items[#items + 1] = {
            text = T(_("面板比例：%1"), ratio_text),
            icon = _PLUGIN_DIR .. "/assets/fullscreen.svg",
            callback = function() self:_cyclePanelRatio() end,
        }
    end
    if _quick_enabled("gallery") then
        items[#items + 1] = {
            text = self:_galleryFilterLabel(),
            icon = _PLUGIN_DIR .. "/assets/gallery.svg",
            callback = function() self:_cycleGalleryFilter() end,
        }
    end
    if _quick_enabled("mode") and not self.is_favorites and not self.is_cbz then
        items[#items + 1] = {
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
        if (self._cur_rotation or 0) ~= 0 then
            items[#items + 1] = {
                text = _("重置旋转"),
                icon = _PLUGIN_DIR .. "/assets/reset-rotation.svg",
                callback = function() self:_setRotation(0) end,
            }
        end
    end
    if _quick_enabled("showinbook") and not self.is_favorites and not self.is_cbz then
        items[#items + 1] = {
            text = _("在书中定位"),
            icon = _PLUGIN_DIR .. "/assets/navigate.svg",
            callback = function() self:_showInBook() end,
        }
    end
    if _quick_enabled("noresidue") then
        items[#items + 1] = {
            text = _("切换比例无残留模式"),
            check = G_reader_settings:isTrue(NO_RESIDUE_KEY),  -- 用独立的设置键
            callback = function()
                G_reader_settings:saveSetting(NO_RESIDUE_KEY,
                    not G_reader_settings:isTrue(NO_RESIDUE_KEY))
            end,
        }
    end
    if _quick_enabled("smartrotate") then
        items[#items + 1] = {
            text = _("智能自动旋转"),
            check = G_reader_settings:nilOrTrue(SMART_ROTATION_KEY),
            callback = function() self:_toggleSmartRotation() end,
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
    if _quick_enabled("darkbg") then
        items[#items + 1] = {
            text = _("抽屉黑色背景"),
            check = G_reader_settings:isTrue(DARK_BG_KEY),
            callback = function() self:_toggleDarkBg() end,
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
            text = _("夜间模式反转图片"),
            check = G_reader_settings:isTrue(INVERT_KEY),
            callback = function() self:_toggleInvert() end,
        }
    end
    if #items == 0 then return end
    local menu
    menu = ArtGalleryPopupMenu:new{
        items = items,
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
    menu._restore_region = self._more_frame and self._more_frame.dimen
        and self._more_frame.dimen:copy()
    menu.on_dismiss = function()
        if self._more_frame then self._more_frame.inverted = nil end
    end
    UIManager:show(menu, function()
        return "ui", menu.movable.dimen
    end)
end

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
    end
    local doc = self.doc_ref
        or (self.artgallery and self.artgallery.ui and self.artgallery.ui.document)
    if doc then return doc.file .. "#" .. im.path end
    return nil
end

function ArtGalleryViewer:_favKeyFor(im)
    if not im then return nil end
    if self.is_cbz and self._zip_path then
        return "cbz:" .. self._zip_path .. "#" .. im.path
    end
    local doc = self.doc_ref
        or (self.artgallery and self.artgallery.ui and self.artgallery.ui.document)
    if doc then return doc.file .. "#" .. im.path end
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
        return
    end
    local key = self:_favKey()
    if key and self.artgallery:isFavoriteByKey(key) then
        self.artgallery:removeFavoriteByKey(key)
    else
        self.artgallery:addFavorite(im, self)
    end
end

function ArtGalleryViewer:_getNoteFromFav(path)
    if not self.artgallery then return nil end
    local records = self.artgallery:_favRecords()
    local filename = path:match("[^/]+$") or path
    for _, r in ipairs(records) do
        if r.file and r.file:match(filename) then
            return r.note
        end
    end
    return nil
end

function ArtGalleryViewer:_hasNote(meta)
    if not meta then return false end
    local note = self:_getNoteFromFav(meta.path)
    return note ~= nil and note ~= ""
end

function ArtGalleryViewer:_addNote()
    local meta = self.image_metas and self.image_metas[self._images_list_cur or 1]
    if not meta then return end

    local existing_note = self:_getNoteFromFav(meta.path)

    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = existing_note and _("编辑备注") or _("添加备注"),
        input = existing_note or "",
        input_hint = _("输入备注文字…"),
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("保存"),
                    callback = function()
                        local text = dialog:getInputText()
                        if text and text ~= "" then
                            self:_saveNoteWithFavorite(meta, text)
                        end
                        UIManager:close(dialog)
                        self:update()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function ArtGalleryViewer:_saveNoteWithFavorite(meta, note)
    if not self.artgallery then return end

    -- 如果未收藏，先收藏
    local key = self:_favKey()
    if not self.artgallery:isFavoriteByKey(key) then
        self.artgallery:addFavorite(meta, self)
    end

    -- 更新备注
    local records = self.artgallery:_favRecords()
    local filename = meta.path:match("[^/]+$") or meta.path
    for _, r in ipairs(records) do
        if r.file and r.file:match(filename) then
            r.note = note
            break
        end
    end
    self.artgallery:_saveFavRecords(records)
end

function ArtGalleryViewer:_removeNoteFromFav(meta)
    if not self.artgallery then return end
    local records = self.artgallery:_favRecords()
    local filename = meta.path:match("[^/]+$") or meta.path
    for _, r in ipairs(records) do
        if r.file and r.file:match(filename) then
            r.note = nil
            break
        end
    end
    self.artgallery:_saveFavRecords(records)
    self:_afterCollectionChange()  -- 刷新菜单状态
end

function ArtGalleryViewer:_rotateCurrent()
    self:_setRotation(((self._cur_rotation or 0) - 90) % 360)
end

function ArtGalleryViewer:_setRotation(rotation)
    self._cur_rotation = rotation
    self._fit_scale_factor = nil
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
    if self._thumb_bbs then
        for _, t in pairs(self._thumb_bbs) do
            if t.bb then t.bb:free() end
        end
        self._thumb_bbs = nil
    end
    self:_resetHiRes()
    if self.image and self.image_disposable and self.image.free then
        self.image:free()
    end
    self.image = self._images_list[cur]
    if type(self.image) == "function" then
        self.image = self.image()
    end
    self:update()
end

function ArtGalleryViewer:_toggleDarkBg()
    G_reader_settings:saveSetting(DARK_BG_KEY,
        not G_reader_settings:isTrue(DARK_BG_KEY))
    self:update()
end

function ArtGalleryViewer:_toggleSmartRotation()
    local old_value = G_reader_settings:nilOrTrue(SMART_ROTATION_KEY)
    G_reader_settings:flipNilOrTrue(SMART_ROTATION_KEY)
    local new_value = G_reader_settings:nilOrTrue(SMART_ROTATION_KEY)

    if old_value == true and new_value == false then
        self:_setRotation(0)
        local meta = self.image_metas and self.image_metas[self._images_list_cur or 1]
        if meta and self.set_pref then
            self.set_pref(meta, "rotation", nil)
        end
    end

    self._auto_rotated_for = nil
    self._smart_failed_for = {}

    if self._thumb_bbs then
        for _, t in pairs(self._thumb_bbs) do
            if t.bb then t.bb:free() end
        end
        self._thumb_bbs = nil
    end
    self._thumb_keys = {}
    self._derived_ok = nil
    self._all_cache = nil
    self._fav_cache = nil
    self:_resetHiRes()

    if self.image and self.image_disposable and self.image.free then
        self.image:free()
    end
    self.image = self._images_list[self._images_list_cur or 1]
    if type(self.image) == "function" then
        self.image = self.image()
    end
    self:update()
end

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

function ArtGalleryViewer:_checkDoubleTap(ges)
    local now = time.now()
    local slop = Screen:scaleBySize(50)
    local lt = self._last_tap
    self._last_tap = { time = now, x = ges.pos.x, y = ges.pos.y }
    if lt and now - lt.time < time.ms(350)
       and math.abs(ges.pos.x - lt.x) <= slop
       and math.abs(ges.pos.y - lt.y) <= slop then
        self._last_tap = nil
        if self._chrome_hide_action then
            UIManager:unschedule(self._chrome_hide_action)
            self._chrome_hide_action = nil
        end
        self:onArtGalleryDoubleTap(nil, ges)
    else
        self:_setChrome(not self._chrome_hidden)
    end
end

function ArtGalleryViewer:onArtGalleryDoubleTap(_, ges)
    local was_fit = self.scale_factor == 0
    local wg = self._image_wg
    if wg and ges and ges.pos then
        wg:getSize()
        local d = wg.dimen
        local cx = d and (d.x + d.w / 2) or Screen:getWidth() / 2
        local cy = d and (d.y + d.h / 2) or Screen:getHeight() / 2
        self._center_x_ratio, self._center_y_ratio =
            wg:getPanByCenterRatio(ges.pos.x - cx, ges.pos.y - cy)
    end
    self:_refreshScaleFactor()
    if was_fit then
        self:_applyNewScaleFactor(self:_maxScale() or self.scale_factor)
    else
        self.scale_factor = 0
        self._center_x_ratio, self._center_y_ratio = 0.5, 0.5
        self:update()
    end
    return true
end

function ArtGalleryViewer:onZoomIn(inc)
    if self._fullscreen_fill == "stretch" and self.scale_factor == 0 then
        local floor = self:_computeFitScaleFactor()
        inc = inc or 0.2
        self:_applyNewScaleFactor(floor * (1 + inc))
        return true
    end
    return ImageViewer.onZoomIn(self, inc)
end

function ArtGalleryViewer:onZoomOut(dec)
    if self._fullscreen_fill == "stretch" and self.scale_factor == 0 then
        return true
    end
    return ImageViewer.onZoomOut(self, dec)
end

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

function ArtGalleryViewer:onTap(_, ges)
    if self.on_show_menu and G_reader_settings:nilOrTrue(TOP_MENU_KEY)
       and self:_inTopMenuZone(ges.pos) then
        self.on_show_menu()
        return true
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
    if not self._gallery_mode and self._more_frame and self._more_frame.dimen
       and ges.pos:intersectWith(self._more_frame.dimen) then
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
    if self._fs_frame and self._fs_frame.dimen
       and ges.pos:intersectWith(self._fs_frame.dimen) then
        self:_flashButton(self._fs_frame, function()
            self:_cyclePanelRatio()
        end)
        return true
    end
    if self._fill_frame and self._fill_frame.dimen
       and ges.pos:intersectWith(self._fill_frame.dimen) then
        self:_flashButton(self._fill_frame, function()
            self:_cycleFullscreenFill()
        end)
        return true
    end
    if self._gallery_btn_frame and self._gallery_btn_frame.dimen
       and ges.pos:intersectWith(self._gallery_btn_frame.dimen) then
        self:_flashButton(self._gallery_btn_frame, function()
            self:_cycleGalleryFilter()
        end)
        return true
    end
    if self._close_btn and self._close_btn.dimen
       and ges.pos:intersectWith(self._close_btn.dimen) then
        self:_flashButton(self._close_btn, function()
            self:onClose()
        end)
        return true
    end
    if self._fav_btn_frame and self._fav_btn_frame.dimen
       and ges.pos:intersectWith(self._fav_btn_frame.dimen) then
        self:_flashButton(self._fav_btn_frame, function()
            self:_toggleFavorite()
            self:_afterCollectionChange()
        end)
        return true
    end
    if self._smart_frame and self._smart_frame.dimen
       and ges.pos:intersectWith(self._smart_frame.dimen) then
        self:_flashButton(self._smart_frame, function()
            self:_toggleSmartRotation()
        end)
        return true
    end
    if self._gallery_mode then
        if self._pill_frame and self._pill_frame.dimen
           and ges.pos:intersectWith(self._pill_frame.dimen) then
            self:_flashButton(self._pill_frame, function()
                self:_cycleGalleryFilter()
            end)
            return true
        end
        local cell = self:_galleryHit(ges.pos)
        if cell then
            local metas = select(2, self:_tabList())
            local meta = metas and metas[cell.idx]
            local pi = meta and self:_primaryIndexForMeta(meta)
            if pi then self:_exitGallery(pi) end
        end
        return true
    end
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
    if not self._chrome_hidden and self.scale_factor == 0 then
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
    self._fit_scale_factor = nil
    self._scale_factor_0 = nil
    self:_resetHiRes()
    self._flash_switch = true
    ImageViewer.switchToImageNum(self, image_num)
    local meta = self.image_metas and self.image_metas[image_num]
    if meta and self.on_image_shown then
        self.on_image_shown(meta, image_num)
    end
end

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

function ArtGalleryViewer:onMultiSwipe(_, ges)
    return true
end

function ArtGalleryViewer:onHold(_, ges)
    if self._fill_frame and self._fill_frame.dimen
       and ges.pos:intersectWith(self._fill_frame.dimen) then
        self:_setDefaultFill(self._fullscreen_fill)
        return true
    end
    if self._fs_frame and self._fs_frame.dimen
      and ges.pos:intersectWith(self._fs_frame.dimen) then
       self:_setDefaultRatio(self.panel_ratio)
       return true
   end
    if self._gallery_mode then
        local cell = self:_galleryHit(ges.pos)
        if cell then
            local metas = select(2, self:_tabList())
            local meta = metas and metas[cell.idx]
            if meta then self:_openImageActionMenu(meta, ges.pos) end
        end
        return true
    end
    if self.scale_factor == 0 then
        local meta = self.image_metas
            and self.image_metas[self._images_list_cur or 1]
        if meta then self:_openImageActionMenu(meta, ges.pos) end
        return true
    end
    return ImageViewer.onHold(self, _, ges)
end

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

function ArtGalleryViewer:_isOverFit()
    if self.scale_factor == 0 then return false end
    local fit = self._fit_scale_factor or self:_computeFitScaleFactor() or 1
    return self.scale_factor > fit + 0.001
end

function ArtGalleryViewer:_computeFitScaleFactor()
    local iw = self.image and self.image.getWidth and self.image:getWidth()
    local ih = self.image and self.image.getHeight and self.image:getHeight()
    if iw and ih and iw > 0 and ih > 0 then
        if self._cur_rotation == 90 or self._cur_rotation == 270 then
            iw, ih = ih, iw
        end
        local w_scale = (self.width - self.image_padding * 2) / iw
        local h_scale = (self.img_container_h - self.image_padding * 2) / ih
        if self._fullscreen_fill == "cover" or self._fullscreen_fill == "stretch" then
            return math.max(w_scale, h_scale)
        end
        return math.min(w_scale, h_scale)
    end
end

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
        return
    end
    if self._fullscreen_fill == "stretch" then
        self._fit_scale_factor = self:_computeFitScaleFactor()
    end
    if self.scale_factor == 0 then
        if self._image_wg then
            self._image_wg:getSize()
        end
        local fit = self._image_wg and self._image_wg:getScaleFactor()
        if not fit or fit <= 0 then
            fit = self:_computeFitScaleFactor()
        end
        if fit and fit > 0 then
            self._fit_scale_factor = fit
            self._scale_factor_0 = fit
        end
    end
    ImageViewer._refreshScaleFactor(self)
end

function ArtGalleryViewer:_applyNewScaleFactor(new_factor)
    if self._gallery_mode then return end
    self._fast_refresh = true
    if self._image_wg then
        self._image_wg:getSize()
    end
    local fit = self._fit_scale_factor
    if not fit then
        fit = self:_computeFitScaleFactor()
        self._fit_scale_factor = fit
    end
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

function ArtGalleryViewer:_maxScale()
    local fit = self:_computeFitScaleFactor() or 1
    return fit * 2
end

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
    self._center_x_ratio, self._center_y_ratio = cx, cy
    self._skip_shadow_paint = true
    self.dithered = false
    local alpha = self.alpha
    self.alpha = false
    UIManager:setDirty(self, function()
        return "ui", wg.dimen or self.main_frame.dimen, false
    end)
    self.alpha = alpha
end

function ArtGalleryViewer:_hideCurrentImage()
    local cur = self._images_list_cur
    local meta = self.image_metas and self.image_metas[cur]
    local closure = self._images_list and self._images_list[cur]
    if meta and self.on_hide then
        self.on_hide(meta)
    end
    if meta then
        if self.shown_metas then
            for i = #self.shown_metas, 1, -1 do
                if self.shown_metas[i] == meta then
                    table.remove(self.shown_metas, i)
                    if self.shown_list then table.remove(self.shown_list, i) end
                    break
                end
            end
        end
        if self.ignored_metas then
            local dup = false
            for _, m in ipairs(self.ignored_metas) do
                if m == meta then dup = true; break end
            end
            if not dup then
                self.ignored_metas[#self.ignored_metas + 1] = meta
                if self.ignored_list and closure then
                    self.ignored_list[#self.ignored_list + 1] = closure
                end
            end
        end
        self:_invalidateGalleryCaches()
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
    self:_resetHiRes()
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
    is_doc_only = false,
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
    logger.dbg("ArtGallery: init (merge of Glimpse + Illustrations)")
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
    if self._bb_cache then
        if self._bb_cache.bb then self._bb_cache.bb:free() end
        self._bb_cache = nil
    end
end

-- ── settings ────────────────────────────────────────────────────────────────

function ArtGallery:getScope()
    return G_reader_settings:readSetting(SCOPE_KEY) or "read_so_far"
end

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

function ArtGallery:_forcedPaths()
    return (self.ui.doc_settings and
            self.ui.doc_settings:readSetting("artgallery_forced")) or {}
end

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
    if type(doc.getDocumentFileContent) ~= "function" then
        return false, _("美术馆仅支持 EPUB 格式（当前文档格式不支持）。")
    end
    return true
end

function ArtGallery:_makeReader(doc)
    doc = doc or self.ui.document
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
            if ok3 and type(d) == "string" and #data > 0 then
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

function ArtGallery:_imagePage(meta, spine_index)
    local doc = self.ui and self.ui.document
    if not doc or not meta or not meta.node_path then return nil end
    local xp = string.format("/body/DocFragment[%d]/body/%s",
        spine_index, meta.node_path)
    local ok, page = pcall(doc.getPageFromXPointer, doc, xp)
    if ok and type(page) == "number" then return page end
    return nil
end

function ArtGallery:_syncReadingProgress(meta)
    if not meta or type(meta.spine_index) ~= "number" or meta.spine_index < 1 then
        return
    end
    local doc = self.ui and self.ui.document
    if not doc then return end

    if self.ui.rolling then
        if G_reader_settings:isFalse(SYNC_PROGRESS_EPUB_KEY) then return end
        local rolling = self.ui.rolling
        if type(rolling.onGotoXPointer) ~= "function" then return end
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

    if self.ui.paging then
        if G_reader_settings:isFalse(SYNC_PROGRESS_KEY) then return end
        local paging = self.ui.paging
        if type(paging.onGotoPage) ~= "function" then return end
        local ok, cur = pcall(function() return self.ui:getCurrentPage() end)
        if not (ok and type(cur) == "number") then return end
        local target = meta.spine_index
        if target <= cur then return end
        if pcall(paging.onGotoPage, paging, target) then
            self._sync_advanced = true
        end
        return
    end
end

-- ── scan + sidecar cache ────────────────────────────────────────────────────

function ArtGallery:_safeFlush(settings)
    if settings then
        logger.dbg("ArtGallery: flushing settings")
        pcall(settings.flush, settings)
    end
end

function ArtGallery:_cachePath()
    local dir = DocSettings:getSidecarDir(self.ui.document.file)
    lfs.mkdir(dir)
    return dir .. "/artgallery.scan.lua"
end

function ArtGallery:_getScan(force, cache_only)
    if self._scan and not force then
        return self._scan
    end
    local doc = self.ui.document
    local a = lfs.attributes(doc.file)
    local mtime = a and a.modification or 0
    local size = a and a.size or 0
    local cache = LuaSettings:open(self:_cachePath())

    if not force then
        local c = cache:readSetting("scan")
        if c and c.version == scanner.VERSION
           and cache:readSetting("mtime") == mtime
           and cache:readSetting("size") == size then
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
    -- 一次完整扫描（读 EPUB/ZIP、解析图片元数据）会产生大量临时表与字节串；
    -- 扫描结束即释放，避免大本书在 KPW3 低内存下堆积（安全点：非热路径、单次）。
    pcall(collectgarbage, "collect")
    return result
end

function ArtGallery:_clearBookCache()
    self._scan = nil
    local ok, path = pcall(self._cachePath, self)
    if ok and path then
        os.remove(path)
    end
end

-- ── rendering ───────────────────────────────────────────────────────────────

local function _flatten_on_white(bb)
    if not bb then return bb end
    local ok, btype = pcall(function() return bb:getType() end)
    if not ok then return bb end
    if btype ~= Blitbuffer.TYPE_BB8A and btype ~= Blitbuffer.TYPE_BBRGB32 then
        return bb
    end
    local w, h = bb:getWidth(), bb:getHeight()
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

local function _mkdirs(path)
    local prefix = path:match("^/") and "/" or ""
    local cur = prefix
    for part in (path .. "/"):gmatch("([^/]+)/") do
        cur = cur .. part
        if not lfs.attributes(cur) then
            lfs.mkdir(cur)
        end
        cur = cur .. "/"
    end
end

function ArtGallery:_favSettings()
    return LuaSettings:open(DataStorage:getDataDir() .. "/artgallery/favorites.lua")
end

function ArtGallery:_favRecords()
    return self:_favSettings():readSetting("favorites") or {}
end

function ArtGallery:_saveFavRecords(t)
    local s = self:_favSettings()
    s:saveSetting("favorites", t)
    logger.dbg("ArtGallery: saved " .. #t .. " favorite records")
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
    local key, doc, zip
    if viewer and viewer.is_cbz and viewer._zip_path then
        zip = viewer._zip_path
        key = "cbz:" .. zip .. "#" .. im.path
    else
        doc = (viewer and viewer.doc_ref)
            or (viewer and viewer.artgallery and viewer.artgallery.ui
                and viewer.artgallery.ui.document)
            or (self.ui and self.ui.document)
        if doc then
            key = doc.file .. "#" .. im.path
        end
    end
    if not key then
        UIManager:show(InfoMessage:new{ text = _("无法收藏此图片。") })
        return
    end
    if self:isFavoriteByKey(key) then
        UIManager:show(InfoMessage:new{ text = _("已在收藏中。") })
        return
    end
    local read_file, close = nil, nil
    if zip then
        read_file, close = self:_makeZipReader(zip)
    else
        read_file, close = self:_makeReader(doc)
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
    _mkdirs(dir)
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
        pcall(os.remove, dest)
        UIManager:show(InfoMessage:new{ text = _("无法写入收藏。") })
        return
    end
    local t = self:_favRecords()
    local live = {}
    for _, r in ipairs(t) do
        if r.file and lfs.attributes(r.file) then
            live[#live + 1] = r
        end
    end
    t = live
    -- 检查是否有已存在的 note（如果该图片之前有备注，保留它）
    local existing_note = nil
    for _, r in ipairs(t) do
        if r.key == key and r.note then
            existing_note = r.note
            break
        end
    end

    t[#t + 1] = {
        file = dest,
        key = key,
        width = im.width or 0,
        height = im.height or 0,
        caption = im.caption,
        note = existing_note,  -- 保留已有备注
    }
    self:_saveFavRecords(t)
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

-- ── 外部画廊 ──────────────────────────────────────────────────────────────

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
    viewer:_enterGallery(1, "all")
    viewer._suppress_refresh = nil
    viewer.alpha = false
    UIManager:show(viewer)
end

-- ── 旧版 Illustrations 收藏迁移 ──────────────────────────────────────────

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

function ArtGallery:showViewer(whole_book_once, skip_scan)
    if self._viewer then
        self._viewer:onClose()
        return
    end
    if not whole_book_once and self:_wholeBookRemembered() then
        whole_book_once = true
    end
    local ok, msg = self:_supportedReason()
    if not ok then
        UIManager:show(InfoMessage:new{ text = msg })
        return
    end

    local scan
    if skip_scan and self._scan then
        scan = self._scan
    else
        scan = self:_getScan(false, true)
        if not scan then
            local info = InfoMessage:new{ text = _("正在扫描书本中的图片…") }
            UIManager:show(info)
            UIManager:forceRePaint()
            scan = self:_getScan()
            UIManager:close(info)
            UIManager:forceRePaint()
        end
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

    local scope_hidden = 0
    local scope = self:getScope()
    if scope ~= "whole_book" and not whole_book_once then
        local cur = self:_currentSpineIndex()
        if cur then
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
                            kept[#kept + 1] = im
                        end
                    end
                end
                return kept
            end
            local before = #shown_metas
            shown_metas = clip(shown_metas)
            scope_hidden = before - #shown_metas
            ignored_metas = clip(ignored_metas)
        end
    end

    local want_ignored_primary = self._review_ignored
        or (self._pending_gallery ~= nil)
    local primary_tab = "shown"
    if #shown_metas == 0 and want_ignored_primary and #ignored_metas > 0 then
        primary_tab = "ignored"
    end
    local imgs = (primary_tab == "shown") and shown_metas or ignored_metas

    if #imgs == 0 then
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
    self._review_ignored = nil

    local read_file, close_reader = self:_makeReader()
    local cap_w = 2 * math.floor(Screen:getWidth() * ArtGalleryViewer.panel_ratio)
    local cap_h = 2 * Screen:getHeight()
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
    local shown_render = make_list(shown_metas)
    local ignored_render = make_list(ignored_metas)
    local images_list = (primary_tab == "shown") and shown_render or ignored_render
    local hires_decode = function(index)
        local im = imgs[index]
        if not im then return nil end
        return decode(im, true)
    end

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

    local s = self:getScope()
    local effective_scope = (s ~= "whole_book" and not whole_book_once)
        and s or "whole_book"

    local viewer
    local first_shown = true
    viewer = ArtGalleryViewer:new{
        image = images_list,
        image_metas = imgs,
        hires_decode = hires_decode,
        shown_metas = shown_metas,
        shown_list = shown_render,
        ignored_metas = ignored_metas,
        ignored_list = ignored_render,
        primary_tab = primary_tab,
        gallery_hidden_count = scope_hidden,
        images_keep_pan_and_zoom = false,
        doc_ref = self.ui and self.ui.document,
        artgallery = self,
        _suppress_refresh = true,
        on_image_shown = function(meta)
            self.ui.doc_settings:saveSetting("artgallery_last", meta.path)
            if first_shown then
                first_shown = false
                return
            end
            self:_syncReadingProgress(meta)
        end,
        on_hide = function(meta)
            local ds = self.ui and self.ui.doc_settings
            if not ds then
                UIManager:show(Notification:new{ text = _("无法忽略此图片。") })
                return
            end
            local h = self:_hiddenPaths()
            h[meta.path] = true
            ds:saveSetting("artgallery_hidden", h)
            self:_safeFlush(ds)
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
        on_rotate = function(rotation, skip_scan)
            self.ui.view:onSetRotationMode(rotation)
            self:showViewer(whole_book_once, skip_scan)
        end,
        on_show_menu = function()
            self.ui:handleEvent(Event:new("ShowMenu"))
        end,
        scope = effective_scope,
        on_toggle_scope = function()
            local order = { whole_book = "read_so_far",
                            read_so_far = "current_page",
                            current_page = "whole_book" }
            local new_scope = order[effective_scope] or "whole_book"
            G_reader_settings:saveSetting(SCOPE_KEY, new_scope)
            self:_forgetWholeBook()
            if self._viewer then self._viewer:onClose() end
            self:showViewer()
            local label = new_scope == "whole_book"
                and _("模式：所有图片")
                or new_scope == "read_so_far"
                and _("模式：仅当前章节之前")
                or _("模式：仅显示已读到的图片")
            UIManager:show(Notification:new{ text = label })
        end,
        hidden_count = function() return self:_hiddenCount() end,
        on_restore_hidden = function()
            self.ui.doc_settings:delSetting("artgallery_hidden")
            if self._viewer then self._viewer:onClose() end
            self:showViewer()
        end,
        on_ignore = function(meta, tab, page)
            local ds = self.ui and self.ui.doc_settings
            if not ds then
                UIManager:show(Notification:new{ text = _("无法忽略此图片。") })
                return
            end
            local h = self:_hiddenPaths(); h[meta.path] = true
            local f = self:_forcedPaths(); f[meta.path] = nil
            ds:saveSetting("artgallery_hidden", h)
            ds:saveSetting("artgallery_forced", next(f) and f or nil)
            self:_safeFlush(ds)
            self._pending_gallery = { tab = tab, page = page }
            if self._viewer then self._viewer:onClose() end
            self:showViewer(whole_book_once)
            UIManager:show(Notification:new{ text = _("已移动到忽略列表") })
        end,
        on_unignore = function(meta, tab, page)
            local ds = self.ui and self.ui.doc_settings
            if not ds then
                UIManager:show(Notification:new{ text = _("无法忽略此图片。") })
                return
            end
            local f = self:_forcedPaths(); f[meta.path] = true
            local h = self:_hiddenPaths(); h[meta.path] = nil
            ds:saveSetting("artgallery_forced", f)
            ds:saveSetting("artgallery_hidden", next(h) and h or nil)
            self:_safeFlush(ds)
            self._pending_gallery = { tab = tab, page = page }
            if self._viewer then self._viewer:onClose() end
            self:showViewer(whole_book_once)
            UIManager:show(Notification:new{ text = _("已添加回图库") })
        end,
    }
    self._viewer = viewer

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
        -- 全屏 viewer 拆除：其解码的全屏位图（≈0.8MB/张）随之可回收。
        -- 在 KPW3 低内存下及时显式 GC，避免退出看图后内存仍居高不下（安全点：
        -- 关闭流程末尾、close_reader 之前，不在绘制热路径）。
        pcall(collectgarbage, "collect")
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

    if self._pending_gallery then
        local pg = self._pending_gallery
        self._pending_gallery = nil
        local tab = pg.tab
        if tab == "shown" then tab = "all" end
        local n = (tab == "ignored") and #ignored_metas or #shown_metas
        if n == 0 then tab = (tab == "ignored") and "all" or "ignored" end
        viewer:_enterGallery(pg.page, tab)
    elseif primary_tab == "ignored" then
        viewer:_enterGallery(1, "ignored")
    end
    viewer._suppress_refresh = nil
    viewer.alpha = false
    local open_w = viewer._panel_w + 2
    if not G_reader_settings:isTrue(SHADOW_KEY) then
        open_w = viewer._panel_w
            + 2 * viewer.shadow_width - viewer.shadow_overlap + 1
    end
    viewer._reader_refresh_count = UIManager.refresh_count
    UIManager.refresh_count = 0
    UIManager:show(viewer, Device:hasKaleidoWfm() and "partial" or "ui",
        Geom:new{
            x = 0, y = 0,
            w = math.min(Screen:getWidth(), open_w),
            h = Screen:getHeight(),
        }, nil, nil, true)
    viewer.alpha = nil
end

-- ── GitHub auto-update ──────────────────────────────────────────────────────

local GH_TOKEN_KEY = "artgallery_github_token"
local PRERELEASE_KEY = "artgallery_update_prerelease"

local function _installed_version()
    local ok, meta = pcall(dofile, _PLUGIN_DIR .. "/_meta.lua")
    if ok and type(meta) == "table" and meta.version then
        return tostring(meta.version)
    end
    return "0"
end

local function _parse_ver(s)
    local t = {}
    for n in tostring(s):gsub("^[vV]", ""):gmatch("%d+") do
        t[#t + 1] = tonumber(n)
    end
    return t
end

local function _ver_gt(a, b)
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
    local ok3, J = pcall(require, "json")
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

    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT,
        socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, code, resp_headers = requester.request{
        url      = url,
        method   = "GET",
        headers  = headers,
        sink     = sink,
        redirect = false,
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
    logger.dbg("ArtGallery: update check start -> " .. api)
    -- fetch in a subprocess so the UI stays responsive and dismissable
    local completed, body = Trapper:dismissableRunInSubprocess(function()
        local b, err = _http_fetch(api)
        return b or ("ERR:" .. tostring(err))
    end, _("正在检查更新…"), true)
    if not completed then return end
    if not completed then return end -- dismissed by the user
    logger.dbg("ArtGallery: update check returned, completed="
        .. tostring(completed) .. ", body_len=" .. (body and #body or 0))
    if not body or body:match("^ERR:") then
        UIManager:show(InfoMessage:new{
            text = _("更新检查失败：") .. "\n"
                .. ((body or "无响应"):gsub("^ERR:", "")) })
        return
    end
    local rel
    if pre then
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
    self._menu_file = file
    menu_items.artgallery = {
        text = _("美术馆"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:_menuItems()
        end,
    }
end

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
            enabled_func = function() return self.ui and self.ui.document ~= nil end,
            callback = function(touchmenu_instance)
                if touchmenu_instance then
                    touchmenu_instance:closeMenu()
                end
                local ag_doc = self.ui and self.ui.document
                local ag_file = ag_doc and ag_doc.file
                UIManager:scheduleIn(0.3, function()
                    if not (self.ui and self.ui.document == ag_doc
                            and self.ui.document.file == ag_file) then
                        return
                    end
                    self:showViewer()
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
            text = _("智能自动旋转图片"),
            help_text = _("开启后，插件会自动判断图片朝向，选择能填满更多屏幕的方向显示。关闭则保持图片原始方向。"),
            checked_func = function()
                return G_reader_settings:nilOrTrue(SMART_ROTATION_KEY)
            end,
            callback = function()
                G_reader_settings:flipNilOrTrue(SMART_ROTATION_KEY)
            end,
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
                    text = _("抽屉模式黑色背景"),
                    help_text = _("开启后，抽屉模式的图片背景变为黑色。关闭则保持白色卡片背景。"),
                    checked_func = function()
                        return G_reader_settings:isTrue(DARK_BG_KEY)
                    end,
                    callback = function()
                        G_reader_settings:saveSetting(DARK_BG_KEY,
                            not G_reader_settings:isTrue(DARK_BG_KEY))
                    end,
                },
                {
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
            callback = function(touchmenu_instance)
                local guide = _(
                    "【单图浏览】\n" ..
                    "· 上一图 / 下一图：屏幕左右两侧的 ◀ ▶ 按钮，或按设备的翻页键，在图片之间切换。\n" ..
                    "· 面板比例切换（左下角）：短按在 0.5 / 0.8 / 1.0 之间循环，长按将当前比例设为默认。\n" ..
                    "· 全屏填充模式（铺满 / 适配 / 拉伸）：底部按钮，短按在三种模式间循环——铺满（裁切溢出、填满屏幕）/ 适配（留白全图、完整显示）/ 拉伸（变形填充、铺满屏幕）；长按可将当前模式设为默认全屏看图方式。\n" ..
                    "· 缩放与平移：双指或双击放大，放大后拖动平移；双击或点按底部圆点恢复 100%。\n" ..
                    "· 点击图片切换底部按钮的显示/隐藏（沉浸式阅读）。\n" ..
                    "\n【⋯ 更多菜单】\n" ..
                    "· 面板比例：显示当前比例，点击进入循环切换。\n" ..
                    "· 图库（全部 / 收藏 / 忽略）：查看本书筛选后的全部图片、仅收藏、仅忽略；点按在三者间循环。\n" ..
                    "· 模式（防剧透范围）：在「所有图片 / 仅显示已读到的图片 / 仅当前章节之前」间切换，控制美术馆扫描到的图片范围。\n" ..
                    "· 旋转 90° / 重置旋转：旋转当前图片（旋转后会出现「重置旋转」项）。\n" ..
                    "· 在书中定位：跳回图片在书中的原始位置（插图文字书适用）。\n" ..
                    "· 恢复被忽略的图片：把被忽略的图片重新放回图库（存在被忽略图片时才出现）。\n" ..
                    "· 显示导航按钮 / 显示图片标题 / 夜间模式反转图片：均为开关项，勾选即时生效（分别显示 ◀▶、图片标题、夜间反转图片明暗）。\n" ..
                    "· ⤢ 全屏查看 / 退出全屏：进入或退出全屏沉浸式。\n" ..
                    "· ▦ 图库（全部 / 收藏 / 忽略）：查看本书筛选后的全部图片、仅收藏、仅忽略；点按在三者间循环。\n" ..
                    "· ◎ 模式（防剧透范围）：在「所有图片 / 仅显示已读到的图片 / 仅当前章节之前」间切换，控制美术馆扫描到的图片范围。\n" ..
                    "· ↻ 旋转 90° / ↺ 重置旋转：旋转当前图片（旋转后会出现「重置旋转」项）。\n" ..
                    "· ➤ 在书中定位：跳回图片在书中的原始位置（插图文字书适用）。\n" ..
                    "· ↩ 恢复被忽略的图片：把被忽略的图片重新放回图库（存在被忽略图片时才出现）。\n" ..
                    "· ☑ 显示导航按钮 / 显示图片标题 / 夜间模式反转图片：均为开关项（菜单中以勾选框标记），勾选即时生效（分别显示 ◀▶、图片标题、夜间反转图片明暗）。\n" ..
                    "\n【长按图片】\n" ..
                    "· 长按任意图片弹出三选一菜单：⭐ 收藏图片 / 取消收藏、忽略图片 / 取消忽略。已处于对应状态的选项会自动置灰（不可用）。\n" ..
                    "\n【图库（网格视图）】\n" ..
                    "· 底部圆点表示当前页码，可点按快速跳转；底部按钮为「图库（全部 / 收藏 / 忽略）」三态循环。\n" ..
                    "· 点按缩略图回到对应的单图查看；右上角数字为该图在全部图片中的序号。\n" ..
                    "· 「全部」视图下：已收藏图片右下角显示 ⭐，已忽略图片右下角显示 👁 划掉的眼睛。角标会按所在位置明暗自动反白以保证可见。\n" ..
                    "\n【收藏与忽略】\n" ..
                    "· 收藏：图片存入设备收藏夹，跨书本持久保存；可在「图库（收藏）」回顾，或在插件菜单「清除收藏」批量移除。\n" ..
                    "· 忽略：将被剧透或不想要的图片移出图库（防剧透），可在「图库（忽略）」查看，或长按「取消忽略」放回图库。\n" ..
                    "\n【CBZ 漫画】\n" ..
                    "· 在文件管理器中选中 .cbz 漫画压缩包，经插件菜单「浏览 CBZ 漫画」用美术馆全屏翻阅其页面图片。\n" ..
                    "\n【快捷动作设置】\n" ..
                    "· 插件的「快捷动作」可自定义 ⋯ 菜单与按钮中显示哪些功能；关闭全部后 ⋯ 按钮会自动隐藏。"
                )
                -- 说明文本较长，用 TextViewer（全屏可滚动长文本）承载，不裁切。
                -- 根因（v1.0.12 后由 KPW3 真机带调用栈日志彻底锁定）：
                -- 白闪/无弹窗的真凶不是本插件弹窗逻辑，而是同机安装的
                -- BookLoadCover Plus 补丁（patches/2-bookloadcover-plus.lua）。其
                -- patchUIManagerShow 在 shouldSuppressClosingNotice() 为真时，对文本
                -- 同时含「关闭」与「书」的 widget 误判为「关闭书籍」弹窗，并将它的
                -- paintTo 清空为 function() end、visible=false 静默吞掉——onShow 仍会
                -- 触发，但 paintTo 永不调用，故屏幕上看不到弹窗（用户感知为白闪/无弹窗）。
                -- 本「关于」长文本恰好同时含这两字（如「关闭全部」「在书中定位」），
                -- 命中其 { "关闭", "书" } 中文判定（textLooksLikeClosingBookNotice）。
                -- 这也呼应两点：早期 InfoMessage 短文本能弹（文本不含该组合）；
                -- poker24 的规则弹窗不闪（其文本未命中）。
                -- 修复：show 后检测其写入的 _bookloadcover_suppressed 标记，若存在则
                -- 恢复被篡改的 paintTo / visible / hasVisibleContent 并触发重绘。
                if touchmenu_instance then touchmenu_instance:closeMenu() end
                local tv = TextViewer:new{
                    title = _("关于 美术馆"),
                    text = guide .. "\n\n--------\n\n" ..
                        T(_("美术馆 / ArtGallery v%1\n\n基于 Glimpse 合并 Illustrations 的全屏看图能力。\n作者：ksaMask123\n更新：GitHub ksaMask123/artgallery.koplugin"),
                            _installed_version()),
                    modal = true,
                    -- 关于说明为纯只读文档，关闭顶部冗余菜单图标（参考 poker24 的
                    -- showRules）；同时消除 TextViewer 内部菜单（ButtonDialog）遮蔽隐患。
                    show_menu = false,
                    close_callback = function()
                        if self._viewer then
                            UIManager:setDirty(self._viewer, "ui")
                        end
                    end,
                }
                local _tv_shown_at = os.clock()
                local _tv_orig_onTapClose = tv.onTapClose
                tv.onTapClose = function(self, arg, ges_ev)
                    if os.clock() - _tv_shown_at < 0.3 then
                        return true
                    end
                    return _tv_orig_onTapClose(self, arg, ges_ev)
                end
                UIManager:show(tv)
                -- 兼容 BookLoadCover Plus 补丁的「关闭书籍」误判：若本弹窗被其静默，
                -- 恢复被清空的 paintTo 与被置否的可见标记，并强制重绘。
                -- 防御性：仅当原始 paintTo 仍是函数时才恢复，避免字段名变更导致崩溃。
                if tv._bookloadcover_suppressed and type(tv._original_paintTo_bookloadcover) == "function" then
                    tv.paintTo = tv._original_paintTo_bookloadcover
                    tv.visible = true
                    tv.hasVisibleContent = true
                    UIManager:setDirty(tv, "ui")
                end
            end,
        },
    }
end

return ArtGallery
