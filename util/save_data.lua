--存档
---@class SaveData
local M = {}

--写入模型（先看这里：改动前先确认不要给这套存档再加显式上传/保存）：
-- * 本文件注释里的「落到原生 / 写进内存 / 落盘」都指写进引擎内存中的存档表，不是写数据库；
--   引擎负责把内存存档写进数据库，默认只发生在游戏结束时，与这里的写入是否及时无关。
-- * 禁止覆盖模式（`load_table` 的默认模式）的表存档，字段写入是实时的：每次赋值都会立刻
--   写进引擎内存存档，不需要任何显式上传/保存接口，`Player:upload_save_data` 不是保存它的途径。
-- * 只有「先建父表、再写子字段」这类嵌套字段会被暂存，约 0.03s 后的 flush 轮次自动写进内存；
--   `$Y3-即将切换关卡` 前会统一排空。
-- * 写嵌套字段（key2 / key3）前，父级必须是表：原生已是表、或本轮刚建 / 暂存队列里即将落盘的
--   表都算。父级缺失或不是表时直接报错（与 ECA 一致）。引擎自己也会拒绝这种写入
--   （table_api._Up1SetTableValueAndCheckValid 对非表父级返回 errcode 4 并抛错，绝不会补建
--   中间表），这里提前拦是为了当场抛出、给出准确路径，并避免写入排到 flush 后才失败、
--   被当成可重试写入反复重试再放弃。
-- * 暂存/重试中的字段在 Lua 侧立即可读（读取以 Lua 侧为准），写进内存后以原生值为准。
---@private
M.table_cache = setmetatable({}, { __mode = 'k' })

---@private
---同一张原生表可能同时挂在多个路径下，代理缓存必须按「原生表 + 路径」两级区分，
---否则第二个路径会复用第一个路径的代理，之后所有写入都会落到第一个路径上。
---@param path table|integer|nil
---@return string
local function cache_path_key(path)
    if path == nil then
        return ''
    end
    if type(path) == 'number' then
        return '#:' .. tostring(path)
    end
    local parts = {}
    for i = 1, #path do
        local key = path[i]
        parts[i] = type(key) .. ':' .. tostring(key)
    end
    return table.concat(parts, '\0')
end

---@private
---@param raw table
---@param path table|integer|nil
---@return table path_cache
---@return string key
local function proxy_cache_slot(raw, path)
    local path_cache = M.table_cache[raw]
    if not path_cache then
        path_cache = {}
        M.table_cache[raw] = path_cache
    end
    return path_cache, cache_path_key(path)
end

-- 获取玩家的存档数据（布尔）
---@param player Player
---@param slot integer
---@return boolean
function M.load_boolean(player, slot)
    return player.handle:get_save_data_bool_value(slot) or false
end

-- 保存玩家的存档数据（布尔）
---@param player Player
---@param slot integer
---@param value boolean
function M.save_boolean(player, slot, value)
    player.handle:set_save_data_bool_value(slot, value)
end

-- 获取玩家的存档数据（整数）
---@param player Player
---@param slot integer
---@return integer
function M.load_integer(player, slot)
    return player.handle:get_save_data_int_value(slot) or 0
end

-- 保存玩家的存档数据（整数）
---@param player Player
---@param slot integer
---@param value integer
function M.save_integer(player, slot, value)
    local int = math.tointeger(value)
    if not int then
        error('存档数据必须是整数')
    end
    player.handle:set_save_data_int_value(slot, int)
end

---增加玩家的存档数据（整数）
---@param player Player
---@param slot integer
---@param value integer
function M.add_integer(player, slot, value)
    local int = math.tointeger(value)
    if not int then
        error('存档数据必须是整数')
    end
    player.handle:add_save_data_int_value(slot, int)
end

-- 获取玩家的存档数据（实数）
---@param player Player
---@param slot integer
---@return number
function M.load_real(player, slot)
    return y3.helper.tonumber(player.handle:get_save_data_fixed_value(slot)) or 0.0
end

-- 保存玩家的存档数据（实数）
---@param player Player
---@param slot integer
---@param value number
function M.save_real(player, slot, value)
    player.handle:set_save_data_fixed_value(slot, Fix32(value))
