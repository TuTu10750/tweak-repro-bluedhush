# 逆向技术笔记

## 全程工具链

无 rizin / otool / objdump / IDA / Ghidra(Mach-O)。全部自研：

- `_rev/macho.py` —— 纯 stdlib Mach-O 读取器：段/节、`LC_SYMTAB`、
  `LC_DYLD_CHAINED_FIXUPS`、chained pointer 解码、ObjC 元数据（class_t / class_ro_t /
  method_list_t / ivar_list_t / property_list_t / protocol_list_t）、`__stubs` 还原。
- `_rev/enc.py` —— Objective-C type encoding 解析器 → C/ObjC 声明。
- `_rev/disasm.py` —— capstone 5.0.7 ARM64 反汇编 + 寄存器数据流还原。
- `_rev/dump_all.py` / `gen_src.py` / `gen_hooks.py` —— 元数据落盘与源码生成。

## 关键坑（都踩过并修正）

1. **PTR_64 系列 next 步进是 4 字节**，不是 8（`_STRIDE` 表）。
2. **`page_start == 0` 是合法链头**，只有 `0xFFFF` 才是 START_NONE。
   误把 0 当"无链"会让 `__objc_data` 整段解不出来。
3. **最终放弃 chain 表**，直接按 raw 值解码：
   - rebase：`target = raw & 0xFFFFFFFFF`（36-bit vm offset）
   - bind：`ordinal = raw & 0xFFFFFF`，`addend = (raw>>24) & 0xFF`（有符号 8 位）
   - `__TEXT` 段内的指针（如 `__objc_methlist`）是**已定值绝对 vmaddr**，直接返回 raw
4. **chained import 的 name_offset 是 `v >> 9`**（`lib:8 / weak:1 / name:23`）。
   写成 `v & 0x7F` 会让 224 个 stub 全部解析成同一个符号。
5. **small method list 的 nameOffset 指向 selref 槽**，必须二次解引用才拿到选择器字符串。
   三个 int32 字段各自相对**自己**的地址（name 槽 +0 / types 槽 +4 / imp 槽 +8）。
6. **类方法在 metaclass 里**：`class_t.isa` → metaclass 的 `data` → `ro.baseMethods`。
   不解析 metaclass 会少 98 个类方法。
7. **`adr x2, #imm`（不是 adrp+add）**用于传 hook 替换函数地址；漏了这一条 hook 表一个都提不出来。
8. **`objc_getClass("X")` 的类名要靠 x0 的字符串常量回推**，且必须在 bl 之后的
   寄存器清空里保留这个捕获值，否则会被通用的 `('call', base)` 覆盖。

## Hook 表提取方法

1. 定位 `bl` 目标 → `__stubs` → import `_MSHookMessageEx`（唯一一个，stub @0x1a7614）。
2. 全 `__text` 扫描出 **557** 个调用点。
3. 按"最近函数入口"分组（`0x43350` 一组 82 个、`0xa3510` 34 个、`0xbc890` 28 个…）。
4. 每组从函数入口全量模拟（不因 `ret` 提前截断），在 `bl MSHookMessageEx` 处快照
   `x0..x3`：
   - `x0` = Class（`objc_getClass` 捕获 / `__objc_classrefs` 解引用）
   - `x1` = SEL（`__objc_selrefs` 解引用）
   - `x2` = 替换实现（`adr` 直接给地址）
   - `x3` = `&old_xxx`（`__DATA` 槽）
5. 去重后 **309 组 (class, selector) / 107 个宿主类**。

宿主类命名可从类名反推产品结构：`GJIM*`（IM 内核）、`BDChat*`（聊天 UI）、
`BDHome*`（动态/相册）、`BDStalk*` / `HushStalk*`（访问足迹）、`HushLoc*`（定位）、
`HushGal*`（聊天库备份）、`HushLicense*`（激活码）。
