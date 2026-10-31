# BluedHush 5.19 — 原版源码还原工程

从 `BluedHush_5.19.dylib`（2,555,072 B，arm64，MH_DYLIB，无 category、无 Swift）
**纯静态**逆向出的可编译 Theos 工程。未运行、未加载、未改字节。

## 一、还原规模（全部实测，非估算）

| 维度 | 数量 | 来源 |
|---|---|---|
| Objective-C 类 | **76** | `__objc_classlist`（0x260 = 76×8） |
| 实例方法 | **917** | class_ro_t.baseMethods（relative method list） |
| 类方法 | **98** | metaclass → class_ro_t.baseMethods |
| 方法合计 | **1015** | 与 `docs/ORIGINAL-REVERSE.md` 记录完全一致 |
| 实例变量 | **336** | `__objc_ivar` + baseIvars |
| 属性 | **291** | baseProperties（含 readonly/ivar 映射） |
| 协议 | **20** | `__objc_protolist` |
| 外部导入 | **423** | chained fixups imports（imports_format=1） |
| stub | **224** | `__stubs`（逐条 12B，全部解到唯一 import） |
| 定义符号 | **630** | `LC_SYMTAB`（1054 条中已定义部分） |
| CFString | **5276** | `__cfstring`（UTF-16 内联 + 长度字段） |
| CJK 字符串 | **6103** | `__cstring` + `__ustring` + `__cfstring` |
| **Hook 点** | **309 组 / 107 个宿主类** | 557 处 `bl _MSHookMessageEx` 调用点回溯 |

## 二、目录

```
Headers/            76 个 .h —— @interface，ivar / property / 方法声明全量
Classes/            76 个 .m —— @implementation，每个方法带：
                       · 恢复的调用序列（objc_msgSend 还原为 [recv sel:arg]）
                       · 原始 ARM64 反汇编（逐条，带 stub 名）
                       · 保证可编译的返回占位
asm/                76 个 .asm —— 每类完整反汇编归档
Functions/          C 函数（630 个定义符号）反汇编归档
Hooks/
  ├─ Hooks.generated.xm   309 组 %hook，按宿主类分组，%orig 透传
  └─ hooks.tsv            机器可读表：class / selector / 调用点 / 替换实现 / old 槽
Makefile / control / BluedHushRE.plist
```

## 三、还原精度分级

| 内容 | 精度 |
|---|---|
| 类名、继承、协议、ivar（名/类型/偏移）、属性（名/类型/属性串） | **精确**（元数据直读） |
| 方法签名（选择器、返回/参数类型、类方法 vs 实例方法） | **精确**（type encoding 解析） |
| 方法入口地址、方法体长度、完整指令流 | **精确** |
| 方法内调用序列、字符串常量、类引用、selector | **高置信**（寄存器数据流还原） |
| 局部变量名、控制流结构（if/for/while） | **未还原**（无反编译器，仅指令级） |
| 函数签名（630 个 C 符号） | **仅符号名**（无 DWARF，无 type encoding） |

> 本工程是"结构完整 + 调用序列级"的还原，不是逐字节等价的源码。
> `Classes/*.m` 的方法体保留全部证据（注释）与编译占位实现；补语义时按注释逐条实装即可。

## 四、编译

```bash
export THEOS=~/theos
cd BluedHush-Original-RE
make clean && make package
```

产物 `packages/com.hush.bluedhush.re_5.19.0_iphoneos-arm.deb`，注入 `com.danlan.xiaolan`。

CI 方式见仓库根 `.github/workflows/build.yml`（macos-14 + Theos）。

## 五、已知差异

1. `- (void).cxx_destruct` / `.cxx_construct` 不生成（编译器自行合成）。
2. `hash` / `superclass` / `description` / `debugDescription` 属性跳过（与 NSObject 冲突）。
3. property 对应的 getter/setter 不再重复声明，由 `@property` 合成。
4. Hook 层方法参数统一为 `id`，返回统一 `id`（宿主侧无 type encoding；`%orig` 透传保证 ABI 安全）。
5. 22 处 hook 调用点的 selector 未能还原（x1 跨基本块传递，未做跨块合并）。

详见 `REVERSE-NOTES.md`。