end

---增加玩家的存档数据（实数）
---@param player Player
---@param slot integer
---@param value number
function M.add_real(player, slot, value)
    player.handle:add_save_data_fixed_value(slot, Fix32(value))
end

-- 获取玩家的存档数据（字符串）
---@param player Player
---@param slot integer
---@return string
function M.load_string(player, slot)
    return player.handle:get_save_data_str_value(slot) or ''
end

-- 保存玩家的存档数据（字符串）
---@param player Player
---@param slot integer
---@param value string
function M.save_string(player, slot, value)
    player.handle:set_save_data_str_value(slot, value)
end

---@type table<Player, table<integer, [table, boolean]>>
M.player_tables = y3.util.multiTable(2)

---获取玩家的存档数据（表）。修改这个表中的字段会自动更新到存档中。
---禁止覆盖模式下最多支持 3 层嵌套（`data.a.b.c` 是最深的一层），第 4 层字段非法：写入或删除第 4 层字段会直接报错，读取第 4 层字段恒为 `nil`（因此遍历第 3 层表得到空表）。
---写嵌套字段（key2 / key3）前父级必须是表（原生已是表，或同一轮里刚建/待落盘的表）；父级缺失或不是表时直接报错（引擎自己也会拒绝这种写入并返回 errcode 4，这里提前拦是为了当场抛出并给出准确路径）。
---> 编辑器已经不再支持允许覆盖模式。
---> 表内字段的写入是实时的：每次赋值都会立刻写进引擎内存中的存档表，不需要（也不应该）再调用
---> `y3.save_data.upload_save_data` 或 `Player:upload_save_data` 来保存（引擎负责把内存存档写进
---> 数据库，默认只发生在游戏结束时）。唯一会被延后的是「父表还没写进内存」的嵌套写入：
---> 它会在约 0.03s 后的 flush 轮次自行写入，切关卡前也会被统一排空。
---@param player Player
---@param slot integer
---@param disable_cover? boolean # 是否禁用覆盖，必须和存档设置中的一致（默认为 `true`；`nil` 与 `true` 等价）
---@return table
function M.load_table(player, slot, disable_cover)
    -- `nil` 与 `true` 都表示禁止覆盖模式，先归一化再比较：否则 ECA 层（固定传 `true`）
    -- 与 Lua 层（默认传 `nil`）访问同一个槽位时会误报「覆盖类型设置与上次不一致」。
    local disable = disable_cover == true or disable_cover == nil
    local last_table = M.player_tables[player][slot]
    if last_table then
        if last_table[2] == disable then
            return last_table[1]
        end
        error('存档的覆盖类型设置与上次不一致！')
    end
    last_table = {}
    if disable then
        last_table[1] = M.load_table_with_cover_disable(player, slot)
    else
        last_table[1] = M.load_table_with_cover_enable(player, slot)
    end
    last_table[2] = disable
    -- 加载成功后才登记缓存：加载失败时留下的半成品会让后续调用拿到
    -- 「覆盖类型设置与上次不一致」这种与真实原因无关的错误。
    M.player_tables[player][slot] = last_table
    return last_table[1]
end

---@private
---@type table<Player, table<integer, { timer: LocalTimer, table: table }>>
M.save_table_pool = {}

---保存玩家的存档数据（表），存档设置中必须使用允许覆盖模式。  
---> 编辑器已经不再支持允许覆盖模式，因此这个函数已经没有用了。
---@deprecated
---@param player Player
---@param slot integer
---@param t table
function M.save_table(player, slot, t)
    ---@diagnostic disable-next-line: deprecated
    if player ~= y3.player.get_local() then
        return
    end
    assert(type(t) == 'table', '数据类型必须是表！')
    M.want_to_save = t
    local pools = M.save_table_pool[player]
    if not pools then
        pools = {}
        M.save_table_pool[player] = pools
    end
    local pool = pools[slot]
    if not pool then
        pool = {}
        pools[slot] = pool
        pool.timer = y3.ltimer.wait(0.1, function ()
            pools[slot] = nil
            local t = pool.table
            t = y3.proxy.raw(t) or t
            player.handle:set_save_data_table_value(slot, t)
            M.upload_save_data(player)
        end)
    end
    pool.table = t
