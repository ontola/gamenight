--- LÖVE exposes minimize/restore but not hide/show. Use its own SDL library
--- when available, so warming does not leave a blank window over the party.
local M = {}
local sdl, window

local function native_window()
	if sdl then
		-- setMode can replace SDL's window on Windows. Never hide a handle
		-- captured before the final window size was chosen.
		local current = sdl.SDL_GL_GetCurrentWindow()
		if current ~= nil then
			window = current
		end
		return
	end
	local ok, ffi = pcall(require, "ffi")
	if not ok then
		return
	end
	ffi.cdef([[
    void *SDL_GL_GetCurrentWindow(void);
    void SDL_HideWindow(void *window);
    void SDL_ShowWindow(void *window);
    void SDL_RaiseWindow(void *window);
  ]])
	-- Unix builds expose linked SDL symbols; Windows ships SDL2.dll beside LÖVE.
	local linked, handle = pcall(function()
		return ffi.C.SDL_GL_GetCurrentWindow()
	end)
	if linked and handle ~= nil then
		sdl, window = ffi.C, handle
		return
	end
	local loaded, library = pcall(ffi.load, "SDL2")
	if loaded then
		handle = library.SDL_GL_GetCurrentWindow()
		if handle ~= nil then
			sdl, window = library, handle
		end
	end
end

function M.hide()
	if not love.window then
		return
	end
	native_window()
	if sdl then
		sdl.SDL_HideWindow(window)
	else
		love.window.minimize()
	end
end

function M.prepare()
	if not love.window then return end
	local width, height = love.window.getDesktopDimensions()
	love.window.setMode(width, height, {fullscreen=false, fullscreentype="desktop", borderless=true, resizable=false, highdpi=true, vsync=1, x=-10000, y=-10000})
	M.hide()
end

function M.show(drawFrame)
	if not love.window then
		return
	end
    -- Hidden/minimized swapchains may discard the warm frame. Restore off
    -- screen and present current gameplay before putting it over the lobby.
    local started=love.timer.getTime()
    native_window()
    love.window.setPosition(-10000,-10000)
    if sdl then sdl.SDL_ShowWindow(window) end
    love.window.restore()
    local function present()
        if drawFrame and love.graphics then
            love.graphics.origin()
            love.graphics.clear()
            drawFrame()
            love.graphics.present()
        end
    end
    local ok,err=pcall(present)
    if not ok then M.hide();error(err) end
    love.window.setPosition(0,0)
    -- Moving between monitors/DPI contexts can invalidate the drawable too.
    ok,err=pcall(present)
    if not ok then M.hide();error(err) end
    native_window()
    if sdl then sdl.SDL_RaiseWindow(window) end
    print(string.format("GameNight window presented in %.3fs",love.timer.getTime()-started))
end

return M
