# 自然语言转 SQL 原型 · 架构说明

> 代码：`python/ai_sql.py`（269 行，只依赖 `pymysql`）
> 目的：把「一句中文问题」变成「一条能在 shop 库跑出结果的 SQL」，并且**在模型出错时不把数据库搞坏**。
> 定位：**原型**，不是产品。写它是为了搞清楚「LLM 接数据库」这条链路里，哪一步最容易出错。

---

## 1. 为什么做这个

真实的数仓开发里，业务方问「上月各品类 GMV」这类问题，要经过：找开发 → 说口径 → 写 SQL → 对结果。一个熟手 10 分钟，一天问 20 次就是 3 小时。

LLM 能不能接掉前半段？能，但有一个前提：**模型不知道你的表结构，也不知道你的口径**。所以问题不是「怎么调 API」，而是「怎么把数据库的语义塞给它，以及怎么挡住它的错误」。

这就是这个原型的全部内容。

---

## 2. 链路

```
            用户: "每个品类最近一周的支付金额和订单数，按金额降序"
                              │
                              ▼
        ┌─────────────────────────────────────────┐
        │ ① SCHEMA_TEXT   表结构 + 口径约定（文本） │
        │ ② SYSTEM_PROMPT 6 条硬规则               │
        └─────────────────────────────────────────┘
                              │  拼成 messages
                              ▼
                    ③ ask_llm()  ──POST──▶ api.deepseek.com/chat/completions
                              │                    (deepseek-chat, temperature=0)
                              ▼
                        模型输出：思路 + ```sql 代码块 + 假设
                              │
                              ▼
                    ④ extract_sql()  正则抠出 SQL
                              │
                              ▼
                    ⑤ guard()  只读校验 + 补 LIMIT
                              │           ✗ 非 SELECT / 多语句 / 含 DROP → 直接拒绝，不执行
                              ▼
                    ⑥ run_sql()  pymysql 执行，返回 (列名, 行, 耗时)
                              │
                              ▼
                    ⑦ ask_llm() 二次调用：让它自评审这条 SQL
                              │
                              ▼
                    输出：SQL / 结果表 / 模型自述的口径风险
```

---

## 3. 六个零件，各自解决一个问题

| # | 零件 | 解决的问题 | 如果去掉会怎样 |
|---|---|---|---|
| ① | `SCHEMA_TEXT` | 模型不知道表名、字段、口径 | 编字段，`Unknown column 'order_date'` |
| ② | `SYSTEM_PROMPT` | 模型不知道你的偏好（用 dt 不用函数、明细用 dwd） | 写 `DATE(event_time)`，索引失效，全表扫 |
| ③ | `ask_llm` | 调 API | —— |
| ④ | `extract_sql` | 模型输出是「文字 + 代码块」，不是可执行语句 | 把整段解释当 SQL 执行，语法错 |
| ⑤ | `guard` | **模型会写出 DELETE** | 一次误触，数据没了 |
| ⑥ | `run_sql` + 自评审 | 执行，并让它说出自己的假设 | 你只知道数对不对，不知道为什么 |

### ① 表结构为什么用「手写中文」而不是自动读 `information_schema`

试过自动导出，问题是：`information_schema` 只有字段名和类型，没有**业务含义**和**口径**。

比如 `dws_trade_daily.pay_amount` 自动导出就是 `DECIMAL(14,2)`，模型不知道它是 GMV、不知道单位、不知道含不含退款。所以这里手写：

```
dws_trade_daily(交易日汇总，一天一行)
  pay_amount  DECIMAL  当日支付金额（GMV）
