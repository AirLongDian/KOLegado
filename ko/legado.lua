-- Single embedded reader. Keep upstream layout, page buffers and Android submission intact.
-- No source rules here: Legado owns network, parsing and the original chapter cache.
local A = require("android")
local ffi = require("ffi")
local function java(method, signature, ...)
    local args = {...}
    for i, value in ipairs(args) do args[i] = ffi.new("int32_t", value) end
    return A.jni:context(A.app.activity.vm, function(jni)
        if signature:sub(-1) == "V" then
            return jni:callVoidMethod(A.app.activity.clazz, method, signature, unpack(args))
        end
        local value = jni:callObjectMethod(A.app.activity.clazz, method, signature, unpack(args))
        if signature:sub(-18) == "Ljava/lang/String;" then
            local text = jni:to_string(value)
            jni.env[0].DeleteLocalRef(jni.env, value)
            return text
        end
        return value
    end)
end

require("defaults")
-- Bound the page-cache budget on this ~300 MiB device; keep KO's pre-rendering intact.
DGLOBAL_CACHE_SIZE_MINIMUM = 8 * 1024 * 1024
DGLOBAL_CACHE_SIZE_MAXIMUM = 16 * 1024 * 1024
DGLOBAL_CACHE_FREE_PROPORTION = 0.15
require("setupkoenv")
local lfs = require("libs/libkoreader-lfs")
local state = A.dir .. "/state"
lfs.mkdir(state)
lfs.mkdir(state .. "/cache")
lfs.mkdir(state .. "/settings")
-- Do not create/use the standalone app's /sdcard/koreader tree.
package.loaded.datastorage = {
    getDataDir = function() return state end,
    getFullDataDir = function() return state end,
    getSettingsDir = function() return state .. "/settings" end,
    getHistoryDir = function() return state .. "/history" end,
}
local LuaSettings = require("luasettings")
G_reader_settings = LuaSettings:open(state .. "/settings.reader.lua")
local defaults = {
    language = "zh_CN", color_rendering = false, night_mode = false,
    cre_storage_size_factor = 1, cre_disk_cache_max_size = 0,
    copt_font_size = 24, copt_font_face = "Noto Sans CJK SC", copt_view_mode = 0,
    hide_header = true, reader_footer_mode = 0,
    back_in_reader = "filemanager", back_to_exit = "always",
    ges_tap_interval_on_keyboard = 0, filemanager_show_hidden_files = false,
}
for key, value in pairs(defaults) do
    if not G_reader_settings:has(key) then G_reader_settings:saveSetting(key, value) end
end
G_reader_settings:saveSetting("color_rendering", false)
local _ = require("gettext")
_.changeLang("zh_CN")
local bb = require("ffi/blitbuffer")
bb:setUseCBB(true)
bb:enableCBB(true)
local Device = require("device")
require("document/canvascontext"):init(Device)
require("ui/bidi").setup("zh_CN")

-- No per-chapter .sdr folders, reading history, exported book or serialized page files.
local DocSettings = require("docsettings")
DocSettings.open = function(self)
    local appearance = G_reader_settings:readSetting("legado_appearance") or {}
    local data = {}
    for key, value in pairs(appearance) do data[key] = value end
    return setmetatable({data = data}, {__index = self})
end
DocSettings.flush = function(self)
    local appearance = {}
    for key, value in pairs(self.data) do
        if key:match("^copt_") or key == "font_face" or key == "font_size"
            or key == "line_space_percent" then appearance[key] = value end
    end
    G_reader_settings:saveSetting("legado_appearance", appearance)
end
DocSettings.ensureSidecar = function() end
DocSettings.hasSidecarFile = function() return false end
local History = require("readhistory")
History.addItem = function() end
History.removeItemByPath = function() end
History.flush = function() end
local DocCache = require("document/doccache")
DocCache.serialize = function() end
DocCache.disk_cache = false
local CreDocument = require("document/credocument")
-- Native cache starts disabled. Do not initialize it: even a zero-size cache writes an index.
CreDocument.cacheInit = function() end
local Registry = require("document/documentregistry")
Registry:addProvider("nb", "text/plain", CreDocument)

