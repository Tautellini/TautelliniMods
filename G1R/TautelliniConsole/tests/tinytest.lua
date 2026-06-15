-- tinytest.lua  --  a tiny in-repo test runner (no external dependencies)
--
-- Run a file that registers tests with T.add(name, fn) and ends with
-- os.exit(T.run()). A test fails by raising an error (use the T.* helpers).

local T = { _tests = {} }

local function fmt(v)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "table" then return tostring(v) end
    return tostring(v)
end

function T.add(name, fn)
    T._tests[#T._tests + 1] = { name = name, fn = fn }
end

function T.ok(cond, msg)
    if not cond then error(msg or "expected a truthy value", 2) end
end

function T.eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%sexpected %s, got %s",
            msg and (msg .. ": ") or "", fmt(expected), fmt(actual)), 2)
    end
end

function T.run()
    local passed, failed = 0, 0
    print(string.format("running %d test(s)", #T._tests))
    for _, tc in ipairs(T._tests) do
        local ok, err = pcall(tc.fn)
        if ok then
            passed = passed + 1
            print("  PASS  " .. tc.name)
        else
            failed = failed + 1
            print("  FAIL  " .. tc.name)
            print("        " .. tostring(err))
        end
    end
    print(string.format("%d passed, %d failed", passed, failed))
    return failed
end

return T
