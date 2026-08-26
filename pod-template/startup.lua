-- Propulsion pod startup.
-- Configure /pod/config.lua and approve the generated manifest before rebooting.

term.clear()
term.setCursorPos(1, 1)
print("Starting propulsion pod controller...")

-- The reboot listener goes in its own tab FIRST, so it is already listening if
-- main.lua fails to start at all. main.lua stays in the foreground to keep the
-- pod display on screen.
if multishell and shell and shell.openTab then
    local tab = shell.openTab("/pod/reboot_listener.lua")
    multishell.setTitle(tab, "Reboot")
end

local ok = shell.run("/pod/main.lua")
if not ok then
    printError("POD CONTROLLER STOPPED")
    printError("Thrusters should have been returned to fallback power.")
end