end

---@private
---@type table<Player, LocalTimer>
M.upload_timer_map = {}

---@private
---@type table<Player, table<integer, fun(drain?: boolean)>>
M.flush_save_table_map = y3.util.multiTable(2)

---@private
---把暂存写入排空到原生存档。`drain` 模式下 `flush_pending_writes` 不会回调上传，
---因此排空与上传之间不存在递归。
---@param player Player
local function drain_pending_writes(player)
    for _, flush in pairs(M.flush_save_table_map[player]) do
        flush(true)
    end
end

---上传玩家的存档数据。
---> 只有允许覆盖模式的表格存档需要显式上传；禁止覆盖模式（`load_table` 的默认模式）
---> 的字段写入会实时写进引擎内存存档，不需要通过本接口保存：这里排空暂存写入只是为了让
---> 显式上传时调用方拿到的原生快照完整（禁止覆盖模式下的暂存写入会由 flush 轮次 / 切关卡
---> 自行写进内存）。引擎负责把内存存档写进数据库，默认只发生在游戏结束时。
---> 详见 `load_table` 的注释。
---@param player Player
function M.upload_save_data(player)
    drain_pending_writes(player)
    local timer = M.upload_timer_map[player]
    if timer then
        return
    end
    M.upload_timer_map[player] = y3.ltimer.wait(0.1, function ()
        M.upload_timer_map[player] = nil
        -- 排定时器之后写入的数据也必须先落盘，否则上传的原生快照会缺字段。
        drain_pending_writes(player)
        player.handle:upload_save_data()
        log.info('自动保存存档：', player)
    end)
end

y3.game:event_on('$Y3-即将切换关卡', function ()
    for _, player_flushes in pairs(M.flush_save_table_map) do
        for _, flush in pairs(player_flushes) do
            flush(true)
        end
    end
    for _, timer in pairs(M.upload_timer_map) do
        timer:execute()
    end
    for _, pools in pairs(M.save_table_pool) do
        for _, pool in pairs(pools) do
            pool.timer:execute()
        end
    end
end)

---@private
---@param player Player
---@param slot integer
---@return table
function M.load_table_with_cover_enable(player, slot)
    local save_data = player.handle:get_save_data_table_value(slot) or {}
    local create_proxy

    ---@type Proxy.Config
    local proxy_config = {
        anySetter = function (self, raw, key, value, config, custom)
            if custom >= 3 and type(value) == 'table' then
                error('存档表最多只支持3层嵌套')
            end
            if type(key) ~= 'string'
            and math.type(key) ~= 'integer' then
                error('存档的key必须是字符串或者整数')
            end
            value = y3.helper.as_lua(value)
            local vtype = type(value)
            if  vtype ~= 'nil'
            and vtype ~= 'string'
            and vtype ~= 'boolean'
            and vtype ~= 'number'
            and vtype ~= 'table' then
                error('存档的值只能是基础类型或表')
            end
            if vtype == 'table' and y3.proxy.raw(value) then
                value = y3.proxy.raw(value)
            end
            raw[key] = value

            ---@diagnostic disable-next-line: deprecated
            M.save_table(player, slot, save_data)
        end,
        anyGetter = function (self, raw, key, config, custom)
            local value = raw[key]
            if type(value) == 'table' then
                return create_proxy(value, custom + 1)
            end
            return y3.helper.as_lua(value)
        end
    }

    function create_proxy(raw, level)
        local path_cache, key = proxy_cache_slot(raw, level)
        local v = path_cache[key]
        if not v then
            v = y3.proxy.new(raw, proxy_config, level)
            path_cache[key] = v
        end
        return v
    end

    local proxy_save_data = create_proxy(save_data, 0)

    return proxy_save_data
end

---@private
--单条字段写入失败后的最多尝试次数：失败先重排到下一轮，超过次数就放弃并记录日志。
--坏写入既不能吃掉同批次的其它写入，也不能让 flush 定时器无限空转。
local MAX_WRITE_ATTEMPTS = 3

