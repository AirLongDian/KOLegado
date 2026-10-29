-- Host-side contract test; intentionally stubs Android/engine, not a device performance test.
local ffi = require("ffi")
ffi.cdef[[enum { ANDROID_LOG_INFO = 4, ANDROID_LOG_ERROR = 6 };]]
local loaded = package.loaded
local calls, scheduled, opens = {}, {}, {}
local Reader, Rolling, Menu, FileManager, Back, Status, Config, Toc = {}, {}, {}, {}, {}, {}, {}, {}
local Settings = {}
function Settings:open() return setmetatable({data = {}}, {__index = self}) end
function Settings:has(k) return self.data[k] ~= nil end
function Settings:readSetting(k) return self.data[k] end
function Settings:saveSetting(k,v) self.data[k] = v end
function Settings:flush() end
local function widget() return {new = function(_, t) return t end} end
local payload, decoded = "", nil
local surface_height, resize_count = 800, 0
local jni = {env = {[0] = {DeleteLocalRef = function() end}}}
function jni:to_string(v) return v end
function jni:callObjectMethod(_, name, signature)
    assert(name == "koPoll" and signature == "()Ljava/lang/String;")
    local result = payload; payload = ""; return result
end
function jni:callVoidMethod(_, name, signature, ...)
    local args = {...}
    for _, v in ipairs(args) do assert(ffi.istype("int32_t", v), "JNI integers must not be C vararg doubles") end
    calls[#calls + 1] = {name, signature, unpack(args)}
end
loaded.android = {dir = "host-test", LOG = function() end, app = {activity = {vm = {}, clazz = {}}}, jni = {
    context = function(_, _, fn) return fn(jni) end,
}, screen = {width = 600, height = 800},
getScreenWidth = function() return 600 end,
getScreenHeight = function() return surface_height end}
loaded.defaults, loaded.setupkoenv = true, true
loaded["libs/libkoreader-lfs"] = {mkdir = function() end}
loaded.luasettings = Settings
loaded.gettext = {changeLang = function() end}
loaded["ffi/blitbuffer"] = {setUseCBB = function() end, enableCBB = function() end}
loaded.device = {screen = {
    getWidth = function() return 600 end,
    getSize = function() return {w = 600, h = surface_height} end,
    resize = function()
        resize_count = resize_count + 1
        loaded.android.screen.height = surface_height
    end,
}}
loaded["document/canvascontext"] = {init = function() end}
loaded["ui/bidi"] = {setup = function() end}
loaded.docsettings, loaded.readhistory = {}, {}
loaded.pluginloader = {loadPlugins = function() return {{name = "test-plugin"}}, {} end}
loaded["ui/widget/frontlightwidget"] = widget()
loaded["document/doccache"], loaded["document/credocument"] = {}, {provider = "crengine"}
loaded["document/documentregistry"] = {addProvider = function(_, ext, mime) assert(ext == "nb" and mime == "text/plain") end}
loaded["ui/event"] = {new = function(_, ...) return {...} end}
loaded["ui/widget/infomessage"], loaded["ui/widget/menu"] = widget(), widget()
loaded.json = {decode = function() return decoded end}
loaded["apps/reader/readerui"] = Reader
loaded["apps/filemanager/filemanager"] = FileManager
loaded["apps/reader/modules/readerback"] = Back
loaded["apps/reader/modules/readerstatus"] = Status
loaded["apps/reader/modules/readermenu"] = Menu
loaded["apps/reader/modules/readertoc"] = Toc
loaded["apps/reader/modules/readerrolling"] = Rolling
loaded["apps/reader/modules/readerconfig"] = Config
loaded["apps/reader/modules/readerfooter"] = {default_settings = {container_height = 10, container_bottom_padding = 1}}
function Menu:init() self.menu_items = {
    filemanager = {callback = function() error("File manager reached") end},
    history = {}, collections = {}, open_previous_document = {},
    reset_document_settings = {}, exit_menu = {}, exit = {},
    table_of_contents = {}, navi = {}, typeset = {}, setting = {}, main = {},
} end
function Menu:onTapCloseMenu() self.closed = true end
function Menu:setUpdateItemTable()
    self.menu_items.table_of_contents = {text = "目录", callback = function() error("KO TOC reached") end}
    self.tab_item_table = {
        {id = "navi", sub_item_table = {
            {id = "table_of_contents", text = "目录", callback = self.menu_items.table_of_contents.callback},
            {id = "history", text = "历史"},
        }},
        {id = "typeset", sub_item_table = {}},
        {id = "setting", sub_item_table = {}},
    }
end
function Rolling:getLastPercent() return self.current_page / 10 end
function Rolling:onGotoPercent(percent) self.current_page = math.max(1, math.floor(percent / 10)) end
function Rolling:onGotoViewRel(diff) self.current_page = math.max(1, math.min(10, self.current_page + diff)); return true end
function Reader:init() Reader.instance = self end
function Reader:onClose() Reader.instance = nil end
function Reader:showReader(path, provider)
    assert(provider == loaded["document/credocument"])
    opens[#opens + 1] = path
    local obj = setmetatable({document = {}, rolling = setmetatable({current_page = 1, current_pos = 0,
        view = {view_mode = "page"}}, {__index = Rolling})}, {__index = Reader})
    obj:init()
end
local UI = {shown = {}, _window_stack = {}}
loaded["ui/uimanager"] = UI
function UI:show(widget) self.shown[#self.shown + 1] = widget end
function UI:close() end
function UI:quit() self.quit_called = true end
function UI:broadcastEvent() end
function UI:scheduleIn(_, callback) scheduled[#scheduled + 1] = callback end
local function deliver(item)
    payload, decoded = "payload", item
    local callback = table.remove(scheduled, 1)
    assert(callback, "No bridge polling task")
    callback()
end
function UI:run()
    deliver{error = "书源规则错误"}
    assert(self.shown[#self.shown].timeout == nil, "Chapter errors must remain visible until dismissed")
    assert(type(self.shown[#self.shown].dismiss_callback) == "function")
    assert(not self.quit_called, "A source error must not close the reader automatically")
    -- First chapter is an existing cache pathname, restored at chapter-relative 30%.
    deliver{path = "/book_cache/a/00001-hash.nb", index = 1, title = "一", percent = 3000}
    assert(opens[1] == "/book_cache/a/00001-hash.nb")
    assert(Reader.instance.rolling.current_page == 3)
    loaded.android.app.window = {}
    surface_height = 900
    deliver{}
    assert(resize_count == 1 and loaded.android.screen.height == 900, "surface resize must relayout")
    Reader.instance.rolling:onGotoViewRel(1)
    local position = calls[#calls]
    assert(position[1] == "koPosition" and tonumber(position[3]) == 1 and tonumber(position[4]) == 4000)
    -- End-of-chapter requests next chapter once, even on repeated taps while loading.
    local count = #calls
    Status:onEndOfBook(); Status:onEndOfBook()
    local chapterCalls = 0
    for i = count + 1, #calls do if calls[i][1] == "koChapter" then chapterCalls = chapterCalls + 1; assert(tonumber(calls[i][3]) == 1) end end
    assert(chapterCalls == 1)
    deliver{path = "/book_cache/a/00002-hash.nb", index = 2, title = "二", percent = 0}
    assert(Reader.instance.rolling.current_page == 1)
    Reader.instance.rolling:onGotoViewRel(-1)
    assert(calls[#calls][1] == "koChapter" and tonumber(calls[#calls][3]) == -1)
    deliver{message = "已到第一章"}
    assert(Reader.instance ~= nil, "Boundary must retain current reader")
    local menu = setmetatable({ui = Reader.instance}, {__index = Menu})
    menu:init()
    menu:setUpdateItemTable()
    assert(menu.menu_items.filemanager == nil)
    assert(menu.menu_items.collections == nil and menu.menu_items.open_previous_document == nil)
    assert(menu.menu_items.typeset and menu.menu_items.setting, "KO settings must remain")
    assert(menu.tab_item_table[1].sub_item_table[1].text == "章节目录")
    assert(#menu.tab_item_table[1].sub_item_table == 1, "KO file/history entry must be removed")
    menu.tab_item_table[1].sub_item_table[1].callback()
    assert(calls[#calls][1] == "koToc", "KO menu must open Legado's chapter list")
    Toc:onShowToc()
    assert(calls[#calls][1] == "koToc", "KO ToC shortcut must also open Legado's chapter list")
    assert(menu.menu_items.legado_next_chapter and menu.menu_items.legado_return_shelf
        and menu.menu_items.legado_change_source)
    menu.menu_items.legado_change_source.callback()
    assert(menu.closed and calls[#calls][1] == "koChangeSource")
    assert(Reader.instance ~= nil, "Change source must keep KO reader behind the dialog")
    assert(loaded["document/doccache"].disk_cache == false)
    assert(loaded.docsettings.hasSidecarFile() == false)
    local enabled = loaded.pluginloader:loadPlugins(); assert(enabled[1].name == "test-plugin")
    loaded.device:showLightDialog()
    assert(#UI.shown > 0, "native KO frontlight widget must open")
    -- Back returns to the host, and all file-manager fallbacks are the very same guarded exit.
    assert(Reader.showFileManager == FileManager.showFiles and Reader.onHome == Back.onBack)
    Back:onBack()
    assert(UI.quit_called and Reader.instance == nil)
end
dofile("ko/legado.lua")
assert(#opens == 2)
print("PASS: path handoff, percentage restore/save, chapter boundary, request coalescing, KO menus/plugins/light, no sidecars, host return")
