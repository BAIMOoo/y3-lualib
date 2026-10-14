# SaveData 存档

`y3.save_data` 是玩家存档的读写接口。可以保存布尔、整数、实数、字符串，以及最多三层的表。
修改后立即生效，不需要手动保存。

## 基础类型

```lua
-- 整数
local level = y3.save_data.load_integer(player, slot)
y3.save_data.save_integer(player, slot, level + 1)

-- 实数
local speed = y3.save_data.load_real(player, slot)
y3.save_data.save_real(player, slot, speed + 0.5)

-- 字符串
local name = y3.save_data.load_string(player, slot)
y3.save_data.save_string(player, slot, 'knight')

-- 布尔
local cleared = y3.save_data.load_boolean(player, slot)
y3.save_data.save_boolean(player, slot, true)
```

数值可以直接累加，不必先读再写：

```lua
y3.save_data.add_integer(player, slot, 10)
y3.save_data.add_real(player, slot, 0.5)
```

槽位里还没有值时，读取会得到该槽位在编辑器「存档设置」里配置的初始值。新增槽位时编辑器会自动分配一个默认初始值，具体值以存档设置里配置的为准，不要假设它一定是 `0`、`""` 或 `false`。

## 表

`y3.save_data.load_table` 返回一张可读写的表，直接改它的字段就会影响玩家存档：

```lua
local data = y3.save_data.load_table(player, slot)

data.level = 5
data.hero = {}
data.hero.name = 'knight'
data.hero.hp = 100

data.hero.hp = nil    -- 赋 nil 即删除该字段
```

要点：

- 一个槽位只需加载一次，之后共用同一张表，随时读写。
- 槽位里还没有值时，表的内容就是编辑器「存档设置」里配置的初始内容。
- 最多三层：`data.a.b.c` 是最深一层。
- key 只能是字符串或整数，且不能是空字符串。
- 值只能是布尔、整数、实数、字符串，或者空表 `{}`。
- 要整体替换一张表时，赋一个空表再重新填字段（`data.hero = {}`）；不要直接赋一张有内容的表。
- 写子字段前父表必须已经存在：先 `data.a = {}`，再写 `data.a.b`；跳过父表直接写 `data.a.b` 会报错。
- 同一帧内对同一张表先清零再写子字段，最终结果与书写顺序一致，不会出现子字段被整体赋值覆盖而丢失。

## 保存时机

不需要调用任何保存或上传接口。字段改动后即写入存档，之后的持久化由引擎在合适时机自动完成（例如游戏结束时），切换关卡前也会先完成写入。

## ECA

存档表在 ECA 里对应四个节点，参数为 玩家、槽位，以及 1~3 层 key：

- 读取存档字段
- 写入存档字段（值填 nil 等于删除）
- 删除存档字段
- 判断字段是否存在

```
写入存档字段(玩家, 槽位, {}, 'a')       -- 建出 a
写入存档字段(玩家, 槽位, {}, 'a', 'b')  -- 建出 a.b
读取存档字段(玩家, 槽位, 'a', 'b')      -- 读取 a.b
```

- 写入或读取一个父表不存在的路径会报错，按上面的方式先建父表。
- 删除一个不存在的路径不做任何事。

## 注意事项

- 不要调用上传 / 保存接口，表存档的改动会自动保存。
- 不要给字段整体赋一张非空表，也不要跳过父表直接写深层字段。
- 表最多三层，第 4 层不可用。
- 使用编辑器默认的存档设置即可（不要开启「允许覆盖」）。
