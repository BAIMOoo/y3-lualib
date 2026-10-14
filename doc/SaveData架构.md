# SaveData 存档

`y3.save_data` 是玩家存档的读写接口。可以保存布尔、整数、实数、字符串，以及最多三层的表。
修改后立即生效，不需要手动保存。

## 与旧版本的区别

旧版本的表存档是「直写」实现：赋值后立刻写进存档，不做顺序控制。这一版重写了写入方式。

**结论**：正常使用表存档的图（只读写三层以内的字段、先建父表再写子字段）不用改代码；只有少数越界写法需要调整。

### 没有变化的

- 标量接口：`load/save_boolean`、`load/save_integer`、`load/save_real`、`load/save_string`、`add_integer`、`add_real`。
- 表接口的调用方式：`load_table(player, slot)`、`save_table(player, slot, t)`、`upload_save_data(player)`、`Player:upload_save_data()`。
- 值规则：空表可以作为字段的值；把字段赋 `nil` 就是删除。
- 上传行为：两个版本都不会自动上传，上传接口的用法不变。

### 新版修好的问题

- **丢字段**：旧版「先清空整张表、再写子字段」时，两次写入在同一批次发出，引擎可能乱序，导致刚写的子字段被覆盖；新版让子字段晚一拍再写，顺序有保证。
- **读到旧值**：旧版只从存档读，取值有延迟时可能读不到刚写的值；新版未写进存档时以最新值为准。
- **同一张表挂在两个 key 下**：旧版会串写，新版各自独立。
- **同一槽位混用 `load_table(p, s)` 和 `load_table(p, s, true)`**：旧版误报「覆盖类型不一致」，新版视为同一模式。

### 新增能力

- **一次设置一整张表**：`y3.save_data.set_table(player, slot, [key1, [key2, ]]t)` 把一棵子树整体替换成 `t`（key 在前、值在最后，key 可以不给）；`data.hero = { ... }` 是它的等价写法。
- **按路径写一个值**：`y3.save_data.set_field(player, slot, key1, [key2, [key3, ]]value)`，与 ECA 的「写入存档字段」节点一一对应（注意 ECA 节点的参数顺序是「值在 key 前面」，两者刻意不同）。
- **`y3.save_data.auto`**（默认 `false`）：打开后，按路径写入时路径上缺的层会自动建出来、不是表的层会换成表。
- ECA 的「写入存档字段」节点同样支持：值填一张非空表 = 整树替换。

### 需要注意的写法

| 写法 | 旧版本 | 现在 |
| --- | --- | --- |
| 写第 4 层：`data.a.b.c.x = 1` | 不报错，但实际写到了第 3 层（把 `data.a.b.c` 覆盖成标量），数据是坏的 | 直接报错 |
| 读第 4 层：`data.a.b.c.d` | 返回的不是这个字段，而是第 3 层那张表 | 返回 `nil` |
| key 用空字符串：`data.a[''] = 1` | 不报错，但实际把父表 `data.a` 整个覆盖了 | 直接报错 |
| 给字段赋一张非空表：`data.hero = { name = 'knight' }` | 报错 | 合法：等于把那棵子树整体替换成这张表，多出来的键会被删掉 |
| 深路径缺父表：`set_field(player, slot, 'a', 'b', 1)` | 报错 | 默认仍报错；`y3.save_data.auto = true` 会先把 `a` 建出来 |

第 4 层在旧版是「能读会读错、能写会写错」的半支持状态，新版统一按不支持处理：表最多三层。

### 为什么要改

- 最主要的原因：旧版在「整体替换一张表」和「写它的子字段」混用时，写入顺序得不到保证，可能把刚写好的子字段覆盖掉，表现为部分字段丢失。新版保证写入顺序，从根上避免丢数据。
- 顺带把之前不清晰的边界（超层、空 key）改成当场报错，便于定位。
- 补上 ECA 侧的表存档读写，纯 ECA 作者也能使用多层表存档。

另外，目前新建的存档槽位统一是「禁止覆盖」的表格存档；「允许覆盖」和 `save_table` 的代码仍然保留，是为了让旧地图能继续正常运行，但已不再维护，新项目直接用默认的禁止覆盖即可。

### 迁移自查

- 全局搜 `['']`。
- 搜 4 个 key 的链式访问，形如 `xxx.yyy.zzz.www`。
- 没有这两类写法，表存档代码就不用动。

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
- 值只能是布尔、整数、实数、字符串，或者表（空表 = 该键位变成空表；非空表 = 整树替换，见下一节）。
- 直接赋一张有内容的表就是**整树替换**：`data.hero = { name = 'knight' }` 之后，`hero` 就等于这张表，存档里多出来的键会被删掉（见下一节）。
- 写子字段前父表必须已经存在：先 `data.a = {}`，再写 `data.a.b`；跳过父表直接写 `data.a.b` 会报错（Lua 语法层面也写不出来，`a` 为 `nil` 时取下标直接崩）。
- 同一帧内对同一张表先清零再写子字段，最终结果与书写顺序一致，不会出现子字段被整体赋值覆盖而丢失。

