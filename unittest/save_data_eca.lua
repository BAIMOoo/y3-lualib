-- ECA bindings for disable-cover table save data.
-- This test uses a small native-handle fake so it exercises the same proxy
-- and ECA conversion path as an in-game call.

-- unittest/init.lua does not load the production ECA stack, so provide the
-- smallest identity converter needed by ECAFunction before registering binds.
if not y3.py_converter then
    y3.py_converter = {
        get_py_type = function (type_name)
            return type_name
        end,
        py_to_lua = function (_, value)
            return value
        end,
        lua_to_py = function (_, value)
            return value
        end,
    }
end
y3.reload = y3.reload or {
    isReloading = function ()
        return false
    end,
}
require 'y3.util.eca_function'
y3.eca = y3.eca or require 'y3.util.eca_helper'

-- This test drives the bindings with a fake player, while the real ECA stack
-- converts the first parameter to a Player and rejects it. Always swap in a
-- small registration stub for the duration of the test, then restore.
if not y3.game then
    y3.game = {
        event_on = function()
        end,
    }
end
if not y3.ltimer then
    y3.ltimer = {
        wait = function()
            return { remove = function() end }
        end,
    }
end
if not y3.helper then
    y3.helper = {
        as_lua = function(value) return value end,
        tonumber = function(value) return value end,
    }
end

local real_eca = y3.eca
local real_loaded_save_data_eca = package.loaded['y3.util.save_data_eca']
local BIND_NAMES = { '读取存档字段', '写入存档字段', '判断字段是否存在', '删除存档字段' }
local real_binds = {}
for index = 1, #BIND_NAMES do
    real_binds[BIND_NAMES[index]] = Bind and Bind[BIND_NAMES[index]]
end

Bind = Bind or {}
y3.eca = {
    -- 真实 y3.eca 会把参数转成 Lua 对象（fake player 会被直接拒绝），
    -- 这里保留真实包装器的错误/返回语义（抛错转 log.error、失败返回 nil），
    -- 只跳过参数与返回值的类型转换。顺序与 y3.eca.def 一致：with_* 先于 call。
    def = function(name)
        local builder = {
            returns_value = false,
        }
        function builder:with_param()
            return self
        end
        function builder:with_return()
            self.returns_value = true
            return self
        end
        function builder:call(func)
            Bind[name] = function (...)
                local function error_handler(...)
                    log.error('在【' .. name .. '】中发生错误：\n', ...)
                end
                local results = table.pack(xpcall(func, error_handler, ...))
                if not results[1] or not builder.returns_value then
                    return nil
                end
                return results[2]
            end
        end
        return builder
    end,
}
package.loaded['y3.util.save_data_eca'] = nil

local save_data_eca = require 'y3.util.save_data_eca'
assert(save_data_eca, 'save_data_eca module must load')

local real_ltimer = y3.ltimer

local function new_player()
    local storage = {}
    local function slot_data(slot)
        storage[slot] = storage[slot] or {}
        return storage[slot]
    end
    local function set_value(slot, key1, value, key2, key3)
        local root = slot_data(slot)
        if key2 == '' then
            root[key1] = value
        elseif key3 == '' then
            root[key1] = root[key1] or {}
            root[key1][key2] = value
        else
            root[key1] = root[key1] or {}
            root[key1][key2] = root[key1][key2] or {}
            root[key1][key2][key3] = value
        end
    end
    local function get_value(slot, key1, key2, key3)
        local root = slot_data(slot)
        if key2 == '' then
            return root[key1]
        end
        local value = root[key1]
        if value == nil then
            return nil
        end
        if key3 == '' then
            return value[key2]
        end
        value = value[key2]
        return value and value[key3]
    end
    local function remove_value(slot, key1, key2, key3)
        local root = slot_data(slot)
        if key2 == '' then
            root[key1] = nil
            return
        end
        local value = root[key1]
        if not value then
            return
        end
        if key3 == '' then
            value[key2] = nil
            return
        end
        value = value[key2]
        if value then
            value[key3] = nil
        end
    end

    local handle = {
        get_save_data_table_value = function(_, slot)
            return slot_data(slot)
        end,
        set_save_table_key_value = function(_, slot, key1, value, key2, key3)
            set_value(slot, key1, value, key2, key3)
        end,
        get_save_table_key_value = function(_, slot, key1, key2, key3)
            return get_value(slot, key1, key2, key3)
        end,
        remove_save_table_key_value = function(_, slot, key1, key2, key3)
            remove_value(slot, key1, key2, key3)
        end,
    }
    return { handle = handle, storage = storage }
end

local function run_tests()
    y3.ltimer = {
        wait = function ()
            return {
                remove = function () end,
            }
        end,
    }

    local player = new_player()

    -- Top-level writes/read and optional keys omitted.
    Bind['写入存档字段'](player, 101, 'ready', 'state')
    assert(Bind['读取存档字段'](player, 101, 'state') == 'ready')
    assert(Bind['判断字段是否存在'](player, 101, 'state') == true)

    -- Empty-table assignment creates the parent; nested writes then work.
    Bind['写入存档字段'](player, 101, {}, 'profile')
    assert(Bind['判断字段是否存在'](player, 101, 'profile') == true)
    Bind['写入存档字段'](player, 101, 10, 'profile', 'level')
    Bind['写入存档字段'](player, 101, {}, 'profile', 'flags')
    Bind['写入存档字段'](player, 101, true, 'profile', 'flags', 'active')
    assert(Bind['读取存档字段'](player, 101, 'profile', 'level') == 10)
    assert(Bind['读取存档字段'](player, 101, 'profile', 'flags', 'active') == true)
    assert(Bind['判断字段是否存在'](player, 101, 'profile', 'flags', 'active') == true)

    -- Integer keys are valid at every supported path depth.
    Bind['写入存档字段'](player, 101, 'integer-key', 7)
    assert(Bind['读取存档字段'](player, 101, 7) == 'integer-key')

    -- Assigning nil has Lua's delete semantics; explicit delete is idempotent.
    Bind['写入存档字段'](player, 101, nil, 'state')
    assert(Bind['判断字段是否存在'](player, 101, 'state') == false)
    Bind['删除存档字段'](player, 101, 'profile', 'level')
    Bind['删除存档字段'](player, 101, 'missing')
    assert(Bind['读取存档字段'](player, 101, 'profile', 'level') == nil)

    -- A nested write requires its parent table to exist.
    local previous_error = log.error
    local missing_parent_error
    log.error = function(...)
        local parts = {}
        for index = 1, select('#', ...) do
            parts[index] = tostring(select(index, ...))
        end
        missing_parent_error = table.concat(parts, ' ')
    end
    Bind['写入存档字段'](player, 101, 1, 'missing_parent', 'value')
    log.error = previous_error
    assert(missing_parent_error and missing_parent_error:find('父表不存在', 1, true))
end

local function restore_runtime()
    y3.ltimer = real_ltimer
    y3.eca = real_eca
    for name, func in pairs(real_binds) do
        Bind[name] = func
    end
    package.loaded['y3.util.save_data_eca'] = real_loaded_save_data_eca
end

local ok, err = xpcall(run_tests, debug.traceback)
restore_runtime()

if not ok then
    error(err)
end

print('save_data_eca unittest passed')
