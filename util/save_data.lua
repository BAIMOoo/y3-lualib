--存档
---@class SaveData
local M = {}

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
---> 编辑器已经不再支持允许覆盖模式。
---@param player Player
---@param slot integer
---@param disable_cover? boolean # 是否禁用覆盖，必须和存档设置中的一致（默认为 `true`)
---@return table
function M.load_table(player, slot, disable_cover)
    local last_table = M.player_tables[player][slot]
    if last_table then
        if last_table[2] == disable_cover then
            return last_table[1]
        end
        error('存档的覆盖类型设置与上次不一致！')
    end
    last_table = {}
    M.player_tables[player][slot] = last_table
    if disable_cover == true or disable_cover == nil then
        last_table[1] = M.load_table_with_cover_disable(player, slot)
    else
        last_table[1] = M.load_table_with_cover_enable(player, slot)
    end
    last_table[2] = disable_cover
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
---> 的字段写入由引擎自己落盘，这里排空暂存写入只是为了调用方拿到的原生快照完整。
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

    local function get_parent_path(key1, key2, key3)
        if key3 and key3 ~= '' then
            return key1, key2, ''
        end
        if key2 and key2 ~= '' then
            return key1, '', ''
        end
    end

    local function should_delay_write(key1, key2, key3)
        local parent_key1, parent_key2, parent_key3 = get_parent_path(key1, key2, key3)
        return parent_key1
           and (is_created_in_this_stage(parent_key1, parent_key2, parent_key3)
             or is_pending_table(parent_key1, parent_key2, parent_key3))
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
            elseif type(write.value) == 'table' then
                unmark_pending_table(write.key1, write.key2, write.key3)
            end
        end
        for i = write_count + 1, #pending_writes do
            pending_writes[i] = nil
        end
    end

    local function write_native(key1, key2, key3, value)
        if type(value) == 'table' then
            value = {}
        end
        player.handle:set_save_table_key_value(slot
            , key1
            , value
            , key2
            , key3
            , ''
        )
        unmark_deleted(key1, key2, key3)
        if type(value) == 'table' then
            unmark_pending_table(key1, key2, key3)
            mark_created(key1, key2, key3)
        end
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
                    write_native(write.key1, write.key2, write.key3, write.value)
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

        -- A new assignment takes effect in Lua immediately, even when the
        -- native write is deferred until the parent table exists.
        unmark_deleted(key1, key2, key3)

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

    local function get_value(key, path)
        local key1, key2, key3 = unpack_path(key, path)
        if is_deleted(key1, key2, key3) then
            return nil
        end
        return read_native_value(key1, key2, key3)
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
            raw[key] = value

            set_value(key, value, path)
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
                --原生已有值：以原生为准，不回写 raw，避免再造一个会过期的影子。
                value = native_value
            else
                value = raw[key]
                if value == nil then
                    value = get_value(key, path)
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
