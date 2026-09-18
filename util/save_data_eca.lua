-- 禁止覆盖模式存档的 ECA 操作封装。
--
-- 这些函数统一通过 save_data.load_table 访问代理表，确保 ECA 与 Lua
-- 侧共享缓存、删除标记以及延迟写入队列。
-- key 最多三层（key1/key2/key3），第 4 层字段非法。
--
-- 路径解析不会创建父表：写入嵌套字段（key2 / key3）时，它的父级必须已经是表。
-- 要新建父表，先写一个空表再写它的子字段（写 {} 是允许的）：
--   写入存档字段(玩家, 槽位, {}, 'a')       -- 建出 a
--   写入存档字段(玩家, 槽位, {}, 'a', 'b')  -- 建出 a.b，前提是 a 已存在
-- 直接写 a.b 而 a 不存在会报错；删除 a.b 而 a 不存在是 no-op（不报错、不建表）。
local save_data = require 'y3.util.save_data'

local M = {}

local function check_key(key, name)
    if type(key) ~= 'string' and math.type(key) ~= 'integer' then
        error(('存档的%s必须是字符串或者整数'):format(name))
    end
end

local function normalize_keys(key1, key2, key3)
    if key1 == nil then
        error('存档的第一个key不能为空')
    end
    check_key(key1, 'key')
    if key2 == nil then
        if key3 ~= nil then
            error('存档路径不能跳过第二层key')
        end
    else
        check_key(key2, 'key')
        if key3 ~= nil then
            check_key(key3, 'key')
        end
    end
    return key1, key2, key3
end

---@param key1 string|integer
---@param key2? string|integer
---@return string
local function path_text(key1, key2)
    if key2 == nil then
        return tostring(key1)
    end
    return ('%s.%s'):format(tostring(key1), tostring(key2))
end

---把路径上的父级字段解析成表。父字段存在但不是表时一律报错（类型错的路径
---属于数据损坏，不是「缺失」）；父字段缺失时按 must_exist 分流：true 报错
---（写入必须有落点），false 返回 nil（删除按 no-op 处理）。
---@param child any 父级字段的当前值
---@param key1 string|integer
---@param key2? string|integer
---@param must_exist boolean
---@return table? parent
local function resolve_parent_table(child, key1, key2, must_exist)
    if type(child) == 'table' then
        return child
    end
    if child ~= nil then
        error(('存档路径的父字段不是表：%s'):format(path_text(key1, key2)))
    end
    if must_exist then
        error(('存档路径的父表不存在：%s'):format(path_text(key1, key2)))
    end
    return nil
end

---解析 ECA 路径的读写目标，返回目标表和最后一层 key。不创建父表：
---key2 / key3 的父级必须是已存在的表，要建父表请先写一个空表（写 {} 是允许的）。
---父表缺失时：must_exist 为 true 报错（写入），为 false 返回 nil（删除 no-op）。
---@param data table 该槽位的顶层代理表
---@param key1 string|integer
---@param key2? string|integer
---@param key3? string|integer
---@param must_exist boolean 父表缺失时是否报错
---@return table? target 目标表；父表缺失且 must_exist 为 false 时是 nil
---@return string|integer? key 目标字段名
local function get_target(data, key1, key2, key3, must_exist)
    local target = data
    if key2 ~= nil then
        local child = resolve_parent_table(target[key1], key1, nil, must_exist)
        if not child then
            return nil
        end
        target = child
        if key3 ~= nil then
            child = resolve_parent_table(target[key2], key1, key2, must_exist)
            if not child then
                return nil
            end
            target = child
            return target, key3
        end
        return target, key2
    end
    return target, key1
end

