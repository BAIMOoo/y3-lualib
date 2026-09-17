local real_ltimer = y3.ltimer
local real_game = y3.game
local real_game_event_on = real_game and real_game.event_on
local real_loaded_save_data = package.loaded['y3.util.save_data']
local real_y3_save_data = y3.save_data

y3.proxy = y3.proxy or require 'y3.tools.proxy'
y3.helper = y3.helper or {
    as_lua = function (value)
        return value
    end,
    tonumber = function (value)
        return value
    end,
}
log.info = log.info or function (...) end

local timers = {}
local level_switch_callback

local fake_ltimer = {}

function fake_ltimer.wait(timeout, on_timer)
    local timer = {
        removed = false,
    }

    function timer:remove()
        self.removed = true
    end

    function timer:execute(...)
        if self.removed then
            return
        end
        self.removed = true
        on_timer(self, 0, ...)
    end

    timers[#timers + 1] = timer
    return timer
end

function fake_ltimer.debug_fastward(count)
    for _ = 1, count do
        local timer = table.remove(timers, 1)
        if not timer then
            return
        end
        timer:execute()
    end
end

local function restore_runtime()
    y3.ltimer = real_ltimer
    if real_game then
        real_game.event_on = real_game_event_on
        y3.game = real_game
    else
        y3.game = nil
    end
    package.loaded['y3.util.save_data'] = real_loaded_save_data
    y3.save_data = real_y3_save_data
end

local function run_tests()
    y3.ltimer = fake_ltimer
    local fake_game = {}
    function fake_game:event_on(event_name, callback)
        level_switch_callback = callback
    end
    y3.game = fake_game

    package.loaded['y3.util.save_data'] = nil
    local save_data = require 'y3.util.save_data'

    local function new_player(initial_tables)
        local calls = {}
        local storage = initial_tables or {}
        local handle = {}

        local function record(call)
            calls[#calls + 1] = call
        end

        local function ensure_slot(slot)
            storage[slot] = storage[slot] or {}
            return storage[slot]
        end

        local function set_path(slot, key1, key2, key3, value)
            local root = ensure_slot(slot)
            if key2 == '' then
                root[key1] = value
                return
            end
            root[key1] = root[key1] or {}
            if key3 == '' then
                root[key1][key2] = value
                return
            end
            root[key1][key2] = root[key1][key2] or {}
            root[key1][key2][key3] = value
        end

        local function get_path(slot, key1, key2, key3)
            local root = ensure_slot(slot)
            if key2 == '' then
                return root[key1]
            end
            local value = root[key1]
            if value == nil or key3 == '' then
                return value and value[key2]
            end
            value = value[key2]
            return value and value[key3]
        end

        local function remove_path(slot, key1, key2, key3)
            local root = ensure_slot(slot)
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

        local function deep_copy(value)
            if type(value) ~= 'table' then
                return value
            end
            local result = {}
            for k, v in pairs(value) do
                result[k] = deep_copy(v)
            end
            return result
        end

        -- 引擎返回的是存档的一份快照：原生写入不会回头改动这份快照，
        -- 而 Lua 侧写入会直接落在快照上。测试必须保真这一点，
        -- 否则「同一张表挂到两个 key」的身份在 fake 里会随原生写入被抹掉。
        function handle:get_save_data_table_value(slot)
            return deep_copy(ensure_slot(slot))
        end

        function handle:set_save_table_key_value(slot, key1, value, key2, key3)
            if type(value) == 'table' and next(value) ~= nil then
                error('native table creation must receive an empty table')
            end
            record({
                op = 'set',
                slot = slot,
                key1 = key1,
                key2 = key2,
                key3 = key3,
                value = value,
                value_type = type(value),
                empty_table_value = type(value) == 'table' and next(value) == nil,
            })
            set_path(slot, key1, key2, key3, value)
        end

        function handle:get_save_table_key_value(slot, key1, key2, key3)
            return get_path(slot, key1, key2, key3)
        end

        function handle:remove_save_table_key_value(slot, key1, key2, key3)
            record({
                op = 'remove',
                slot = slot,
                key1 = key1,
                key2 = key2,
                key3 = key3,
            })
            remove_path(slot, key1, key2, key3)
        end

        function handle:upload_save_data()
            record({
                op = 'upload',
            })
        end

        return {
            handle = handle,
            calls = calls,
            storage = storage,
        }
    end

    local function find_call(calls, op, key1, key2, key3, value)
        for index, call in ipairs(calls) do
            if call.op == op
            and (key1 == nil or call.key1 == key1)
            and (key2 == nil or call.key2 == key2)
            and (key3 == nil or call.key3 == key3)
            and (value == nil or call.value == value) then
                return index, call
            end
        end
    end

    local function count_calls(calls, op, key1, key2, key3)
        local count = 0
        for _, call in ipairs(calls) do
            if call.op == op
            and (key1 == nil or call.key1 == key1)
            and (key2 == nil or call.key2 == key2)
            and (key3 == nil or call.key3 == key3) then
                count = count + 1
            end
        end
        return count
    end

    do
        local player = new_player()
        local data = save_data.load_table(player, 1)

        data[1] = {}
        data[1].level = 10
        data[1].amp = {}
        data[1].amp.value = 20

        assert(#player.calls == 1)
        assert(player.calls[1].op == 'set')
        assert(player.calls[1].key1 == 1)
        assert(player.calls[1].key2 == '')
        assert(player.calls[1].value_type == 'table')
        assert(player.calls[1].empty_table_value == true)

        fake_ltimer.debug_fastward(1)
        assert(find_call(player.calls, 'set', 1, 'level', '', 10))
        assert(find_call(player.calls, 'set', 1, 'amp', ''))
        assert(not find_call(player.calls, 'set', 1, 'amp', 'value', 20))

        fake_ltimer.debug_fastward(1)
        assert(find_call(player.calls, 'set', 1, 'amp', 'value', 20))
    end

    do
        local player = new_player()
        local data = save_data.load_table(player, 2)

        data[1] = {}
        data[1].level = 11
        data[1].amp = {}
        data[1].amp.value = 22

        ---@diagnostic disable-next-line: invisible
        save_data.upload_save_data(player)
        fake_ltimer.debug_fastward(10)

        local root_index = find_call(player.calls, 'set', 1, '', '')
        local level_index = find_call(player.calls, 'set', 1, 'level', '', 11)
        local amp_index = find_call(player.calls, 'set', 1, 'amp', '')
        local value_index = find_call(player.calls, 'set', 1, 'amp', 'value', 22)
        local upload_index = find_call(player.calls, 'upload')

        assert(root_index and level_index and amp_index and value_index and upload_index)
        assert(root_index < level_index)
        assert(level_index < amp_index)
        assert(amp_index < value_index)
        assert(value_index < upload_index)
    end

    do
        local player = new_player({
            [3] = {
                [10] = {
                    value = 1,
                },
            },
        })
        local data = save_data.load_table(player, 3)

        assert(data[10].value == 1)
        data[10] = nil

        assert(find_call(player.calls, 'remove', 10, '', ''))
        assert(data[10] == nil)
    end

    do
        local player = new_player()
        local data = save_data.load_table(player, 4)

        data[20] = {}
        data[20].value = 1
        data[20] = nil
        ---@diagnostic disable-next-line: invisible
        save_data.upload_save_data(player)
        fake_ltimer.debug_fastward(10)

        assert(find_call(player.calls, 'remove', 20, '', ''))
        assert(not find_call(player.calls, 'set', 20, 'value', '', 1))
    end

    do
        local player = new_player()
        local data = save_data.load_table(player, 5)

        data[1] = {}
        data[1].value = 7
        data['1'] = nil

        assert(data[1].value == 7)
        ---@diagnostic disable-next-line: invisible
        save_data.upload_save_data(player)
        fake_ltimer.debug_fastward(10)

        assert(find_call(player.calls, 'remove', '1', '', ''))
        assert(find_call(player.calls, 'set', 1, 'value', '', 7))
        assert(count_calls(player.calls, 'remove', 1, '', '') == 0)
    end

    do
        local player = new_player()
        local data = save_data.load_table(player, 6)

        data[1] = {}
        data[1].amp = {}
        data[1].amp.value = 30

        assert(level_switch_callback)
        level_switch_callback()

        local amp_index = find_call(player.calls, 'set', 1, 'amp', '')
        local value_index = find_call(player.calls, 'set', 1, 'amp', 'value', 30)
        assert(amp_index and value_index)
        assert(amp_index < value_index)
    end

    do
        local player = new_player()
        local data = save_data.load_table(player, 7)

        data.a = {}
        data.a.v = 1
        data.a.v = nil
        data.a.v = 2

        assert(data.a.v == 2)
        fake_ltimer.debug_fastward(1)
        assert(data.a.v == 2)
    end

    do
        local player = new_player()
        local data = save_data.load_table(player, 8)

        data.a = {}
        data.a.b = {}
        data.a.b.c = {}

        local write_ok, write_err = pcall(function ()
            data.a.b.c.d = 1
        end)
        assert(not write_ok, '写入第 4 层字段必须报错')
        assert(tostring(write_err):find('最多只支持3层嵌套', 1, true), tostring(write_err))

        fake_ltimer.debug_fastward(10)
        assert(find_call(player.calls, 'set', 'a', '', ''))
        assert(find_call(player.calls, 'set', 'a', 'b', ''))
        assert(find_call(player.calls, 'set', 'a', 'b', 'c'))
        assert(count_calls(player.calls, 'set') == 3, '第 4 层写入不得落到原生接口')
        assert(not find_call(player.calls, 'set', 'a', 'b', 'c', 1))
    end

    do
        local player = new_player({
            [9] = {
                level = 5,
                a = {
                    b = {
                        c = {
                            x = 1,
                        },
                    },
                },
            },
        })
        local data = save_data.load_table(player, 9)

        assert(data.level == 5)
        assert(type(data.a.b.c) == 'table')
        assert(data.a.b.c.x == nil, '第 4 层字段不可读')

        local delete_ok, delete_err = pcall(function ()
            data.a.b.c.x = nil
        end)
        assert(not delete_ok, '删除第 4 层字段必须报错')
        assert(tostring(delete_err):find('最多只支持3层嵌套', 1, true), tostring(delete_err))

        fake_ltimer.debug_fastward(10)
        assert(count_calls(player.calls, 'remove') == 0, '不得删除第 3 层的整张表')
        assert(type(data.a.b.c) == 'table')
        assert(player.storage[9].a.b.c.x == 1)
    end

    do
        local player = new_player()
        local data = save_data.load_table(player, 10)

        -- 同一张表挂到两个 key：代理缓存必须按「原生表 + 路径」区分，
        -- 否则两个 key 读到同一个代理，写入会落到先访问的那个路径上。
        local shared = {}
        data.left = shared
        data.right = shared

        assert(data.left ~= data.right, '同一张原生表挂两个 key 时不能共用代理')

        data.right.value = 1
        fake_ltimer.debug_fastward(10)

        assert(find_call(player.calls, 'set', 'right', 'value', '', 1))
        assert(count_calls(player.calls, 'set', 'left', 'value', '', 1) == 0)
    end

    do
        -- 外部先请求上传，再在 0.1 秒窗口内写入需要多轮 flush 的嵌套表：
        -- 上传前必须先把暂存写入排空，否则上传的原生快照会缺字段。
        local player = new_player()
        local data = save_data.load_table(player, 11)

        ---@diagnostic disable-next-line: invisible
        save_data.upload_save_data(player)
        data.a = {}
        data.a.b = {}
        data.a.b.c = 1

        fake_ltimer.debug_fastward(20)

        local upload_index = find_call(player.calls, 'upload')
        assert(upload_index, '上传必须发生')
        for index, call in ipairs(player.calls) do
            if call.op == 'set' then
                assert(index < upload_index, '所有原生写入都必须排在上传之前')
            end
        end
        assert(count_calls(player.calls, 'upload') == 1, '上传不得重复触发')
    end

    do
        -- 禁止覆盖模式的表格写入由引擎自己落盘，
        -- 只有允许覆盖模式才依赖 player.handle:upload_save_data()。
        local player = new_player()
        local data = save_data.load_table(player, 12)

        data.a = {}
        data.a.b = {}
        data.a.b.c = 1
        fake_ltimer.debug_fastward(20)

        assert(find_call(player.calls, 'set', 'a', 'b', 'c'))
        assert(count_calls(player.calls, 'upload') == 0, '未显式请求时不得上传')
    end
end

local ok, err = xpcall(run_tests, debug.traceback)
restore_runtime()

if not ok then
    error(err)
end

print('save_data unittest passed')
