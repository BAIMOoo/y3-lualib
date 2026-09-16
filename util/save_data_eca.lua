-- 禁止覆盖模式存档的 ECA 操作封装。
--
-- 这些函数统一通过 save_data.load_table 访问代理表，确保 ECA 与 Lua
-- 侧共享缓存、删除标记以及延迟写入队列。
-- key 最多三层（key1/key2/key3），第 4 层字段非法。
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

local function get_target(data, key1, key2, key3, create)
    local target = data
    if key2 ~= nil then
        local child = target[key1]
        if type(child) ~= 'table' then
            if create then
                if child ~= nil then
                    error(('存档路径的父字段不是表：%s'):format(tostring(key1)))
                end
                error(('存档路径的父表不存在：%s'):format(tostring(key1)))
            end
            if child ~= nil then
                error(('存档路径的父字段不是表：%s'):format(tostring(key1)))
            end
            return nil
        end
        target = child
        if key3 ~= nil then
            child = target[key2]
            if type(child) ~= 'table' then
                if create then
                    if child ~= nil then
                        error(('存档路径的父字段不是表：%s.%s'):format(tostring(key1), tostring(key2)))
                    end
                    error(('存档路径的父表不存在：%s.%s'):format(tostring(key1), tostring(key2)))
                end
                if child ~= nil then
                    error(('存档路径的父字段不是表：%s.%s'):format(tostring(key1), tostring(key2)))
                end
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
    return read_field(player, slot, key1, key2, key3) ~= nil
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
