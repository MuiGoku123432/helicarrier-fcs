-- Self-test and finalization guard for the lift-and-coast bracket.
local path = "fcs/wiredframe_lift_coast_test.lua"
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
assert(source:find("LIFT_POWER, COAST_POWER, FALLBACK_POWER = 0.200, 0.14, 0.07", 1, true),
    "lift/coast/fallback authority bracket changed unexpectedly")
assert(source:find("MAX_RISE, MAX_FALL, MAX_HORIZONTAL_DISPLACEMENT = 1.5, 1.0, 1.5", 1, true),
    "outer displacement envelope changed unexpectedly")

local program, loadError = loadfile(path)
assert(program, loadError)
program("--self-test")
print("wired lift-and-coast finalization test: PASS")
