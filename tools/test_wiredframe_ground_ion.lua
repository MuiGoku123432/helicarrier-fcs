local function testGroundIonHarnessSelfTest()
    local chunk = assert(loadfile("fcs/wiredframe_ground_ion_test.lua"))
    local ok, err = pcall(chunk, "--self-test")
    assert(ok, tostring(err))
end

testGroundIonHarnessSelfTest()
print("wired grounded ion harness test: PASS")