local UIManager = require("ui/uimanager")
-- The native KO light widget avoids the broken Android dialog compositor on
-- this ROM while retaining KO's normal brightness controls.
Device.showLightDialog = function()
    UIManager:show(require("ui/widget/frontlightwidget"):new{})
end
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local ReaderUI = require("apps/reader/readerui")
local ReaderFooter = require("apps/reader/modules/readerfooter")
local footer_settings = G_reader_settings:readSetting("footer") or {}
for key, value in pairs(ReaderFooter.default_settings) do
    if footer_settings[key] == nil then footer_settings[key] = value end
end
-- Off by default, but initialized: KO's resize/TocReset handlers still touch it.
footer_settings.disabled = false
if not G_reader_settings:has("legado_footer_v2") then
    footer_settings.disable_progress_bar = true
    footer_settings.reclaim_height = true
    G_reader_settings:saveSetting("reader_footer_mode", 0)
    G_reader_settings:saveSetting("legado_footer_v2", true)
end
G_reader_settings:saveSetting("footer", footer_settings)
local active, pending, busy, quitting = nil, nil, false, false
local function savePosition()
    local reader = ReaderUI.instance
    if reader and reader.rolling and reader.document and active then
        local ok, value = pcall(reader.rolling.getLastPercent, reader.rolling)
        if ok then java("koPosition", "(II)V", active.index, math.floor(value * 10000 + 0.5)) end
    end
end
local function leave()
    if quitting then return true end
    quitting = true
    savePosition()
    if ReaderUI.instance then ReaderUI.instance:onClose() end
    UIManager:quit()
    return true
end
local function chapter(direction)
    if busy then return true end
    savePosition()
    busy = true
    java("koChapter", "(I)V", direction)
    return true
end

-- Keep the dependency, but make *every* file-manager fallback return to the shelf.
ReaderUI.showFileManager = leave
ReaderUI.onHome = leave
require("apps/filemanager/filemanager").showFiles = leave
require("apps/reader/modules/readerback").onBack = leave
require("apps/reader/modules/readerstatus").onEndOfBook = function() return chapter(1) end
local originalShowReader = ReaderUI.doShowReader
ReaderUI.doShowReader = function(self, file, provider)
    local ok, result = xpcall(function() return originalShowReader(self, file, provider) end, debug.traceback)
    if not ok then
        A.LOG(ffi.C.ANDROID_LOG_ERROR, "reader open failed: " .. tostring(result), "LegadoKO")
        error(result)
    end
    if not ReaderUI.instance then
        A.LOG(ffi.C.ANDROID_LOG_ERROR, "reader open returned without instance: " .. file, "LegadoKO")
    else
        UIManager:setDirty("all", "full")
        UIManager:forceRePaint()
    end
    return result
end

-- Keep KO's own typesetting and settings menus; only cut file/library routes.
local ReaderMenu = require("apps/reader/modules/readermenu")
-- A chapter cache file has no embedded ToC. Route every KO ToC action to
-- Legado's real book-wide chapter list, including shortcuts outside the menu.
require("apps/reader/modules/readertoc").onShowToc = function()
    java("koToc", "()V")
    return true
