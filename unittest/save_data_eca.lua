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

    -- 父字段是标量时，判断存在性必须是 false：read_field 的抛错属于读取语义，
    -- 不能被 has_field 继承（否则 ECA 条件每次判定都会刷 log.error 并返回 nil）。
    local scalar_player = new_player()
    Bind['写入存档字段'](scalar_player, 102, 100, 'coins')

    local logged = {}
    local previous_error_handler = log.error
    log.error = function (...)
        local parts = {}
        for index = 1, select('#', ...) do
            parts[index] = tostring(select(index, ...))
        end
        logged[#logged + 1] = table.concat(parts, ' ')
    end

    local has_scalar = Bind['判断字段是否存在'](scalar_player, 102, 'coins', 'x')
    local has_scalar_deep = Bind['判断字段是否存在'](scalar_player, 102, 'coins', 'x', 'y')
    local has_missing = Bind['判断字段是否存在'](scalar_player, 102, 'missing', 'x')
    local has_present = Bind['判断字段是否存在'](scalar_player, 102, 'coins')
    local has_log_count = #logged

    -- read_field 的抛错行为保持不变：读取标量父字段下的路径仍然报错。
    Bind['读取存档字段'](scalar_player, 102, 'coins', 'x')
    local read_log = logged[#logged]

    -- 参数错误仍然要暴露（structure 判断会先走 normalize_keys），不能一起吞成 false。
    local bad_key_log_count = #logged
    Bind['判断字段是否存在'](scalar_player, 102, nil)
    local bad_key_log = logged[#logged]

    log.error = previous_error_handler

    assert(has_log_count == 0, '判断存在性不应写 log.error，实际：' .. tostring(logged[1]))
    assert(has_scalar == false, '父字段是标量时应为 false，实际：' .. tostring(has_scalar))
    assert(has_scalar_deep == false, '标量父字段上的三层路径应为 false，实际：' .. tostring(has_scalar_deep))
    assert(has_missing == false, '父表不存在时应为 false，实际：' .. tostring(has_missing))
    assert(has_present == true, '存在的字段应为 true，实际：' .. tostring(has_present))
    assert(read_log and read_log:find('父字段不是表', 1, true),
        '读取标量父字段下的路径仍应按读取语义报错，实际：' .. tostring(read_log))
    assert(#logged == bad_key_log_count + 1 and bad_key_log:find('不能为空', 1, true),
        'key 非法时判断存在性仍应报错，实际：' .. tostring(bad_key_log))

    -- 路径解析不创建父表：要建父表必须先写一个空表（写 {} 是允许的）。
    -- 写入时父表缺失必须报错；删除时父表缺失是 no-op（不报错、不建表）。
    local captured_errors
    local function capture_errors()
        captured_errors = {}
        local previous = log.error
        log.error = function(...)
            local parts = {}
            for index = 1, select('#', ...) do
                parts[index] = tostring(select(index, ...))
            end
            captured_errors[#captured_errors + 1] = table.concat(parts, ' ')
        end
        return previous
    end

    local function drain_pending_writes(target_player, slot)
        local save_data = require 'y3.util.save_data'
        local flush = save_data.flush_save_table_map[target_player][slot]
        if flush then
            flush(true)
        end
    end

    -- key2 层父表缺失：写入报错，且不会凭空建出父表。
    local previous_write_error = capture_errors()
    Bind['写入存档字段'](player, 101, 1, 'missing_parent', 'value')
    local write_errors = captured_errors
    log.error = previous_write_error
    drain_pending_writes(player, 101)
    assert(#write_errors == 1 and write_errors[1]:find('父表不存在', 1, true),
        '写入时父表缺失必须报错，实际：' .. tostring(write_errors[1]))
    assert(player.storage[101].missing_parent == nil, '写入报错后不应创建父表')

    -- key3 层祖父表缺失：写入同样报错，路径上不留表。
    local previous_deep_write_error = capture_errors()
    Bind['写入存档字段'](player, 101, 1, 'missing_grand', 'mid', 'leaf')
    local deep_write_errors = captured_errors
    log.error = previous_deep_write_error
    drain_pending_writes(player, 101)
    assert(#deep_write_errors == 1 and deep_write_errors[1]:find('父表不存在', 1, true),
        '祖父表缺失时三层写入必须报错，实际：' .. tostring(deep_write_errors[1]))
    assert(player.storage[101].missing_grand == nil, '写入报错后不应创建祖父表')

    -- 删除在父表缺失时是 no-op：不报错、不建表。
    local previous_delete_error = capture_errors()
    Bind['删除存档字段'](player, 101, 'absent_parent', 'value')
    Bind['删除存档字段'](player, 101, 'absent_grand', 'mid', 'leaf')
    local delete_errors = captured_errors
    log.error = previous_delete_error
    drain_pending_writes(player, 101)
    assert(#delete_errors == 0, '父表缺失时删除不应报错，实际：' .. tostring(delete_errors[1]))
    assert(Bind['判断字段是否存在'](player, 101, 'absent_parent') == false)
    assert(Bind['判断字段是否存在'](player, 101, 'absent_grand') == false)
    assert(player.storage[101].absent_parent == nil, '删除不应创建父表')
    assert(player.storage[101].absent_grand == nil, '删除不应创建祖父表')

    -- 「父表缺失」是 no-op，「父字段不是表」仍然报错，两者不能混为一谈。
    local scalar_delete_player = new_player()
    Bind['写入存档字段'](scalar_delete_player, 103, 100, 'coins')
    local previous_scalar_delete_error = capture_errors()
    Bind['删除存档字段'](scalar_delete_player, 103, 'coins', 'x')
    local scalar_delete_errors = captured_errors
    log.error = previous_scalar_delete_error
    assert(#scalar_delete_errors == 1 and scalar_delete_errors[1]:find('父字段不是表', 1, true),
        '父字段是标量时删除仍应报错，实际：' .. tostring(scalar_delete_errors[1]))
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
