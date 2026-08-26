-- THROWAWAY. Answers the two questions the monitor hub's design rests on,
-- neither of which can be checked off-server. Delete once you have the answer.
--
--   Q1  Does os.queueEvent from one multishell tab reach another tab?
--   Q2  Do ARRAY-indexed sub-tables survive the round trip intact?
--
-- Q2 is the sharp one. The hub sends per-bearing thrust as bearings[1] and
-- bearings[2], and walks fault lists with ipairs. If integer keys do not
-- survive, the b1/b2/delta rows read "--" forever while every offline test
-- still passes.
--
--   tab A:  probe_event listen
--   tab B:  probe_event send
--   then switch back to tab A.

local mode = ({ ... })[1]

if mode == "send" then
    for i = 1, 10 do
        os.queueEvent("fcs_probe", {
            n = i,
            bearings = { { thrust = 13960.98 }, { thrust = 13804.41 } },
            faults = { "alpha", "beta" },
        })
        print("sent " .. i)
        sleep(0.5)
    end
    print("done -- switch to the listening tab")
    return
end

if mode == "listen" then
    print("listening for fcs_probe (Ctrl+T to stop)")
    while true do
        local _, p = os.pullEvent("fcs_probe")
        local b1 = p and p.bearings and p.bearings[1] and p.bearings[1].thrust
        local b2 = p and p.bearings and p.bearings[2] and p.bearings[2].thrust
        local nf = 0
        for _ in ipairs(p and p.faults or {}) do nf = nf + 1 end
        print(string.format("n=%s  b1=%s  b2=%s  faults=%d",
            tostring(p and p.n), tostring(b1), tostring(b2), nf))
    end
end

print("usage: probe_event listen | probe_event send")