end
local originalSetMenu = ReaderMenu.setUpdateItemTable
ReaderMenu.setUpdateItemTable = function(self)
    self.menu_items.filemanager = nil
    self.menu_items.history = nil
    self.menu_items.collections = nil
    self.menu_items.open_previous_document = nil
    self.menu_items.reset_document_settings = nil
    self.menu_items.exit_menu = nil
    self.menu_items.exit = nil
    self.menu_items.table_of_contents = {
        text = "章节目录",
        callback = function() java("koToc", "()V") end,
    }
    self.menu_items.legado_previous_chapter = {
        text = "上一章", sorting_hint = "navi", callback = function() chapter(-1) end,
    }
    self.menu_items.legado_next_chapter = {
        text = "下一章", sorting_hint = "navi", callback = function() chapter(1) end,
    }
    self.menu_items.legado_change_source = {
        text = "换源", sorting_hint = "navi", callback = function()
            self:onTapCloseMenu()
            savePosition()
            java("koChangeSource", "()V")
            return true
        end,
    }
    self.menu_items.legado_return_shelf = {
        text = "返回书架", sorting_hint = "main", callback = leave,
    }
    originalSetMenu(self)
    -- Upstream registers some entries *inside* setUpdateItemTable, after the
    -- pre-filter above. Prune the assembled tree, keeping KO's settings tabs.
    local blocked = {
        filemanager = true, history = true, collections = true,
        open_previous_document = true, reset_document_settings = true,
        exit_menu = true, exit = true,
    }
    local function prune(items)
        for i = #items, 1, -1 do
            local item = items[i]
            if blocked[item.id] then
                table.remove(items, i)
            else
                if item.id == "table_of_contents" then
                    item.text = "章节目录"
                    item.callback = function() java("koToc", "()V") end
                end
                if type(item.sub_item_table) == "table" then prune(item.sub_item_table) end
            end
        end
    end
    prune(self.tab_item_table)
end

local ReaderRolling = require("apps/reader/modules/readerrolling")
local originalTurn = ReaderRolling.onGotoViewRel
ReaderRolling.onGotoViewRel = function(self, diff)
    if diff < 0 and ((self.view.view_mode == "page" and self.current_page <= 1)
        or (self.view.view_mode == "scroll" and self.current_pos <= 0)) then return chapter(-1) end
    local result = originalTurn(self, diff)
    savePosition()
    return result
end
local originalInit = ReaderUI.init
ReaderUI.init = function(self)
    originalInit(self)
    if pending then
        active = pending
        pending = nil
        if self.rolling then self.rolling:onGotoPercent(active.percent / 100) end
    end
    savePosition()
end

-- No UI/framebuffer processing in the bridge: polling only transfers tiny metadata.
local json = require("json")
local loading
local function syncSurface()
    if A.app.window == nil then return end
    if A.screen.width == A.getScreenWidth() and A.screen.height == A.getScreenHeight() then return end
    Device.screen:resize()
    local size = Device.screen:getSize()
    UIManager:broadcastEvent(Event:new("SetDimensions", size))
    UIManager:broadcastEvent(Event:new("ScreenResize", size))
    UIManager:broadcastEvent(Event:new("RedrawCurrentPage"))
end
local function poll()
    if quitting then return end
    syncSurface()
    local payload = java("koPoll", "()Ljava/lang/String;")
    if payload and payload ~= "" then
        busy = false
        local item = json.decode(payload)
        if item.path then
            if loading then UIManager:close(loading); loading = nil end
            pending = item
            ReaderUI:showReader(item.path, CreDocument)
        elseif item.error or item.message then
            if loading then UIManager:close(loading); loading = nil end
            local timeout
            if not item.error then timeout = 2 end
            UIManager:show(InfoMessage:new{
                text = item.error or item.message,
                timeout = timeout,
                dismiss_callback = not active and leave or nil,
            })
        end
    end
    UIManager:scheduleIn(0.1, poll)
end
-- A persistent background keeps the native loop alive while the first network load is pending.
loading = InfoMessage:new{text = "正在读取章节…", dismiss_callback = leave}
UIManager:show(loading)
UIManager:scheduleIn(0, poll)
local ok, err = xpcall(function() UIManager:run() end, debug.traceback)
savePosition()
if ReaderUI.instance then ReaderUI.instance:onClose() end
G_reader_settings:flush()
-- Native host finishes only this Activity; never os.exit() the shared app process.
if not ok then error(err) end
