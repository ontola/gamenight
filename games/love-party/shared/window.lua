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
	love.window.setMode(width, height, {borderless=true, resizable=false, vsync=1, x=-10000, y=-10000})
	M.hide()
end

function M.show()
	if not love.window then
		return
	end
	native_window()
	-- The managed window already has its final dimensions and borderless
	-- style. Moving and showing it must not recreate graphics resources.
	love.window.setPosition(0, 0)
	if sdl then sdl.SDL_ShowWindow(window) end
	love.window.restore()
	native_window()
	if sdl then
		sdl.SDL_RaiseWindow(window)
	end
	love.window.requestAttention()
end

return M
