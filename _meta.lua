local _ = require("gettext")
return {
    -- 注意：KOReader 2026.07.1 起 `_meta.lua` 的 `name` 字段已弃用（将忽略，
    -- 插件名改由目录名推导，即 artgallery.koplugin → "artgallery"），保留它会
    -- 在 crash.log 打印 WARN。故此处不写 name。
    fullname = _("美术馆 / ArtGallery"),
    description = _("浏览本书中的地图、族谱和其他参考图片，不丢失阅读位置；支持抽屉预览与一键全屏查看，可缩放、平移、收藏。基于 Glimpse 合并 Illustrations 的全屏看图能力。"),
    author = "ksaMask123",
    version = "1.0.14",
}