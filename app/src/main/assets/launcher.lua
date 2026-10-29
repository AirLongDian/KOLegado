local A = require("android")
local ffi = require("ffi")
ffi.cdef[[int chdir(const char *path);]]
-- The Android navigation bar can change the NativeActivity surface size without
-- changing display metrics or sending a configuration change to KOReader.
local displayWidth, displayHeight = A.getScreenWidth, A.getScreenHeight
A.getScreenWidth = function()
    if A.app.window ~= nil then
        local width = A.lib.ANativeWindow_getWidth(A.app.window)
        if width > 0 then return width end
    end
    return displayWidth()
end
A.getScreenHeight = function()
    if A.app.window ~= nil then
        local height = A.lib.ANativeWindow_getHeight(A.app.window)
        if height > 0 then return height end
    end
    return displayHeight()
end
A.screen.width, A.screen.height = A.getScreenWidth(), A.getScreenHeight()
local host_dir = A.dir
A.dir = host_dir .. "/koreader"
package.path = A.dir .. "/?.lua;" .. package.path
package.cpath = A.dir .. "/?.so;" .. package.cpath
A.dl.library_path = A.nativeLibraryDir .. "/?;" .. A.dir .. "/?;" .. A.dir .. "/libs/?;" .. A.dl.library_path
assert(ffi.C.chdir(A.dir) == 0, "Unable to enter KO runtime")
local ok, err = xpcall(function() dofile("legado.lua") end, debug.traceback)
ffi.C.chdir(host_dir)
if not ok then error(err) end