## 一次设置一整张表

除了逐个字段赋值，还可以把一整张表一次写进去：**这张表就是那棵子树的最终内容**，没出现在里面的键（任意层）都会被删掉。

```lua
-- 写整个槽位
y3.save_data.set_table(player, slot, {
    level = 5,
    hero = { name = 'knight', hp = 100 },
})

-- 只写 hero 这棵子树（'hero' 是路径 key，表放最后）
y3.save_data.set_table(player, slot, 'hero', { name = 'knight' })

-- 等价写法
local data = y3.save_data.load_table(player, slot)
data.hero = { name = 'knight' }

-- 只写一个字段（值可以是标量，也可以是表）；值填 nil 等于删除。key 在前、值在最后。
y3.save_data.set_field(player, slot, 'hero', 'hp', 100)
y3.save_data.set_field(player, slot, 'hero', 'name', nil)
```

要点：

- 语义是**替换**不是合并：`set_table(player, slot, { a = 1 })` 之后，槽位里只剩 `a`。想保留其它字段，就把它们一起写进表里。
- 路径 key 全部写在值的前面：`set_table(player, slot, 'a', 'b', t)` 是「把 `a.b` 替换成 `t`」。key 的个数就是参数个数减一，所以 `set_field(player, slot, 'a', 'b', 'c')` 会被理解为「key 是 `a`、`b`，值是 `c`」。
- 传入表最多 `3 - 路径层数` 层；超出、key 非法、值类型非法都会在**写入之前**整体报错，不会只写进去一半。
- 与现值相同的字段不会重复写进存档；目标为空表时，子树是用「写一张空表覆盖」清掉的（一次操作，不会逐键删除）。
- `data.hero = {...}` 之后请重新从 `data` 上取（`data.hero.name`）；替换前就抓在手里的那张子表引用不保证跟着更新。
- 槽位根上没有「整表写入」这个原生操作，所以 `set_table(player, slot, {})` 是逐键清空。

## y3.save_data.auto

默认 `false`。它只影响**路径当参数传**的写入（`set_field`、`set_table` 的路径前缀、ECA 的「写入存档字段」）：

```lua
y3.save_data.auto = true
y3.save_data.set_field(player, slot, 'a', 'b', 'c', 1)   -- a 不存在 → 自动建 a、a.b 再写
```

- 打开后，路径上**缺的层会建出来、不是表的层会换成表**，保证这次写入一定落地；换掉一个已存在的非表值时会打一条 `log.warn`（记录被丢弃的旧值）。
- 关闭时保持旧行为：父级缺失 / 不是表直接报错。
- Lua 的点写 `data.a.b = 1` 不受它影响：`a` 缺失 / 不是表时，Lua 语法本身就报 `attempt to index a nil value`，我们的代码接不到。想「缺了就建」就用上面的 `set_field`。
- 删除（赋 `nil`）也不受影响。

## 保存时机

不需要调用任何保存或上传接口。字段改动后即写入存档，之后的持久化由引擎在合适时机自动完成（例如游戏结束时），切换关卡前也会先完成写入。

## ECA

存档表在 ECA 里对应四个节点，参数为 玩家、槽位，以及 1~3 层 key：

- 读取存档字段
- 写入存档字段（值填 nil 等于删除；值填一张非空表等于整树替换该子树，与 `data.hero = {...}` 同义）
- 删除存档字段
- 判断字段是否存在

```
写入存档字段(玩家, 槽位, {}, 'a')       -- 建出 a
写入存档字段(玩家, 槽位, {}, 'a', 'b')  -- 建出 a.b
读取存档字段(玩家, 槽位, 'a', 'b')      -- 读取 a.b
```

- 写入或读取一个父表不存在的路径会报错，按上面的方式先建父表；`y3.save_data.auto = true` 时写入会自动把缺的层建出来。
- 删除一个不存在的路径不做任何事。
- ECA 节点的参数顺序是「值在 key 前面」（`写入存档字段(玩家, 槽位, 值, key1, ...)`），与 Lua 的 `set_field`（key 在前、值在最后）刻意不同：节点的顺序已经定死并被存量图按位置引用，不能改。

## 注意事项

- 不要调用上传 / 保存接口，字段改动会自动写入存档。
- 赋非空表 = 整树替换，注意没写进表里的键会被删掉；跳过父表直接写深层字段（`data.a.b = 1` 而 `a` 不存在）仍然会报错。
- 表最多三层，第 4 层不可用。
- 使用编辑器默认的存档设置即可（新建槽位统一为「禁止覆盖」）。
