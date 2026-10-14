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
-- `y3.save_data.auto` 换掉非表父级时会 warn，测试里收下来断言。
local warnings = {}
log.warn = function (...) warnings[#warnings + 1] = table.concat({ ... }, ' ') end

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

    local function new_player(initial_tables, native_set_hook)
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

        -- 路径文本，仅用于模拟引擎报错信息。
        local function path_text(key1, key2)
            if key2 == '' then
                return tostring(key1)
            end
            return tostring(key1) .. '.' .. tostring(key2)
        end

        -- 与引擎一致（table_api.py `_Up1SetTableValueAndCheckValid`）：父级不是表就报错
        -- （errcode 4），绝不补建中间表。假引擎若不这样，会放行真引擎必然拒绝的写入。
        local function check_parent_table(parent, key1, key2)
            if type(parent) ~= 'table' then
                error('save_table_exceed_table_depth: ' .. path_text(key1, key2))
            end
        end

        local function set_path(slot, key1, key2, key3, value)
            local root = ensure_slot(slot)
            if key2 == '' then
                root[key1] = value
                return
            end
            check_parent_table(root[key1], key1, '')
            if key3 == '' then
                root[key1][key2] = value
                return
            end
            check_parent_table(root[key1][key2], key1, key2)
            root[key1][key2][key3] = value
        end

        local function get_path(slot, key1, key2, key3)
            local root = ensure_slot(slot)
            if key2 == '' then
                return root[key1]
            end
            -- 引擎按路径逐层走，遇到非表（缺失或标量）都返回 nil，不报错。
            local value = root[key1]
            if type(value) ~= 'table' then
                return nil
            end
            if key3 == '' then
                return value[key2]
            end
            value = value[key2]
            if type(value) ~= 'table' then
                return nil
            end
            return value[key3]
        end

        local function remove_path(slot, key1, key2, key3)
            local root = ensure_slot(slot)
            if key2 == '' then
                root[key1] = nil
                return
            end
            -- 引擎的删除走同一套父级校验：父级不是表同样报错（errcode 4）。
            check_parent_table(root[key1], key1, '')
            if key3 == '' then
                root[key1][key2] = nil
                return
            end
            check_parent_table(root[key1][key2], key1, key2)
            root[key1][key2][key3] = nil
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

        function handle:set_save_table_key_value(slot, key1, value, key2, key3, value_convert_func)
            if native_set_hook then
                native_set_hook(slot, key1, value, key2, key3)
            end
            if type(value) == 'table' and next(value) ~= nil then
                error('native table creation must receive an empty table')
            end
            -- 先落盘再记录：引擎的父级校验失败时不会产生任何存档操作。
            set_path(slot, key1, key2, key3, value)
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
        end

        function handle:get_save_table_key_value(slot, key1, key2, key3)
            return get_path(slot, key1, key2, key3)
        end

        function handle:remove_save_table_key_value(slot, key1, key2, key3)
            -- 先落盘再记录：父级校验失败时不会产生任何存档操作。
            remove_path(slot, key1, key2, key3)
            record({
                op = 'remove',
                slot = slot,
                key1 = key1,
                key2 = key2,
                key3 = key3,
            })
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

    do
        -- 空表的代理挂到另一个 key：代理自带 [CONFIG]/[CUSTOM] 哨兵键，
        -- `next(代理)` 恒非 nil，判空必须先解包成原生表再判。
        local player = new_player()
        local data = save_data.load_table(player, 13)

        data.x = {}
        local a = data.x
        data.y = a
        fake_ltimer.debug_fastward(10)

        local y_index, y_call = find_call(player.calls, 'set', 'y', '', '')
        assert(y_index, '空表的代理必须能赋值给另一个 key')
        assert(y_call.value_type == 'table')
        assert(y_call.empty_table_value == true, '原生 y 必须是空表')
        assert(type(player.storage[13].y) == 'table')
        assert(next(player.storage[13].y) == nil, '原生 y 不得带字段')

        -- 赋一张非空表 = 把这个键位所在的子树整体替换成它
        data.z = { 1 }
        fake_ltimer.debug_fastward(20)
        assert(player.storage[13].z[1] == 1, '非空表赋值必须整树写进原生')
    end

    do
        -- 代理包着非空表（引擎快照里的子表）：赋出去 = 整树替换对方，而不是报错
        local player = new_player({
            [14] = {
                a = {
                    b = {
                        c = 1,
                    },
                },
            },
        })
        local data = save_data.load_table(player, 14)

        assert(type(data.a.b) == 'table')

        data.m = data.a.b
        fake_ltimer.debug_fastward(20)
        assert(player.storage[14].m.c == 1, '代理包着的非空表必须整树写出去')
    end

    do
        -- 删除标记只是本会话的读侧影子：第三方绕过本代理把同路径写回原生后，
        -- 代理必须读到原生值，而不是继续被删除标记挡住。
        local player = new_player({
            [15] = {
                a = { b = 1 },
            },
        })
        local data = save_data.load_table(player, 15)

        assert(data.a.b == 1)
        data.a.b = nil
        assert(data.a.b == nil)

        player.handle:set_save_table_key_value(15, 'a', 7, 'b', '', '')
        assert(player.storage[15].a.b == 7, '绕过代理写回原生必须生效')
        assert(data.a.b == 7, '原生已有值时，代理必须读到原生值')

        fake_ltimer.debug_fastward(10)
        assert(data.a.b == 7, '对账后仍必须读到原生值')
        assert(count_calls(player.calls, 'set', 'a', 'b', '') == 1,
            '对账不得把值再写回原生（只允许那一次第三方写入）')
    end

    do
        -- 对照组：原生确实为空时删除语义不变，不得因为对账就把旧值读回来。
        local player = new_player({
            [16] = {
                k = 1,
            },
        })
        local data = save_data.load_table(player, 16)

        data.k = nil
        assert(data.k == nil, '原生为空时删除必须胜出')
        assert(player.storage[16].k == nil)

        fake_ltimer.debug_fastward(10)
        assert(data.k == nil, '多轮 flush 后删除仍然胜出')
    end

    do
        -- 删除父表后，用仍持有的代理写它的子字段：父表在原生已经不存在，必须当场报错。
        -- （引擎对该写入同样返回 errcode 4 报错、不会补建 p；这里提前拦是为了当场抛出。）
        -- 这里同时守着 pending_created 的清理：若残留「本轮已创建」标记，这次写入会被
        -- 判成「父表即将落盘」而暂存，pcall 就不会失败，错误被推迟到 flush。
        local player = new_player()
        local data = save_data.load_table(player, 17)

        data.p = {}
        local captured = data.p
        data.p = nil

        local ok, err = pcall(function () captured.x = 1 end)
        assert(not ok, '删除父表后写子字段必须报错')
        assert(tostring(err):find('父表不存在：p', 1, true), tostring(err))

        fake_ltimer.debug_fastward(10)
        assert(count_calls(player.calls, 'set', 'p', 'x', '') == 0, '不得把写入下发到原生')
        assert(player.storage[17].p == nil, '原生不得出现 p')
    end

    do
        -- ECA 接口固定传 true，Lua 接口按文档默认传 nil，两者都表示禁止覆盖模式：
        -- 同一个槽位混用必须拿到同一个代理，而不是报「覆盖类型设置与上次不一致」。
        local player = new_player()

        local data_by_default = save_data.load_table(player, 18)
        assert(save_data.load_table(player, 18, true) == data_by_default,
            'nil 与 true 必须等价')

        local data_by_flag = save_data.load_table(player, 19, true)
        assert(save_data.load_table(player, 19) == data_by_flag,
            'true 与 nil 必须等价')

        -- 允许覆盖模式已经被编辑器废弃，但它确实和禁止覆盖模式不同，仍然必须报错。
        assert(save_data.load_table(player, 20, false))
        local ok, err = pcall(function ()
            return save_data.load_table(player, 20, true)
        end)
        assert(not ok, '禁止覆盖与允许覆盖混用必须报错')
        assert(tostring(err):find('覆盖类型设置与上次不一致', 1, true), tostring(err))
    end

    do
        -- 先建父表、再写子字段，随后把父字段改回标量：被推迟的子字段写入已被这次
        -- 赋值取代，不得在后续轮次落盘（否则原生先收到 settings.diff = 2，
        -- 又收到 settings.diff.mode = 1，写进一个已经是标量的父表）。
        local player = new_player()
        local data = save_data.load_table(player, 21)

        data.settings = {}
        data.settings.diff = {}
        data.settings.diff.mode = 1
        data.settings.diff = 2

        fake_ltimer.debug_fastward(10)

        assert(player.storage[21].settings.diff == 2, '最终原生值必须等于最后一次赋值')
        assert(count_calls(player.calls, 'set', 'settings', 'diff', 'mode') == 0,
            '被取代的子字段写入不得下发到原生')
        assert(data.settings.diff == 2)
    end

    do
        -- 同上，只是赋值落在两轮 flush 之间。
        local player = new_player()
        local data = save_data.load_table(player, 22)

        data.settings = {}
        data.settings.diff = {}
        data.settings.diff.mode = 1
        fake_ltimer.debug_fastward(1)
        assert(player.storage[22].settings.diff ~= nil, '第一轮 flush 后 diff 表应已落盘')

        data.settings.diff = 2
        fake_ltimer.debug_fastward(10)

        assert(player.storage[22].settings.diff == 2, '最终原生值必须等于最后一次赋值')
        assert(count_calls(player.calls, 'set', 'settings', 'diff', 'mode') == 0,
            '被取代的子字段写入不得下发到原生')
    end

    do
        -- 单条原生写入失败不能吃掉同批次的其它写入，也不能静默：失败会记日志并重排重试。
        local failing = true
        local player = new_player(nil, function (_, _, _, key2)
            if failing and key2 == 'bad' then
                error('模拟原生写入失败')
            end
        end)
        local data = save_data.load_table(player, 23)

        local errors = {}
        local previous_error = log.error
        log.error = function (...)
            local parts = {}
            for index = 1, select('#', ...) do
                parts[index] = tostring(select(index, ...))
            end
            errors[#errors + 1] = table.concat(parts, ' ')
        end

        data.root = {}
        data.root.bad = 1
        data.root.good = 2
        fake_ltimer.debug_fastward(10)

        log.error = previous_error

        assert(#errors >= 2, '写入失败必须先重试再放弃，且必须记日志，实际：' .. tostring(#errors))
        assert(errors[1]:find('模拟原生写入失败', 1, true), errors[1])
        assert(player.storage[23].root.good == 2, '同批次的其它写入不得被一次失败带走')
        assert(player.storage[23].root.bad == nil, '失败的字段确实没落到原生')
        assert(data.root.bad == 1, '失败的字段仍必须能读回 Lua 侧的值')

        -- 失败注入解除后重试必须成功。
        failing = false
        data.root.bad = 3
        fake_ltimer.debug_fastward(10)

        assert(player.storage[23].root.bad == 3)
        assert(data.root.bad == 3)
    end

    do
        -- 直接改「传进存档的那张表」（绕过代理）后，代理并不知道中间表存在：
        -- 此时 a.b 只在 Lua 快照里，原生没有。写 a.b.c 必须报错
        -- （引擎同样会返回 errcode 4，不会补建 a.b）。
        local player = new_player()
        local data = save_data.load_table(player, 24)

        local assigned = {}
        data.a = assigned
        assigned.b = {}

        local ok, err = pcall(function () data.a.b.c = 1 end)
        assert(not ok, '中间表只存在于 Lua 侧时，三层写入必须报错')
        assert(tostring(err):find('父表不存在：a.b', 1, true), tostring(err))

        fake_ltimer.debug_fastward(10)
        assert(count_calls(player.calls, 'set', 'a', 'b', 'c') == 0, '不得把写入下发到原生')
    end

    do
        -- 第三方（或引擎）绕过本代理改写原生后，本代理没写过这个字段时必须读到原生值，
        -- 不能读回过期快照——和删除标记的对账是同一条规则。
        local player = new_player({
            [25] = {
                k = 1,
                root = { v = 1 },
            },
        })
        local data = save_data.load_table(player, 25)

        assert(data.k == 1)
        player.handle:set_save_table_key_value(25, 'k', 99, '', '', '')
        assert(data.k == 99, '没写过这个字段时必须以原生为准')

        -- 但本代理自己的赋值还没落盘时，原生还是旧值，必须用 Lua 侧的值。
        data.root = {}
        data.root.v = 5
        assert(data.root.v == 5, '暂存写入未落盘时必须用 Lua 侧的值')

        -- 表值仍然用快照里的表：代理身份稳定，写入才会落在同一张表上。
        local first = data.root
        player.handle:set_save_table_key_value(25, 'root', {}, '', '', '')
        assert(data.root == first, '原生换成另一张表时仍必须返回原代理')
        assert(data.root.v == 5)

        -- 引擎取值滞后（原生读不到刚写过的值）时必须退回快照值，不能读成 nil。
        player.handle.get_save_table_key_value = function ()
            return nil
        end
        assert(data.k == 1, '原生读不到时应退回快照值')
        assert(data.root.v == 5, '暂存写入本来就不依赖原生取值')
    end

    do
        -- 表值/标量写入连续失败被放弃后，该路径的「等待落盘的表」与「未落盘」标记
        -- 必须一并清掉：
        --  * 残留的 pending_table 会让子字段写入被永久推迟（下面 find_call 立刻失败）；
        --  * 残留的 unflushed 会让读取永久遮蔽原生后来写入的值；
        --  * 两者都不清时，drain 模式（切关卡 / upload_save_data）会死循环。
        local failing = true
        local player = new_player(nil, function (_, _, _, key2, key3)
            if failing and key3 == '' and (key2 == 'tbl' or key2 == 'val') then
                error('模拟原生写入失败')
            end
        end)
        local data = save_data.load_table(player, 26)

        local errors = {}
        local previous_error = log.error
        log.error = function (...)
            local parts = {}
            for index = 1, select('#', ...) do
                parts[index] = tostring(select(index, ...))
            end
            errors[#errors + 1] = table.concat(parts, ' ')
        end

        data.root = {}
        data.root.tbl = {}
        data.root.val = 1
        fake_ltimer.debug_fastward(10)
        log.error = previous_error

        assert(#errors >= 2, '放弃写入必须记日志，实际：' .. tostring(#errors))
        assert(errors[#errors]:find('已放弃', 1, true), errors[#errors])
        assert(player.storage[26].root.tbl == nil, '失败的建表写入确实没落到原生')
        assert(player.storage[26].root.val == nil)
        assert(type(data.root.tbl) == 'table', '失败的字段仍必须能读回 Lua 侧的值')
        assert(data.root.val == 1)

        -- 关键：放弃建表后，父表在原生并不存在。子字段写入必须当场报错，
        -- 既不能靠残留的 pending_table 无限推迟，也不能把写入下发到原生
        -- （引擎对缺失父级返回 errcode 4，不会补建）。
        -- 若 abandon 分支漏清 pending_table，这里会被判成「父表即将落盘」而暂存，
        -- pcall 就不会失败。
        local child_ok, child_err = pcall(function () data.root.tbl.child = 1 end)
        assert(not child_ok, '父表被放弃后写子字段必须报错')
        assert(tostring(child_err):find('父表不存在：root.tbl', 1, true), tostring(child_err))
        assert(count_calls(player.calls, 'set', 'root', 'tbl', 'child') == 0, '不得把写入下发到原生')
        fake_ltimer.debug_fastward(10)
        assert(player.storage[26].root.tbl == nil, '原生不得出现 root.tbl')

        -- drain 路径（切关卡 / 上传）必须能返回：若残留标记让排空死循环，这里会挂住。
        assert(level_switch_callback)
        level_switch_callback()

        -- 放弃写入不再被残留的「未落盘」标记永久遮蔽：第三方写回原生必须可见。
        failing = false
        player.handle:set_save_table_key_value(26, 'root', 7, 'val', '', '')
        assert(player.storage[26].root.val == 7)
        assert(data.root.val == 7, '放弃写入后，原生的新值必须能被读到')
    end

    do
        -- 与 ECA 的路径语义对齐：写嵌套字段前父级必须是表，否则当场报错
        -- （引擎也会拒绝并返回 errcode 4，不会补建中间表）。
        local player = new_player({
            [27] = {
                a = { b = { c = 1 } },
            },
        })
        local data = save_data.load_table(player, 27)

        -- 父字段变成标量：key2 层
        data.n = {}
        local captured_scalar = data.n
        data.n = 1
        local ok1, err1 = pcall(function () captured_scalar.child = 2 end)
        assert(not ok1, '父字段是标量时必须报错')
        assert(tostring(err1):find('父字段不是表：n', 1, true), tostring(err1))

        -- 父表已被删除，用旧代理写它的子字段：key3 层
        local captured_table = data.a.b
        data.a.b = nil
        local ok2, err2 = pcall(function () captured_table.c = 2 end)
        assert(not ok2, '父表被删除后写子字段必须报错')
        assert(tostring(err2):find('父表不存在：a.b', 1, true), tostring(err2))

        fake_ltimer.debug_fastward(10)
        assert(count_calls(player.calls, 'set', 'n', 'child') == 0, '不得把写入下发到原生')
        assert(count_calls(player.calls, 'set', 'a', 'b', 'c') == 0, '不得把写入下发到原生')
        assert(player.storage[27].n == 1, '标量父字段不得被覆盖')
        assert(player.storage[27].a.b == nil, '被删除的父表不得被重新写出来')

        -- 正常流程（先写空表建父表）必须照常工作
        data.cfg = {}
        data.cfg.sub = {}
        data.cfg.sub.v = 1
        fake_ltimer.debug_fastward(10)
        assert(player.storage[27].cfg.sub.v == 1)
        assert(data.cfg.sub.v == 1)
    end

    do
        -- 假引擎保真度：原生层的父级校验必须和真引擎一致（table_api.py
        -- `_Up1SetTableValueAndCheckValid`）。这条用例不经过代理，直接打原生接口：
        -- 万一以后 Lua 层的父级校验被绕过或回退，原生层仍要拒绝，而不是补建中间表。
        local player = new_player()
        save_data.load_table(player, 28)

        local ok1, err1 = pcall(function ()
            player.handle:set_save_table_key_value(28, 'a', 1, 'b', '', '')
        end)
        assert(not ok1, '父表缺失时原生写入必须报错')
        assert(tostring(err1):find('save_table_exceed_table_depth', 1, true), tostring(err1))
        assert(player.storage[28] == nil or player.storage[28].a == nil, '不得补建父表')

        -- 读取遇到非表父级返回 nil（引擎逐层走路径，不报错）
        player.storage[28] = { a = 1 }
        assert(player.handle:get_save_table_key_value(28, 'a', 'b', '') == nil)

        -- 删除同样受父级校验约束（引擎 errcode 4）
        local ok2, err2 = pcall(function ()
            player.handle:remove_save_table_key_value(28, 'a', 'b', '')
        end)
        assert(not ok2, '父字段不是表时原生删除必须报错')
        assert(tostring(err2):find('save_table_exceed_table_depth', 1, true), tostring(err2))
        assert(player.storage[28].a == 1, '删除报错后原生不得被改动')
    end

    do
        -- 删除分支刻意不做父级校验、直接交给引擎：父表缺失 / 不是表时报错（沿用引擎语义，
        -- 与 ECA 侧的 no-op 是有意的差异，不要"顺手对齐"成 no-op）。
        local player = new_player()
        local data = save_data.load_table(player, 29)

        data.p = {}
        local captured = data.p
        data.p = nil

        local ok, err = pcall(function () captured.x = nil end)
        assert(not ok, '父表缺失时删除子字段必须报错（沿用引擎语义）')
        assert(tostring(err):find('save_table_exceed_table_depth', 1, true), tostring(err))
        assert(player.storage[29].p == nil, '删除报错后原生不得被改动')
    end

    do
        -- 父表还在暂存队列里（本会话刚建、尚未落盘）时删除它的子字段：写入侧对同一种
        -- 父级是延期，删除侧也必须能正常完成，而不是误报「父表不存在」（errcode 4）。
        -- 删除前先把该槽位的暂存写入排空，父表才真正落盘。
        local player = new_player()
        local data = save_data.load_table(player, 30)

        data.a = {}
        data.a.b = {}
        data.a.b.c = 1

        local ok, err = pcall(function () data.a.b.c = nil end)
        assert(ok, '父表待落盘时删除子字段必须成功，实际：' .. tostring(err))

        fake_ltimer.debug_fastward(20)
        assert(type(player.storage[30].a) == 'table')
        assert(type(player.storage[30].a.b) == 'table', '父表必须先落盘再执行删除')
        assert(player.storage[30].a.b.c == nil, '被删除的字段不得留在原生')

        local set_index = find_call(player.calls, 'set', 'a', 'b', '')
        local remove_index = find_call(player.calls, 'remove', 'a', 'b', 'c')
        assert(set_index and remove_index and set_index < remove_index,
            '父表写入必须排在删除之前')
        assert(count_calls(player.calls, 'remove', 'a', 'b', 'c') == 1)
        assert(count_calls(player.calls, 'set', 'a', 'b', 'c') == 0,
            '被删除取代的暂存写入不得下发到原生')
    end

    do
        -- key 不能是空字符串：引擎用 `''` 表示「这一层没有 key」，第 2/3 层的空 key 会被
        -- 当成「没有这一层」，退化成对父级赋值，把父表整个覆盖成标量。
        local player = new_player()
        local data = save_data.load_table(player, 31)

        data.a = {}

        local ok1, err1 = pcall(function () data[''] = 1 end)
        assert(not ok1, '第 1 层空字符串 key 必须报错')
        assert(tostring(err1):find('不能是空字符串', 1, true), tostring(err1))

        local ok2, err2 = pcall(function () data.a[''] = 1 end)
        assert(not ok2, '第 2 层空字符串 key 必须报错')
        assert(tostring(err2):find('不能是空字符串', 1, true), tostring(err2))

        data.a.b = {}
        local ok3, err3 = pcall(function () data.a.b[''] = 1 end)
        assert(not ok3, '第 3 层空字符串 key 必须报错')
        assert(tostring(err3):find('不能是空字符串', 1, true), tostring(err3))

        fake_ltimer.debug_fastward(20)
        assert(type(player.storage[31].a) == 'table', '父表不得被空 key 覆盖成标量')
        assert(type(player.storage[31].a.b) == 'table', '第 2 层表不得被空 key 覆盖成标量')
        assert(find_call(player.calls, 'set', '', '', '', 1) == nil, '空 key 不得下发到原生')
        assert(find_call(player.calls, 'set', 'a', '', '', 1) == nil, '空 key 不得下发到原生')
        assert(find_call(player.calls, 'set', 'a', 'b', '', 1) == nil, '空 key 不得下发到原生')
    end

    do
        -- set_table：根上整树替换。没出现在表里的键（任意层）必须删掉；值没变的字段不得重写。
        local player = new_player({
            [32] = {
                keep = 1,
                change = 1,
                drop = { deep = true },
                sub = { a = 1, b = 2 },
            },
        })
        save_data.load_table(player, 32)

        save_data.set_table(player, 32, {
            keep = 1,
            change = 2,
            sub = { a = 1, c = 3 },
        })
        fake_ltimer.debug_fastward(20)

        local storage = player.storage[32]
        assert(storage.keep == 1)
        assert(storage.change == 2)
        assert(storage.drop == nil, '没出现在表里的键必须删掉')
        assert(storage.sub.b == nil, '子表里没出现的键也要删掉')
        assert(storage.sub.c == 3, '子表里新增的键必须写上')
        assert(count_calls(player.calls, 'set', 'keep', '', '', 1) == 0, '值没变的字段不得重写')
        assert(count_calls(player.calls, 'set', 'sub', 'a', '', 1) == 0, '子表里值没变的字段不得重写')
        assert(count_calls(player.calls, 'remove', 'drop', '') == 1, '多出来的键必须删除')
    end

    do
        -- set_table 子树路径 + 目标为空：写一张空表覆盖（1 次），不逐键删除。
        local player = new_player({
            [33] = {
                sub = { a = 1, b = 2, c = 3 },
            },
        })
        save_data.load_table(player, 33)

        save_data.set_table(player, 33, 'sub', {})
        fake_ltimer.debug_fastward(20)

        assert(next(player.storage[33].sub) == nil, '空表覆盖必须清掉所有子字段')
        assert(count_calls(player.calls, 'remove') == 0, '清空子树不得逐键删除')
        assert(count_calls(player.calls, 'set', 'sub', '', '') == 1)
    end

    do
        -- 根上 set_table({})：原生没有「整表写到根」的操作，只能逐键删除。
        local player = new_player({ [34] = { a = 1, b = 2 } })
        save_data.load_table(player, 34)

        save_data.set_table(player, 34, {})
        fake_ltimer.debug_fastward(20)

        assert(next(player.storage[34]) == nil, '根上的空表必须清空整个槽位')
        assert(count_calls(player.calls, 'remove') == 2)
    end

    do
        -- 校验不通过时整体报错：一个字段都不写。
        local player = new_player()
        save_data.load_table(player, 35)

        local ok, err = pcall(function ()
            save_data.set_table(player, 35, { a = 1, bad = { x = { y = { z = 1 } } } })
        end)
        assert(not ok, '超过 3 层必须报错')
        assert(tostring(err):find('最多只支持', 1, true), tostring(err))

        local ok_key = pcall(function ()
            save_data.set_table(player, 35, { a = 1, [2] = { [''] = 1 } })
        end)
        assert(not ok_key, '表里的空字符串 key 必须报错')

        fake_ltimer.debug_fastward(20)
        assert(count_calls(player.calls, 'set') == 0, '校验失败不得写进任何一个字段')
        assert(player.storage[35].a == nil)
    end

    do
        -- set_field：auto 关闭时父表缺失直接报错（与点写一致），不写任何东西。
        local player = new_player()
        save_data.load_table(player, 36)

        local ok, err = pcall(function ()
            save_data.set_field(player, 36, 'a', 'b', 1)
        end)
        assert(not ok, 'auto 关闭时父表缺失必须报错')
        assert(tostring(err):find('父表不存在', 1, true), tostring(err))
        assert(count_calls(player.calls, 'set') == 0)
    end

    do
        -- set_field + auto：缺的层建出来、不是表的层换成表（并 warn），值最终一定落地。
        local player = new_player({ [37] = { a = 5 } })
        save_data.load_table(player, 37)

        save_data.auto = true
        local ok, err = pcall(function ()
            save_data.set_field(player, 37, 'a', 'b', 'c', 1)
        end)
        save_data.auto = false

        assert(ok, 'auto 打开时深路径写入必须成功，实际：' .. tostring(err))
        fake_ltimer.debug_fastward(20)
        assert(type(player.storage[37].a) == 'table', '不是表的父级必须换成表')
        assert(player.storage[37].a.b.c == 1)
        assert(warnings[#warnings] and warnings[#warnings]:find('auto', 1, true),
            '换掉非表父级必须记一条 warn')
    end

    do
        -- set_table 到子树路径：父表已存在时整树替换该子树。
        local player = new_player({
            [38] = { hero = { name = 'a', hp = 1 } },
        })
        save_data.load_table(player, 38)

        save_data.set_table(player, 38, 'hero', { hp = 2 })
        fake_ltimer.debug_fastward(20)

        assert(player.storage[38].hero.name == nil, '整树替换必须删掉没出现的键')
        assert(player.storage[38].hero.hp == 2)
    end

    do
        -- 目标路径当前是标量：整表赋值把它覆盖成表（替换语义的必然结果）。
        local player = new_player({ [39] = { a = 5 } })
        local data = save_data.load_table(player, 39)

        data.a = { b = 1 }
        fake_ltimer.debug_fastward(20)

        assert(type(player.storage[39].a) == 'table')
        assert(player.storage[39].a.b == 1)
    end

    do
        -- 替换后重新索引必须读到新内容，不能被代理缓存里的旧子表挡住。
        local player = new_player({
            [40] = { hero = { name = 'old', hp = 1 } },
        })
        local data = save_data.load_table(player, 40)

        assert(data.hero.name == 'old')
        data.hero = { name = 'new' }
        fake_ltimer.debug_fastward(20)

        assert(data.hero.name == 'new', '替换后重新索引必须读到新内容')
        assert(data.hero.hp == nil, '被替换掉的字段不得残留')
    end

    do
        -- set_field 写标量 / 写 nil 删除。
        local player = new_player({ [41] = { a = { b = 1 } } })
        save_data.load_table(player, 41)

        save_data.set_field(player, 41, 'a', 'b', 2)
        fake_ltimer.debug_fastward(10)
        assert(player.storage[41].a.b == 2)

        save_data.set_field(player, 41, 'a', 'b', nil)
        fake_ltimer.debug_fastward(10)
        assert(player.storage[41].a.b == nil)
    end

    do
        -- 早于本会话的 key 不在快照里、但原生有值：整表替换也要能把它删掉。
        local player = new_player({
            [42] = { old = 1, keep = 2 },
        })
        local data = save_data.load_table(player, 42)

        -- 第三方绕过代理把 old 改掉，代理以原生为准。
        player.handle:set_save_table_key_value(42, 'old', 9, '', '', '')
        assert(data.old == 9)

        save_data.set_table(player, 42, { keep = 2 })
        fake_ltimer.debug_fastward(20)
        assert(player.storage[42].old == nil, '被原生死值遮住的 key 也必须删掉')
        assert(player.storage[42].keep == 2)
    end

    do
        -- key 在前、值在最后：参数个数不对必须当场报错，不能把 key 当成值写下去。
        local player = new_player({ [43] = { a = { b = 1 } } })
        save_data.load_table(player, 43)

        local ok1 = pcall(function () save_data.set_field(player, 43, 'a') end)
        assert(not ok1, 'set_field 至少要给一个 key 和一个值')

        local ok2 = pcall(function () save_data.set_field(player, 43, 'a', 'b', 'c', 'd', 1) end)
        assert(not ok2, 'set_field 最多三层 key')

        local ok3 = pcall(function () save_data.set_table(player, 43, 'a', 'b', 'c', {}) end)
        assert(not ok3, 'set_table 最多两层 key')

        local ok4 = pcall(function () save_data.set_table(player, 43, 'a', 1) end)
        assert(not ok4, 'set_table 最后一个参数必须是表')

        fake_ltimer.debug_fastward(20)
        assert(player.storage[43].a.b == 1, '参数不对时不得写进任何东西')
    end
end

local ok, err = xpcall(run_tests, debug.traceback)
restore_runtime()

if not ok then
    error(err)
end

print('save_data unittest passed')