---@param player Player
---@param slot integer
---@param key1 string|integer
---@param key2? string|integer
---@param key3? string|integer
---@return any
local function read_field(player, slot, key1, key2, key3)
    normalize_keys(key1, key2, key3)
    local data = save_data.load_table(player, slot, true)
    local value = data[key1]
    if key2 ~= nil then
        if type(value) ~= 'table' then
            if value ~= nil then
                error(('存档路径的父字段不是表：%s'):format(tostring(key1)))
            end
            return nil
        end
        value = value[key2]
        if key3 ~= nil then
            if type(value) ~= 'table' then
                if value ~= nil then
                    error(('存档路径的父字段不是表：%s.%s'):format(tostring(key1), tostring(key2)))
                end
                return nil
            end
            value = value[key3]
        end
    end
    return y3.helper.as_lua(value)
end

---@param player Player
---@param slot integer
---@param value any
---@param key1 string|integer
---@param key2? string|integer
---@param key3? string|integer
local function write_field(player, slot, value, key1, key2, key3)
    normalize_keys(key1, key2, key3)
    local data = save_data.load_table(player, slot, true)
    local target, key = get_target(data, key1, key2, key3, true)
    target[key] = value
end

---@param player Player
---@param slot integer
---@param key1 string|integer
---@param key2? string|integer
---@param key3? string|integer
local function delete_field(player, slot, key1, key2, key3)
    normalize_keys(key1, key2, key3)
    local data = save_data.load_table(player, slot, true)
    local target, key = get_target(data, key1, key2, key3, false)
    if target then
        target[key] = nil
    end
end

---@param player Player
---@param slot integer
---@param key1 string|integer
---@param key2? string|integer
---@param key3? string|integer
---@return boolean
local function has_field(player, slot, key1, key2, key3)
    -- 判断存在性只关心结构：「路径不存在」和「父字段不是表」都算不存在。
    -- 不能复用 read_field：读取语义下父字段不是表会抛错（这是合理的），
    -- 但 ECA 条件节点每次判定都刷一条错误日志，且拿不到 false。
    normalize_keys(key1, key2, key3)
    local data = save_data.load_table(player, slot, true)
    local value = data[key1]
    if key2 ~= nil then
        if type(value) ~= 'table' then
            return false
        end
        value = value[key2]
        if key3 ~= nil then
            if type(value) ~= 'table' then
                return false
            end
            value = value[key3]
        end
    end
    -- 与 read_field 的收敛方式保持一致，避免同一个值出现「读为 nil、判断为存在」。
    return y3.helper.as_lua(value) ~= nil
end

local DEFINITIONS = {
    {
        '读取存档字段',
        read_field,
        { {'玩家', 'Player'}, {'槽位', 'integer'}, {'key1', 'any'}, {'key2', 'any?'}, {'key3', 'any?'} },
        { {'值', 'any'} },
    },
    {
        '写入存档字段',
        write_field,
        -- 值允许为 nil；按 Lua 语义，给字段赋 nil 等价于删除字段。
        { {'玩家', 'Player'}, {'槽位', 'integer'}, {'值', 'any?'}, {'key1', 'any'}, {'key2', 'any?'}, {'key3', 'any?'} },
    },
    {
        '删除存档字段',
        delete_field,
        { {'玩家', 'Player'}, {'槽位', 'integer'}, {'key1', 'any'}, {'key2', 'any?'}, {'key3', 'any?'} },
    },
    {
        '判断字段是否存在',
        has_field,
        { {'玩家', 'Player'}, {'槽位', 'integer'}, {'key1', 'any'}, {'key2', 'any?'}, {'key3', 'any?'} },
        { {'存在', 'boolean'} },
    },
}

function M.register()
    if not y3.eca or not y3.eca.def then
        return false
    end
    for _, definition in ipairs(DEFINITIONS) do
        local builder = y3.eca.def(definition[1])
        for _, param in ipairs(definition[3]) do
            builder:with_param(param[1], param[2])
        end
        for _, ret in ipairs(definition[4] or {}) do
            builder:with_return(ret[1], ret[2])
        end
        builder:call(definition[2])
    end
    return true
end

M.register()

return M
