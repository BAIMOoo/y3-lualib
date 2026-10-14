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
-- * key 只能是字符串或整数，且不能是空字符串：引擎用 `''` 表示「这一层没有 key」，放行空
--   字符串会让第 2/3 层的空 key 退化成对父级赋值（把父表整个覆盖掉），因此写入侧一律拒绝。
-- * 删除不做延期（父级缺失 / 不是表时按 errcode 4 报错，与写入的「延期」不同）；但父级只是
--   还没落盘（本会话刚建 / 还在暂存队列里）时，会先把该槽位的暂存写入排空再下发删除，
--   否则刚建好的父表会被误判成「父表不存在」。
-- * 字段赋一张「非空表」= 把该键位所在的子树整体替换成这张表：未出现在表里的键（任意层）
--   都会删除；空表则只是把该键位写成一个空表（`data.a = {}` 会清掉 a 下面的所有字段）。
--   替换按「值没变就不写」做 diff，不会为了改一个字段而重写整棵子树。
-- * `M.auto`（默认 false）只对「路径当参数传」的写入生效：`M.set_field`、
--   `M.set_table` 的路径前缀、ECA 的「写入存档字段」节点。Lua 的点写 `data.a.b = x`
--   在 a 缺失 / 不是表时由 Lua 语法本身拦下（attempt to index a nil value），代理接不到，
--   因此不受本开关影响；删除（赋 nil）同样不受它影响。
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

---路径当参数传的写入（`set_field` / `set_table` 的路径前缀 / ECA 的写入节点）
---在父级缺失 / 不是表时，是否自动按序补成表。
---
---默认 `false`，即保持旧行为：父级缺失 / 不是表时直接报错。
---置为 `true` 后，写入路径上缺的层会被建出来、不是表的层会被换成表，保证这次写入落地；
---换掉一个已存在的非表值时会打一条 `log.warn` 记录被丢弃的旧值。
---
---只对「路径当参数传」的写入生效：`y3.save_data.set_field`、`y3.save_data.set_table` 的路径前缀，
---以及 ECA 的「写入存档字段」节点。Lua 的点写 `data.a.b = x` 在 `a` 缺失 / 不是表时由 Lua
---语法本身拦下（attempt to index a nil value），代理接不到，因此不受本开关影响；
---删除（赋 `nil`）也不受影响，仍按旧行为报错。
---@type boolean
M.auto = false

---@private
---键路径文本，只用于报错：`a` / `a.b`；`upto` 限定只用前几层。
---@param keys (string|integer)[]
---@param upto? integer
---@return string
local function keys_text(keys, upto)
    local n = upto or #keys
    if n <= 0 then
        return '<存档根>'
    end
    local parts = {}
    for i = 1, n do
        parts[i] = tostring(keys[i])
    end
    return table.concat(parts, '.')
end