---@private
---禁止覆盖模式的代理实现：原生接口只有 key1/key2/key3，因此最多 3 层嵌套。
---第 4 层字段非法：写入或删除会报错，读取恒为 `nil`。
---@param player Player
---@param slot integer
---@return table
function M.load_table_with_cover_disable(player, slot)
    local save_data = player.handle:get_save_data_table_value(slot) or {}
    local create_proxy
    local pending_created = {}
    local pending_tables = {}
    local pending_writes = {}
    local deleted_keys = {}
    local unflushed_keys = {}
    local flush_timer

    local function unpack_path(key, path)
        local key1 = path and path[1]
        if not key1 then
            key1 = key
            key = ''
        end
        local key2 = path and path[2]
        if not key2 then
            key2 = key
            key = ''
        end
        local key3 = path and path[3] or key
        return key1, key2, key3
    end

    local function path_key(key1, key2, key3)
        local function encode_key(key)
            if key == nil then
                return 'nil:'
            end
            return type(key) .. ':' .. tostring(key)
        end
        return encode_key(key1)
            .. '\0' .. encode_key(key2)
            .. '\0' .. encode_key(key3)
    end

    --创建标记要记下 key 三元组，删除父表时才能按路径把失效的标记清干净。
    local function mark_created(key1, key2, key3)
        pending_created[path_key(key1, key2, key3)] = { key1, key2, key3 }
    end

    local function is_created_in_this_stage(key1, key2, key3)
        return pending_created[path_key(key1, key2, key3)] ~= nil
    end

    local function mark_pending_table(key1, key2, key3)
        pending_tables[path_key(key1, key2, key3)] = true
    end

    local function unmark_pending_table(key1, key2, key3)
        pending_tables[path_key(key1, key2, key3)] = nil
    end

    local function is_pending_table(key1, key2, key3)
        return pending_tables[path_key(key1, key2, key3)] == true
    end

    local function mark_deleted(key1, key2, key3)
        deleted_keys[path_key(key1, key2, key3)] = true
    end

    local function unmark_deleted(key1, key2, key3)
        deleted_keys[path_key(key1, key2, key3)] = nil
    end

    local function is_deleted(key1, key2, key3)
        return deleted_keys[path_key(key1, key2, key3)] == true
    end

    --字段的最新值还只存在于 Lua 侧（`raw`）：写入被推迟或写入失败时原生读到的还是旧值，
    --这期间的读取必须以 Lua 侧为准。落盘成功后清掉，读取重新以原生为准。
    local function mark_unflushed(key1, key2, key3)
        unflushed_keys[path_key(key1, key2, key3)] = true
    end

    local function unmark_unflushed(key1, key2, key3)
        unflushed_keys[path_key(key1, key2, key3)] = nil
    end

    local function has_unflushed_write(key1, key2, key3)
        return unflushed_keys[path_key(key1, key2, key3)] == true
    end

    --原生写入要求路径上的父级已经是表：引擎对缺失 / 不是表的父级返回 errcode 4 并报错，
    --不会按 key1/key2/key3 补建中间表。所以任何一层祖先表「本轮刚建」或「还在等待落盘」
    --时这次写入都得等下一轮：只看直接父表会漏掉「祖父表刚建、中间表尚不存在」的三层写入。
    local function should_delay_write(key1, key2, key3)
        if not (key2 and key2 ~= '') then
            return false
        end
        if key3 and key3 ~= '' then
            if is_created_in_this_stage(key1, key2, '') or is_pending_table(key1, key2, '') then
                return true
            end
        end
        return is_created_in_this_stage(key1, '', '') or is_pending_table(key1, '', '')
    end

    local function is_same_or_child_path(key1, key2, key3, parent_key1, parent_key2, parent_key3)
        if key1 ~= parent_key1 then
            return false
        end
        if parent_key2 == '' then
            return true
        end
        if key2 ~= parent_key2 then
            return false
        end
        if parent_key3 == '' then
            return true
        end
        return key3 == parent_key3
    end

    --原生 remove 删掉的是整棵子树，因此该路径及其子孙的「本轮已创建」标记都已失效。
    local function unmark_created(key1, key2, key3)
        for path, keys in pairs(pending_created) do
            if is_same_or_child_path(keys[1], keys[2], keys[3], key1, key2, key3) then
                pending_created[path] = nil
            end
        end
    end

    local function remove_pending_writes(key1, key2, key3)
        local write_count = 0
        for i = 1, #pending_writes do
            local write = pending_writes[i]
            if not is_same_or_child_path(write.key1, write.key2, write.key3, key1, key2, key3) then
                write_count = write_count + 1
                pending_writes[write_count] = write
            else
                --被撤销的暂存写入不再代表 Lua 侧的最新值。
                unmark_unflushed(write.key1, write.key2, write.key3)
                if type(write.value) == 'table' then
                    unmark_pending_table(write.key1, write.key2, write.key3)
                end
            end
        end
        for i = write_count + 1, #pending_writes do
            pending_writes[i] = nil
        end
    end

    ---路径文本，仅用于报错：`a` / `a.b`
    ---@param key1 any
    ---@param key2 any
    ---@return string
    local function path_text(key1, key2)
        if key2 == nil or key2 == '' then
            return tostring(key1)
        end
        return ('%s.%s'):format(tostring(key1), tostring(key2))
    end

    --读取原生同路径的值，不做任何删除标记判断。
    local function read_native_value(key1, key2, key3)
        return player.handle:get_save_table_key_value(slot
            , key1
            , key2
            , key3
            ---@diagnostic disable-next-line: param-type-mismatch
            , nil
            , ''
        )
    end

    --该层在「原生已是表」或「本会话即将建成表」的视角下是不是表。
    --本轮刚建的表、暂存队列里等待落盘的表都算，其余以原生为准。
    local function is_table_level(key1, key2)
        if is_pending_table(key1, key2, '') or is_created_in_this_stage(key1, key2, '') then
            return true
        end
        return type(read_native_value(key1, key2, '')) == 'table'
    end

    ---与 ECA 的路径语义对齐：写嵌套字段前，父级必须是表。
    ---父级在原生已是表、或本会话刚建 / 暂存队列里即将建成表时放行；父级缺失或不是表时
    ---直接报错（引擎自己也会拒绝这种写入并返回 errcode 4，这里提前拦是为了当场抛出并给出
    ---准确路径）。删除分支不做这个校验，直接交给引擎：父表缺失 / 不是表时同样按 errcode 4
    ---报错。这是有意的——删除一个不存在的路径按用法错误处理（ECA 侧是 no-op，两边刻意不同）。
    ---@param key1 any
    ---@param key2 any
    ---@param key3 any
    local function check_parent_table(key1, key2, key3)
        if key2 == nil or key2 == '' then
            --顶层字段没有父级
            return
        end
        local function assert_level(parent_key1, parent_key2)
            if is_table_level(parent_key1, parent_key2) then
                return
            end
            local text = path_text(parent_key1, parent_key2)
            if read_native_value(parent_key1, parent_key2, '') == nil then
                error(('存档路径的父表不存在：%s'):format(text))
            end
            error(('存档路径的父字段不是表：%s'):format(text))
        end
        --先查浅层：父字段是标量时，读它的子路径可能直接报错，浅层校验能先给出准确原因。
        assert_level(key1, '')
        if key3 ~= nil and key3 ~= '' then
            assert_level(key1, key2)
        end
    end

    local function write_native(key1, key2, key3, value)
        --写入前再校验一次父级：排空/重试路径上父表的建表写入可能已经失败并被放弃。
        check_parent_table(key1, key2, key3)
        local is_table = type(value) == 'table'
        if is_table then
            value = {}
        end
        player.handle:set_save_table_key_value(slot
            , key1
            , value
            , key2
            , key3
            , ''
        )
        --已经落到原生，Lua 侧不再是这个字段的唯一持有者。
        unmark_unflushed(key1, key2, key3)
        unmark_deleted(key1, key2, key3)
        if is_table then
            unmark_pending_table(key1, key2, key3)
            mark_created(key1, key2, key3)
        else
            --标量写入把该路径的子树整个换掉，其上「本轮已创建的表」标记（含子孙）随之失效，
            --否则后续写子字段会被误判成「父表即将落盘」而暂存，错误/写入被推迟。
            unmark_created(key1, key2, key3)
        end
    end

    ---@param write { key1: any, key2: any, key3: any }
    ---@return string
    local function write_log_text(write)
        return ('slot=%s key1=%s key2=%s key3=%s'):format(tostring(slot)
            , tostring(write.key1)
            , tostring(write.key2)
            , tostring(write.key3)
        )
    end

    local flush_pending_writes

    local function schedule_flush()
        if flush_timer then
            return
        end
        flush_timer = y3.ltimer.wait(0.03, function ()
            flush_pending_writes()
        end)
    end

    function flush_pending_writes(drain)
        if flush_timer then
            flush_timer:remove()
            flush_timer = nil
        end

        while true do
            pending_created = {}
            if #pending_writes == 0 then
                return
            end

            local writes = pending_writes
            pending_writes = {}

            for _, write in ipairs(writes) do
                if should_delay_write(write.key1, write.key2, write.key3) then
                    pending_writes[#pending_writes + 1] = write
                    if type(write.value) == 'table' then
                        mark_pending_table(write.key1, write.key2, write.key3)
                    end
                else
                    --单条写入失败不能让同批次的其它写入一起丢：每条单独 pcall，失败的
                    --重排到下一轮，超过次数才放弃。同一路径同时最多只有一个暂存写入
                    --（新赋值会撤销旧的），所以重排不会让旧值盖掉新值。
                    local ok, err = pcall(write_native, write.key1, write.key2, write.key3, write.value)
                    if not ok then
                        write.attempts = (write.attempts or 0) + 1
                        if write.attempts < MAX_WRITE_ATTEMPTS then
                            log.error('存档字段写入失败，稍后重试：', err, write_log_text(write))
                            pending_writes[#pending_writes + 1] = write
                        else
                            --放弃写入时该路径的标记必须一并清掉：
                            -- * 残留的「等待写进内存的表」会让子字段写入被 should_delay_write
                            --   永久推迟，`drain` 模式（切关卡 / upload_save_data）会在
                            --   flush_pending_writes 的 while true 里死循环；
                            -- * 残留的「还没写进内存」会让读取永久遮蔽原生后来的新值。
                            unmark_pending_table(write.key1, write.key2, write.key3)
                            unmark_unflushed(write.key1, write.key2, write.key3)
                            log.error('存档字段写入连续失败，已放弃：', err, write_log_text(write))
                        end
                    end
                end
            end

            -- 依赖父表的暂存写入留到下一轮；`drain` 模式继续循环直到全部落盘。
            if not drain and (#pending_writes > 0 or next(pending_created)) then
                schedule_flush()
                return
            end
        end
    end

    M.flush_save_table_map[player][slot] = flush_pending_writes

    local function set_value(key, value, path)
        local key1, key2, key3 = unpack_path(key, path)
        if value == nil then
            remove_pending_writes(key1, key2, key3)
            unmark_pending_table(key1, key2, key3)
            unmark_created(key1, key2, key3)
            mark_deleted(key1, key2, key3)
            player.handle:remove_save_table_key_value(slot
                , key1
                , key2
                , key3
            )
            return
        end

        -- 新的赋值在 Lua 侧立即生效，即使原生写入因为父表还没建好而推迟。
        -- 同路径（及其子孙路径）里还挂着的暂存写入已被这次赋值取代：它们会在后续
        -- 轮次落盘，那时顺序已经不等于赋值顺序，甚至可能写进一个已经变成标量的
        -- 父表，所以必须一并撤销（删除分支同样会撤销这些暂存写入）。
        -- 校验放在改标记之前：父级不合法时直接抛错，不留下任何状态。
        check_parent_table(key1, key2, key3)
        remove_pending_writes(key1, key2, key3)
        unmark_deleted(key1, key2, key3)
        mark_unflushed(key1, key2, key3)

        if should_delay_write(key1, key2, key3) then
            pending_writes[#pending_writes + 1] = {
                key1 = key1,
                key2 = key2,
                key3 = key3,
                value = value,
            }
            if type(value) == 'table' then
                mark_pending_table(key1, key2, key3)
            end
            schedule_flush()
            return
        end

        write_native(key1, key2, key3, value)
        if type(value) == 'table' then
            schedule_flush()
        end
    end

    --删除标记只是本会话的读侧影子，只有「原生同路径确实为空」时才成立：
    --第三方绕过本代理（直接调 set_save_table_key_value）或混用其它代理把同路径
    --写回原生后，删除已被覆盖，此时以原生为准并顺手清掉标记。
    ---@return boolean deleted_now 是否仍处于删除状态
    ---@return any native_value 原生值；deleted_now 为 true 时为 nil
    local function resolve_deleted(key1, key2, key3)
        if not is_deleted(key1, key2, key3) then
            return false
        end
        local value = read_native_value(key1, key2, key3)
        if value == nil then
            return true
        end
        unmark_deleted(key1, key2, key3)
        return false, value
    end

    ---@type Proxy.Config
    local proxy_config = {
        cache = false,
        anySetter = function (self, raw, key, value, config, path)
            if type(key) ~= 'string'
            and math.type(key) ~= 'integer' then
                error('表的key必须是字符串或者整数')
            end
            -- 原生接口只有 key1/key2/key3，第 4 层字段无法表示：
            -- 若继续放行，写入会被截断到第 3 层（覆盖父表），删除会连带删掉整个子树。
            if path and #path >= 3 then
                error('存档表最多只支持3层嵌套')
            end
            value = y3.helper.as_lua(value)
            local vtype = type(value)
            if vtype == 'table' then
                -- 代理自带 [CONFIG]/[CUSTOM] 哨兵键，`next(代理)` 恒非 nil；
                -- 必须先解包成原生表再判空，否则空表的代理会被误判成非空表。
                -- 非代理表 `raw` 返回自身，因此普通表的校验语义不变。
                value = y3.proxy.raw(value)
                if next(value) ~= nil then
                    error('禁止覆盖模式下非空表不能作为存档的值')
                end
            elseif vtype ~= 'nil'
            and    vtype ~= 'string'
            and    vtype ~= 'boolean'
            and    vtype ~= 'number' then
                error('存档的值只能是基础类型')
            end
            -- 先落 set_value：父级校验失败会抛错，此时不能在快照上留下一个读得到的影子值。
            set_value(key, value, path)
            raw[key] = value
        end,
        anyGetter = function (self, raw, key, config, path)
            -- 第 4 层字段非法，该层不存在。
            if path and #path >= 3 then
                return nil
            end
            local key1, key2, key3 = unpack_path(key, path)
            local deleted_now, native_value = resolve_deleted(key1, key2, key3)
            if deleted_now then
                return nil
            end
            local value
            if native_value ~= nil then
                --删除被原生值覆盖：以原生为准，不回写 raw，避免再造一个会过期的影子。
                value = native_value
            elseif has_unflushed_write(key1, key2, key3) then
                --本代理的赋值还没落盘：原生现在读到的还是旧值，必须用 Lua 侧的值。
                value = raw[key]
            else
                --其余情况以原生为准：第三方绕过本代理改过原生时不会读到过期快照
                --（与删除标记的对账同理）。两个例外：
                --  * 快照里是表：保留快照里的表，代理身份才稳定、写入才落在同一张表上；
                --  * 原生为空：退回快照值，避免受引擎取值差异影响。
                local cached = raw[key]
                if type(cached) == 'table' then
                    value = cached
                else
                    value = read_native_value(key1, key2, key3)
                    if value == nil then
                        value = cached
                    end
                end
            end
            if type(value) == 'table' then
                local new_path = path and { table.unpack(path) } or {}
                new_path[#new_path+1] = key
                return create_proxy(value, new_path)
            end

            return y3.helper.as_lua(value)
        end
    }

    function create_proxy(raw, path)
        local path_cache, key = proxy_cache_slot(raw, path)
        local v = path_cache[key]
        if not v then
            v = y3.proxy.new(raw, proxy_config, path)
            path_cache[key] = v
        end
        return v
    end

    local proxy_save_data = create_proxy(save_data)

    return proxy_save_data
end

return M
