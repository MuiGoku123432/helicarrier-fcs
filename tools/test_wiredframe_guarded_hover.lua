local path = "fcs/wiredframe_guarded_hover_test.lua"
local chunk, err = loadfile(path)
assert(chunk, err)
chunk("--self-test")
