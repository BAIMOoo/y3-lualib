# SaveData

存档

## load_boolean

```lua
function SaveData.load_boolean(player: Player, slot: integer)
  -> boolean
```

 获取玩家的存档数据（布尔）
## load_integer

```lua
function SaveData.load_integer(player: Player, slot: integer)
  -> integer
```

 获取玩家的存档数据（整数）
## load_real

```lua
function SaveData.load_real(player: Player, slot: integer)
  -> number
```

 获取玩家的存档数据（实数）
## load_string

```lua
function SaveData.load_string(player: Player, slot: integer)
  -> string
```

 获取玩家的存档数据（字符串）
## load_table

```lua
function SaveData.load_table(player: Player, slot: integer, disable_cover: boolean)
  -> table
```

 获取玩家的存档数据（表）

@*param* `disable_cover` — 是否禁用覆盖，必须和存档设置中的一致
## load_table_with_cover_disable

```lua
function SaveData.load_table_with_cover_disable(player: Player, slot: integer)
  -> table
```

## load_table_with_cover_enable

```lua
function SaveData.load_table_with_cover_enable(player: Player, slot: integer)
  -> table
```

## save_boolean

```lua
function SaveData.save_boolean(player: Player, slot: integer, value: boolean)
```

 保存玩家的存档数据（布尔）
## save_integer

```lua
function SaveData.save_integer(player: Player, slot: integer, value: integer)
```

 保存玩家的存档数据（整数）
## save_real

```lua
function SaveData.save_real(player: Player, slot: integer, value: number)
```

 保存玩家的存档数据（实数）
## save_string

```lua
function SaveData.save_string(player: Player, slot: integer, value: string)
```

 保存玩家的存档数据（字符串）
## save_table

```lua
function SaveData.save_table(player: Player, slot: integer, t: table)
```

 保存玩家的存档数据（表），存档设置中必须使用允许覆盖模式
## set_field

```lua
function SaveData.set_field(player: Player, slot: integer, key1: string|integer, ..., value: any)
```

 按路径写一个存档字段（与 ECA 的「写入存档字段」节点对应，但参数顺序相反：这里 key 在前、值在最后）。key 给 1~3 层，值可以是标量或一张表；值填 `nil` 等于删除。路径上缺失 / 不是表的父级是否自动补建取决于 `y3.save_data.auto`。
## set_table

```lua
function SaveData.set_table(player: Player, slot: integer, ..., t: table)
```

 把一张表整体写入存档：这张表就是该子树的最终内容（key 在前、值在最后；key 给 0~2 层，不给就是槽位根）。未出现在表里的键都会被删除；空表表示清空该子树。
## auto

```lua
auto: boolean
```

 路径当参数传的写入（`set_field` / `set_table` 的路径前缀 / ECA 写入节点）在父级缺失或不是表时，是否自动补成表。默认 `false`；打开后换掉已存在的非表值会打一条 `log.warn`。不影响 Lua 的点写 `data.a.b = x`。
## table_cache

```lua
table
```

## timer_map

```lua
{ [Player]: LocalTimer }
```

## upload_save_data

```lua
function SaveData.upload_save_data(player: Player)
```


