-- Self-test wrapper for the standalone live neutral-hover gate.
local path = "fcs/wiredframe_neutral_hover_test.lua"
local sourceFile = assert(io.open(path, "r"))
local source = sourceFile:read("*a")
sourceFile:close()

assert(source:find("parallel.waitForAll", 1, true),
    "receiver must remain alive through shutdown finalization")
assert(not source:find("parallel.waitForAny", 1, true),
    "waitForAny would discard the shutdown acknowledgement receiver")
local sender = assert(source:match(
    "local function sendLoop%(%)(.-)\nend\n\nlocal ok"),
    "sendLoop body not found")
local shutdownAt = assert(sender:find("shutdownBurst", 1, true))
local acknowledgeAt = assert(sender:find("shutdownAcknowledged", 1, true))
assert(shutdownAt < acknowledgeAt,
    "shutdown acknowledgement must be checked after the zero burst")

local program, loadError = loadfile(path)
assert(program, loadError)
program("--self-test")
print("wired neutral-hover finalization test: PASS")