口径约定：GMV = SUM(pay_amount) over dws_trade_daily ...
```

**代价**：schema 改了要同步改这段文本，会漂移。
**取舍**：原型阶段，人写的 30 行语义比自动读的 200 行类型定义有用得多。

### ⑤ 为什么只读校验必须自己写，不能指望模型

`guard()` 做四件事：

```python
if ";" in body:                       # 多条语句（SQL 注入 / 模型自作主张）
if not re.match(r"^\s*(select|with)\b", body, re.I):   # 只放行查询
if FORBIDDEN.search(body):            # insert/update/delete/drop/alter/...
if not re.search(r"\blimit\b", body):  # 没写 LIMIT 就补 200
```

模型不是恶意的，但它会**过度帮助**：你问「把重复数据清掉」，它真的会写 `DELETE`。这一层是唯一的安全边界，不能省。

### ⑥ 二次调用（自评审）为什么值

第一次调用只负责「写对」，第二次调用换一个角色：「严格的 SQL 评审」，让它回答三件事——做了什么、口径有什么假设、什么情况下会错。

实测输出（节选）：

> 支付金额用 `item.price` 近似实付，**未扣优惠和退款**；品类取自行为表，未用商品维表；有退款/优惠时金额虚高；维表一对多会放大金额。

这段话的价值：**它把自己不该被信任的地方说出来了**。面试被问「AI 写错了你怎么发现」，这就是答案的第一层。

---

## 4. 一次真实运行（2026-11-05）

**输入**：`每个品类最近一周的支付金额和订单数，按金额降序`

**模型写的 SQL**（2.4 秒）：

```sql
WITH base AS (
  SELECT b.category_id,
         SUM(CASE WHEN b.behavior = 'pay'   THEN i.price ELSE 0 END) AS pay_amount,
         COUNT(DISTINCT CASE WHEN b.behavior = 'order' THEN b.id END) AS order_cnt
  FROM dwd_user_behavior b
  LEFT JOIN dim_item i ON b.item_id = i.item_id
  WHERE b.dt >= (SELECT DATE_SUB(MAX(dt), INTERVAL 6 DAY) FROM dwd_user_behavior)
    AND b.dt <= (SELECT MAX(dt) FROM dwd_user_behavior)
  GROUP BY b.category_id
)
SELECT * FROM base ORDER BY pay_amount DESC LIMIT 200;
```

**结果**：14 个品类，前 3 行

```
category_id | pay_amount | order_cnt
20          | 55108.70   | 119
7           | 53616.10   | 109
12          | 49483.00   | 100
```

**它自己指出的问题**：用 `item.price` 近似实付、品类取自行为表而非商品维表、维表一对多会放大金额。

值得注意的细节：它**主动用了 `dt` 而不是 `DATE(event_time)`**——因为 SYSTEM_PROMPT 第 3 条就是这么要求的。把这条规则删掉再跑，它会改成 `DATE(event_time)`，这就是「提示词决定行为」的最小实验。

---

## 5. 已知局限（写清楚，别人才信）

| 局限 | 后果 | 下一步 |
|---|---|---|
| 不读真实 schema | 表改了要手动同步，容易漂移 | 加一层 `information_schema` 导出 + 人工补注释 |
| 单轮问答 | 追问「按周看呢」要从头来 | 把上一轮 SQL 作为上下文 |
| 无评估集 | 不知道整体准确率，只验证过几个问题 | 攒 30 个问题 + 标准 SQL，算 exact match / 执行一致性 |
| 无缓存 | 同一个问题重复调 API | 问题 → SQL 的缓存 |
| 无多表校验 | 只查语法与安全，不查语义 | 结果与 `dws_*` 对账，差异 > 1% 就标红 |
| 只支持 MySQL | 换 Hive 要改方言 | 方言参数化 |

**最重要的一条**：这个原型从来没有在真实业务库上跑过。它的价值是证明「链路能通、坑在哪」，不是「能上线」。

---

## 6. 面试可讲的三个点

1. **为什么表结构要写进提示词？** —— 模型没有数据库的先验知识，schema 是唯一的接口文档；只给表名必错。
2. **怎么防止 AI 删库？** —— `guard()` 白名单（只放行 SELECT/WITH）+ 黑名单关键字 + 强制 LIMIT；不依赖模型的自觉。
3. **AI 写错了怎么发现？** —— 三层：执行报错回灌、只读校验拦住危险操作、**语义层用已知答案的小样本对账**（dws 汇总 vs 明细手算，差异 >1% 查口径）。

---

## 7. 运行

```powershell
cd D:\Ti\learn\dsworkplace\data-eng-lab
$env:DEEPSEEK_API_KEY = "sk-..."     # 只在当前窗口生效
$env:SHOP_DB_PASSWORD = "你的密码"

.venv\Scripts\python.exe project1-dw\python\ai_sql.py "每个品类最近一周的支付金额和订单数，按金额降序"
.venv\Scripts\python.exe project1-dw\python\ai_sql.py "..." --dry-run   # 只看 SQL 不执行
```

Key 走环境变量，不进代码、不进仓库。