---@private
---@param path table|nil
---@param key any
---@return table
local function append_path(path, key)
    local new_path = path and { table.unpack(path) } or {}
    new_path[#new_path + 1] = key
    return new_path
end

---@private
---把带元表的「视图表」物化成普通 Lua 表，并解开代理。
---平台（在线）构建里引擎交回来的实时存档表是「字段藏在 __pairs 后面、raw 键为空」的视图：
---直接 `next` 会当成空表、py 层按原生 pairs 也拿不到字段，因此凡是要遍历的表都先过一遍这里。
---本来就是普通表（无元表）的原样返回，保持原来的身份语义。
---@param value any
---@param depth? integer
---@return any
function M.to_plain_table(value, depth)
    if type(value) ~= 'table' or getmetatable(value) == nil then
        return value
    end
    if (depth or 1) > 8 then
        return value
    end
    local result = {}
    for k, v in pairs(value) do
        result[k] = M.to_plain_table(v, (depth or 1) + 1)
    end
    return result
end

---@private
---@param key any
local function check_key(key)
    if type(key) ~= 'string' and math.type(key) ~= 'integer' then
        error('存档的key必须是字符串或者整数')
    end
    -- 引擎用空字符串表示「这一层没有 key」，放行空字符串会让第 2/3 层的空 key 退化成写父级。
    if key == '' then
        error('存档的key不能是空字符串')
    end
end

---@private
---整表写入前的全量校验：任何一处非法都在写之前抛出，保证不会只写进去一半。
---@param value any
---@param depth integer 当前层数（顶层传 1）
---@param max_depth integer 该路径允许的最大层数
---@param text string 出错时用来定位的路径文本
local function validate_save_table(value, depth, max_depth, text)
    if type(value) ~= 'table' then
        error(('存档的值只能是基础类型：%s'):format(text))
    end
    if depth > max_depth then
        error(('存档表最多只支持3层嵌套：%s'):format(text))
    end
    for k, v in pairs(value) do
        if type(k) ~= 'string' and math.type(k) ~= 'integer' then
            error(('存档的key必须是字符串或者整数：%s'):format(text))
        end
        if k == '' then
            error(('存档的key不能是空字符串：%s'):format(text))
        end
        local child_text = ('%s.%s'):format(text, tostring(k))
        local vtype = type(v)
        if vtype == 'table' then
            validate_save_table(v, depth + 1, max_depth, child_text)
        elseif vtype ~= 'string' and vtype ~= 'boolean' and vtype ~= 'number' then
            error(('存档的值只能是基础类型：%s'):format(child_text))
        end
    end
end

---@private
---沿代理路径取「点写的父表」，返回的 `key` 就是目标字段名。
---`create`（即 `M.auto`）为 true 时，路径上缺失 / 不是表的层会补成表（换掉非表值时打日志）；
---为 false 时父级缺失 / 不是表返回 nil 与报错文案，由调用方决定是报错还是 no-op。
---@param data table 该槽位的顶层代理表
---@param keys (string|integer)[] 1~3 层 key
---@param create boolean
---@return table? parent
---@return string|integer? key
---@return string? err
local function resolve_write_parent(data, keys, create)
    local node = data
    for i = 1, #keys - 1 do
        local name = keys[i]
        local child = node[name]
        if type(child) ~= 'table' then
            local text = keys_text(keys, i)
            if not create then
                if child == nil then
                    return nil, nil, ('存档路径的父表不存在：%s'):format(text)
                end
                return nil, nil, ('存档路径的父字段不是表：%s'):format(text)
            end
            if child ~= nil then
                log.warn(('存档路径的父字段不是表，已按 y3.save_data.auto 换成表：%s'):format(text))
            end
            node[name] = {}
            child = node[name]
        end
        node = child
    end
    return node, keys[#keys]
end

---按 `M.auto` 的规则解析点写目标：返回父表与最后一层 key。
---@param data table 该槽位的顶层代理表
---@param keys (string|integer)[] 1~3 层 key
---@return table? parent
---@return string|integer? key
---@return string? err
function M.resolve_write_parent(data, keys)
    return resolve_write_parent(data, keys, M.auto)
end

---@type table<Player, table<integer, [table, boolean]>>
M.player_tables = y3.util.multiTable(2)

---获取玩家的存档数据（表）。修改这个表中的字段会自动更新到存档中。
---禁止覆盖模式下最多支持 3 层嵌套（`data.a.b.c` 是最深的一层），第 4 层字段非法：写入或删除第 4 层字段会直接报错，读取第 4 层字段恒为 `nil`（因此遍历第 3 层表得到空表）。
---写嵌套字段（key2 / key3）前父级必须是表（原生已是表，或同一轮里刚建/待落盘的表）；父级缺失或不是表时直接报错（引擎自己也会拒绝这种写入并返回 errcode 4，这里提前拦是为了当场抛出并给出准确路径）。
---key 只能是字符串或整数，且不能是空字符串（引擎用 `''` 表示「这一层没有 key」），否则写入会报错。
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
            -- 引擎用空字符串表示「这一层没有 key」，放行空字符串会让第 2/3 层的空 key
            -- 退化成对父级赋值（把父表整个覆盖掉），因此统一拒绝（见文件头注释）。
            if key == '' then
                error('存档的key不能是空字符串')
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

    --某个具体路径当前是不是一张表（整表替换时判断「要不要先建 / 换一张表」）。
    --与 is_table_level 的区别：这里用的是完整的 key1/key2/key3，第 3 层也能问。
    ---@param key1 any
    ---@param key2 any
    ---@param key3 any
    ---@return boolean
    local function current_is_table(key1, key2, key3)
        if is_pending_table(key1, key2, key3) or is_created_in_this_stage(key1, key2, key3) then
            return true
        end
        if is_deleted(key1, key2, key3) then
            return false
        end
        return type(read_native_value(key1, key2, key3)) == 'table'
    end

    ---与 ECA 的路径语义对齐：写嵌套字段前，父级必须是表。
    ---父级在原生已是表、或本会话刚建 / 暂存队列里即将建成表时放行；父级缺失或不是表时
    ---直接报错（引擎自己也会拒绝这种写入并返回 errcode 4，这里提前拦是为了当场抛出并给出
    ---准确路径）。删除分支不做这个校验，直接交给引擎：父表缺失 / 不是表时同样按 errcode 4
    ---报错。这是有意的——删除一个不存在的路径按用法错误处理（ECA 侧是 no-op，两边刻意不同）。
    ---父表只是还没落盘时不算「缺失」：删除会先排空暂存写入（见 `parent_chain_not_native`），
    ---所以刚建好的表在被删除子字段前会先落盘，不会误报 errcode 4。
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

    --删除前，父级链上是否还有「原生还不是表」的层。写入侧遇到这种父级会延期，删除侧
    --不做延期，因此删除要先把这个槽位的暂存写入排空，父表才真正落盘、引擎才不会按
    --errcode 4 拒绝。这里和 `check_parent_table` 的差别是只看原生，不看暂存队列。
    ---@param key1 any
    ---@param key2 any
    ---@param key3 any
    ---@return boolean
    local function parent_chain_not_native(key1, key2, key3)
        if key2 == nil or key2 == '' then
            --顶层字段没有父级
            return false
        end
        if type(read_native_value(key1, '', '')) ~= 'table' then
            return true
        end
        if key3 ~= nil and key3 ~= '' then
            return type(read_native_value(key1, key2, '')) ~= 'table'
        end
        return false
    end

    local set_value

    --`M.auto` 打开时，把写入路径上缺失 / 不是表的层补成表，保证这次写入落地。
    --关闭时什么都不做，交给下面的 `check_parent_table` 按旧行为报错。
    --只有「路径当参数传」的写入才可能走到需要补建的场景：Lua 的点写 `data.a.b = x` 在 a
    --缺失 / 不是表时由 Lua 语法本身拦下，代理根本接不到。
    ---@param key1 any
    ---@param key2 any
    ---@param key3 any
    local function ensure_auto_parents(key1, key2, key3)
        if not M.auto then
            return
        end
        if key2 ~= nil and key2 ~= '' then
            if not is_table_level(key1, '') or is_deleted(key1, '', '') then
                local old = read_native_value(key1, '', '')
                if old ~= nil and type(old) ~= 'table' then
                    log.warn(('存档路径的父字段不是表，已按 y3.save_data.auto 换成表：%s'):format(tostring(key1)))
                end
                set_value(key1, {}, {})
            end
        end
        if key3 ~= nil and key3 ~= '' then
            if not is_table_level(key1, key2) or is_deleted(key1, key2, '') then
                local old = read_native_value(key1, key2, '')
                if old ~= nil and type(old) ~= 'table' then
                    log.warn(('存档路径的父字段不是表，已按 y3.save_data.auto 换成表：%s')
                        :format(keys_text({ key1, key2 })))
                end
                set_value(key2, {}, { key1 })
            end
        end
    end

    set_value = function(key, value, path)
        local key1, key2, key3 = unpack_path(key, path)
        if value == nil then
            remove_pending_writes(key1, key2, key3)
            unmark_pending_table(key1, key2, key3)
            unmark_created(key1, key2, key3)
            mark_deleted(key1, key2, key3)
            --父表可能只是「本会话刚建 / 还在暂存队列里」，此时必须先让它落盘：引擎对
            --非表父级返回 errcode 4，而写入侧对同一种情况是延期（不报错）。排空后父表
            --若因写入失败仍未落盘，这里照旧按 errcode 4 报错，与「父表确实不存在」同义。
            if parent_chain_not_native(key1, key2, key3) then
                flush_pending_writes(true)
            end
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
        ensure_auto_parents(key1, key2, key3)
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
            -- 引擎用空字符串表示「这一层没有 key」，放行空字符串会让第 2/3 层的空 key
            -- 退化成对父级赋值（把父表整个覆盖掉），因此统一拒绝（见文件头注释）。
            if key == '' then
                error('存档的key不能是空字符串')
            end
            -- 原生接口只有 key1/key2/key3，第 4 层字段无法表示：
            -- 若继续放行，写入会被截断到第 3 层（覆盖父表），删除会连带删掉整个子树。
            if path and #path >= 3 then
                error('存档表最多只支持3层嵌套')
            end
            value = y3.helper.as_lua(value)
            local vtype = type(value)
            if vtype == 'table' then
                -- 非空表 = 把这个键位所在的子树整体替换成它（空表只是把这个键位写成空表）。
                -- 必须先物化：代理自带 [CONFIG]/[CUSTOM] 哨兵键、平台构建的视图表字段藏在
                -- __pairs 后面，不解包就会把一张有内容的表误判成空表。
                local target = M.to_plain_table(value)
                if next(target) == nil then
                    set_value(key, {}, path)
                    -- 快照里保留调用方给的那张表本身（普通表 `to_plain_table` 原样返回），
                    -- 与旧行为一致：之后直接改这张表，代理是看不到的。
                    raw[key] = target
                    return
                end
                local key1, key2, key3 = unpack_path(key, path)
                local node_path = append_path(path, key)
                if #node_path >= 3 then
                    -- 第 3 层再放一张有内容的表就要用到第 4 层了。
                    error(('存档表最多只支持3层嵌套：%s'):format(keys_text(node_path)))
                end
                -- 先整张校验再写：任何一处非法都在写之前抛出，不会只写进去一半。
                validate_save_table(target, 1, 3 - #node_path, keys_text(node_path))
                local node_raw = raw[key]
                if current_is_table(key1, key2, key3) then
                    if type(node_raw) ~= 'table' then
                        node_raw = read_native_value(key1, key2, key3)
                        if type(node_raw) ~= 'table' then
                            node_raw = {}
                        end
                    end
                else
                    -- 不存在 / 不是表 / 已被删除：先写一张空表把它建出来（1 次原生写入）。
                    set_value(key, {}, path)
                    node_raw = {}
                end
                -- 整表替换：多出来的键删掉，目标表里的键按代理写入（嵌套表会递归走回这里）。
                raw[key] = node_raw
                local node = create_proxy(node_raw, node_path)
                for k in pairs(node) do
                    if target[k] == nil then
                        node[k] = nil
                    end
                end
                for k, v in pairs(target) do
                    -- 值没变就不写：表交给代理递归做 diff，标量直接比一次。
                    if type(v) == 'table' or node[k] ~= v then
                        node[k] = v
                    end
                end
                return
            end
            if vtype ~= 'nil'
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

---把一张表整体写入存档：这张表就是该子树的最终内容（key 在前、值在最后）。
---
---    y3.save_data.set_table(player, slot, t)                   -- 整个槽位根
---    y3.save_data.set_table(player, slot, key1, t)
---    y3.save_data.set_table(player, slot, key1, key2, t)
---
---未出现在表里的键（任意层）都会被删除；空表表示该键位变成一个空表（在根上就是清空整个槽位）。
---传入表最多 `3 - 路径层数` 层，超出报错；键与值的规则和表存档一致。
---写入前会先把整张表校验一遍，任何一处非法都整体报错、一个字段都不写。
---与现值相同的字段不会产生原生写入。
---
---等价写法：`y3.save_data.load_table(player, slot)[key1][key2] = t`。
---（注意 key 是**路径**，缺失的层是否自动补建取决于 `y3.save_data.auto`。）
---@param player Player
---@param slot integer
---@param ... string|integer|table 0~2 层路径 key，最后一个是该子树的最终内容
function M.set_table(player, slot, ...)
    local count = select('#', ...)
    if count == 0 then
        error('缺少要写入的表：set_table(player, slot, [key1, [key2, ]]t)')
    end
    local t = select(count, ...)
    if type(t) ~= 'table' then
        error('存档的值只能是基础类型')
    end
    local keys = {}
    for i = 1, count - 1 do
        keys[i] = select(i, ...)
        check_key(keys[i])
    end
    if #keys > 2 then
        error('存档路径最多两层 key：set_table(player, slot, key1, key2, t)')
    end
    local data = M.load_table(player, slot)
    local target = M.to_plain_table(t)
    if #keys == 0 then
        validate_save_table(target, 1, 3, '<存档根>')
        -- 根上只能逐键增删：字段级接口要求 key1 非空（引擎对 key1 == '' 直接报
        -- invalid save table key1），而整表写入接口（set_save_data_table_value）只允许
        -- 覆盖模式的槽位使用，禁止覆盖槽位会当场抛错。所以根清空就是逐个删除顶层字段。
        for k in pairs(data) do
            if target[k] == nil then
                data[k] = nil
            end
        end
        for k, v in pairs(target) do
            -- 值没变就不写：表交给代理递归做 diff，标量直接比一次。
            if type(v) == 'table' or data[k] ~= v then
                data[k] = v
            end
        end
        return
    end
    local parent, key, err = M.resolve_write_parent(data, keys)
    if not parent then
        error(err)
    end
    parent[key] = target
end

---按路径写一个字段（与 ECA 的「写入存档字段」节点对应），值可以是标量或一张表（key 在前、值在最后）。
---
---    y3.save_data.set_field(player, slot, key1, value)
---    y3.save_data.set_field(player, slot, key1, key2, value)
---    y3.save_data.set_field(player, slot, key1, key2, key3, value)
---
---值是表时等价于 `y3.save_data.set_table(player, slot, key1, key2, value)`；值填 `nil` 等于删除。
---路径上缺失 / 不是表的父级是否自动补建，取决于 `y3.save_data.auto`。
---@param player Player
---@param slot integer
---@param ... any 1~3 层路径 key（只能是字符串或整数），最后一个是值
function M.set_field(player, slot, ...)
    local count = select('#', ...)
    if count < 2 then
        error('缺少存档路径的 key：set_field(player, slot, key1, value)')
    end
    if count > 4 then
        error('存档路径最多三层 key：set_field(player, slot, key1, key2, key3, value)')
    end
    local keys = {}
    for i = 1, count - 1 do
        keys[i] = select(i, ...)
        check_key(keys[i])
    end
    local value = select(count, ...)
    local data = M.load_table(player, slot)
    local parent, key, err = M.resolve_write_parent(data, keys)
    if not parent then
        error(err)
    end
    parent[key] = value
end

return M
