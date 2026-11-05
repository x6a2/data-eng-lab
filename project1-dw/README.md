# 项目 1：电商用户行为离线数仓（ODS → DWD → DWS → ADS）

> 仓库地址：https://github.com/x6a2/data-eng-lab
> 全部脚本可复现：建表 → 造数 → 清洗 → 指标 → EXPLAIN 优化，按天提交。

目标：从 0 做一条能讲清楚的离线数仓链路，最终产出 4 个业务指标。
技术栈（先用最朴素的，跑通了再加）：MySQL 8.0 + Python 3 + Pandas + Git。

## 背景
（待写：业务场景、数据来源、要回答的问题）

## 架构
（待画：数据流向图）

## 表设计
（待写：分层、字段、分区）

---

## Day 1（2026-11-04）：建库建表 + 造 10 万条数据

**今天只做一件事：把数据弄进 MySQL。** 不做任何清洗、不算任何指标。

### 文件

| 文件 | 作用 |
| --- | --- |
| `sql/01_create_tables.sql` | 建 `shop` 库 + 3 张表（`dim_user` / `dim_item` / `ods_user_behavior`） |
| `python/gen_data.py` | 造数并写入 MySQL（5000 用户 / 2000 商品 / 100570 条行为） |
| `sql/02_day1_check.sql` | 验收查询 + 脏数据体检 + 3 道作业 |

### 怎么跑

```bash
# 1. 建库建表（DBeaver 打开 01_create_tables.sql 全选执行，或用命令行）
mysqlsh --sql -u root -p --file data-eng-lab/project1-dw/sql/01_create_tables.sql

# 2. 造数入库（密码用环境变量传，不要写进代码）
#    PowerShell:
$env:SHOP_DB_PASSWORD="你的密码"
data-eng-lab\.venv\Scripts\python.exe data-eng-lab\project1-dw\python\gen_data.py

# 3. 验收
mysqlsh --sql -u root -p --file data-eng-lab/project1-dw/sql/02_day1_check.sql
```

### 验收标准（数字必须一模一样）

| 检查项 | 预期值 |
| --- | --- |
| `dim_user` 行数 | 5,000 |
| `dim_item` 行数 | 2,000 |
| `ods_user_behavior` 行数 | 100,570 |
| 行为分布 | view 69.9% / cart 15.1% / order 10.0% / pay 5.1% |
| 重复行（多出来的条数） | 300 |
| 未来时间 | 150 |
| 孤儿用户 | 120 |

**为什么是 100,570 而不是 100,000？** 因为 `gen_data.py` 故意掺了 570 条脏数据：

- 300 条**完全重复**的行 → 模拟埋点重复上报
- 150 条**未来时间**（2027 年）→ 模拟客户端时钟错误
- 120 条**孤儿用户**（`user_id` 在 `dim_user` 里不存在）→ 模拟用户被物理删除

这三类脏数据是 Day 2 清洗的对象。真实公司里，它们占的比例只会更高。

### 今天要弄懂的 5 个点

1. **ODS 层为什么不洗数据？** 贴源层的职责是"原样存档"，清洗放在 DWD。数据出问题时才能回溯到原始状态。
2. **`dt` 字段和 `event_time` 有什么区别？** `event_time` 是精确时间，`dt` 是日期冗余字段。按天统计/分区裁剪用 `dt`，比 `DATE(event_time)` 快得多（能用上索引）。
3. **为什么要 `dim_` 前缀？** 维度表（用户、商品）和事实表（行为）分开，是维度建模最基本的区分。
4. **`TRUNCATE` 和 `DELETE` 的区别？** TRUNCATE 不能回滚、不能带 WHERE，但快得多；批量重灌数据时用它。
5. **为什么用 `executemany` 分批写？** 一次性 INSERT 十万行会撑爆内存和 `max_allowed_packet`，5000 条一批是常见做法。

### Day 1 作业（写在 `sql/02_day1_check.sql` 第 6 节下面）

1. 查 2026-10-01 这天，每种 behavior 各多少条
2. 查"加购了但没下单"的用户数（提示：`NOT EXISTS` 或 `LEFT JOIN ... IS NULL`）
3. 查支付金额最高的 5 个商品（`behavior='pay'` 关联 `dim_item.price`）

---

## Day 2（2026-11-05）：ODS → DWD 清洗 + 4 个指标

**今天做两件事**：把 100,570 条脏数据洗成 100,000 条干净明细；在干净数据上算 5 个指标。

### 文件

| 文件 | 作用 |
| --- | --- |
| `sql/03_dwd_build.sql` | 建 `dwd_user_behavior`，用 `INSERT ... SELECT` 完成 4 条清洗规则 |
| `sql/04_metrics.sql` | GMV / DAU / 次日留存 / 复购率 / 转化漏斗 |

### 清洗的 4 条规则

| # | 规则 | 手段 | 洗掉 |
| --- | --- | --- | --- |
| 1 | 同一行为只留一条 | `ROW_NUMBER() OVER (PARTITION BY ... ORDER BY id)` 取 `rn = 1` | 300 |
| 2 | 丢掉未来时间 | `WHERE event_time <= NOW()` | 150 |
| 3 | 丢掉孤儿用户 | `JOIN dim_user`（内连接天然过滤） | 120 |
| 4 | 只留合法行为码 | `WHERE behavior IN ('view','cart','order','pay')` | 0 |

100,570 − 300 − 150 − 120 = **100,000**。

### 验收标准

| 检查项 | 预期值 |
| --- | --- |
| `dwd_user_behavior` 行数 | **100,000** |
| 「清洗后还有脏数据吗」三行 | 全部 **0** |
| 次日留存率 | 60%–75% 之间（模拟数据是随机行为，不会太高） |
| 复购率 | 20%–35% 之间 |

### 今天要弄懂的 5 个点

1. **为什么用 `ROW_NUMBER` 而不是 `DISTINCT`？**
   `DISTINCT` 只能对"整行去重"，一旦你要保留 `id` 这类不参与去重的列就失效了；而且 `DISTINCT` 不告诉你丢的是哪条。`ROW_NUMBER` 保留了全部列，还能按 `id` 决定"留第一条"，可回溯。

2. **内连接为什么能过滤孤儿用户？**
   `JOIN dim_user ON u.user_id = b.user_id` 匹配不上的行直接消失。这比 `WHERE NOT EXISTS (...)` 更快，也更符合"事实表必须能关联到维度"的数仓约定。

3. **为什么要先 `TRUNCATE` 再 `INSERT`？**
   这叫**幂等重跑**。脚本跑两遍结果一样，出错时不用手工清理。真实调度（DolphinScheduler/Airflow）里，每个任务都必须能重跑。

4. **GMV 为什么不能用 `dim_item.price`？**
   练习环境图省事。真实场景商品会改价，用当前价格算历史 GMV 会算错。正确做法是下单时把价格**快照**进订单表。

5. **次日留存为什么排除最后一天？**
   最后一天没有"第二天"的数据，分母有、分子必然为 0，会把整体留存率拉低。这类"窗口边界"问题在指标开发里极其常见。

### Day 2 作业

1. 用 `ROW_NUMBER` 找出重复行里 `id` 最小和最大的各一条，确认保留的是最小的
2. 查"支付过但从未浏览过"的用户数（正常应该是 0，如果不是，说明数据链路有问题）
3. 算"下单 → 支付"的转化率（`pay` 人数 / `order` 人数）
4. 分别在 ODS 和 DWD 上算一次 GMV，比较差多少，想想为什么

## Day 3（2026-11-06）：DWS 汇总 + EXPLAIN 优化

**今天两件事**：把 10 万行明细预聚合成年 34 行报表数据；学会用 `EXPLAIN` 判断一条 SQL 好不好。

### 文件

| 文件 | 作用 |
| --- | --- |
| `sql/05_dws_build.sql` | `dws_trade_daily` + `dws_user_daily` + `ads_daily_overview` 视图 |
| `sql/06_explain_opt.sql` | 4 组 EXPLAIN 实验：函数导致索引失效 / 最左前缀 / 覆盖索引 |

### 为什么要有 DWS

`dwd_user_behavior` 是 10 万行明细，报表要的是"每天一行"。如果 BI 每次刷新都扫 10 万行重算 GMV：

- 慢（每次都要 JOIN 商品表）
- 浪费（同一份结果算了 100 遍）
- 口径不统一（每个人写一遍 SQL，迟早算出两个数）

预聚合到 DWS 后，查询从 10 万行变成 34 行。这就是"用空间换时间"，也是数仓存在的第一理由。

### 验收标准

| 检查项 | 预期值 |
| --- | --- |
| `dws_trade_daily` 行数 | 34 |
| `dws_user_daily` 行数 | 34 |
| `ads_daily_overview` 行数 | 34 |
| 明细层 vs 汇总层行数对比 | 100000 vs 34 |

### EXPLAIN 要记住的三件事

1. **对字段用函数 = 索引报废**。`WHERE DATE(event_time) = '2026-10-15'` 必然全表扫；`WHERE dt = '2026-10-15'` 才能走索引。这就是 ODS 表要冗余一个 `dt` 字段的原因。
2. **联合索引遵守最左前缀**。`(behavior, dt)` 只有在条件里出现 `behavior` 时才有机会命中。
3. **覆盖索引（`Using index`）不用回表**，是最快的形态。查询只取索引里包含的列时自动触发。

### Day 3 作业

1. 把实验 3.2 改成能走索引的写法
2. 给 `dws_trade_daily` 写一条"按支付人数取前 10 天"的查询，看有没有 `Using filesort`
3. 用 `EXPLAIN ANALYZE` 对比实验 4.1 和 4.2 的实际耗时

## Day 4（2026-11-07）：Git + 推上 GitHub

**今天不做数据，只做一件事：让这个仓库出现在你的 GitHub 主页上。**

详细步骤见 [docs/Git与GitHub上手.md](../docs/Git与GitHub上手.md)，这里只列检查清单。

### 检查清单

- [ ] `git config --global user.name` / `user.email` 已设置（邮箱要和 GitHub 账号一致）
- [ ] GitHub 上建好空仓库 `data-eng-lab`（**不要勾** Add a README）
- [ ] 在 `data-eng-lab` 目录里 `git init`（**不是**工作区根目录）
- [ ] `git status` 确认没有 `.venv/`、没有密码文件、没有 `*.pdf`
- [ ] 第一次 commit：`feat: 电商用户行为离线数仓 Day1-3（建表/造数/清洗/汇总/EXPLAIN）`
- [ ] `git remote add origin ...` + `git push -u origin main`
- [ ] 浏览器里能看到代码，提交记录关联到你自己的头像

### 为什么这一步不能省

简历上写「GitHub 仓库」但点进去是空的，比不写更糟——面试官会当场打开看。

反过来，一个能点开的仓库，哪怕代码不复杂，也证明了三件事：你真的动过手、你会用 Git、你愿意把东西公开。

### Day 4 作业

1. 把仓库链接贴到简历「项目经历」的电商数仓那一条后面
2. 在 `project1-dw/README.md` 顶部加一行仓库地址
3. 用 `git log --oneline` 看自己的提交历史

---

## 附加：自然语言转 SQL 原型（2026-11-05）

> 代码 `python/ai_sql.py`　架构说明 `python/ai_sql说明.md`

数仓练通之后，顺手做了一个小原型：**一句中文问题 → 模型生成 SQL → 只读校验 → 执行 → 模型自评审口径风险**。

它跟本项目的其余部分不是一条线（那些是逐层建模），做它的目的是搞清楚「LLM 接数据库」这条链路里哪一步最容易出错：

- 表结构不写进提示词，模型必编字段；
- 不写只读校验，模型会顺手写 `DELETE`；
- 不追问口径，结果「看着对」但算错。

一次实测：问「每个品类最近一周的支付金额和订单数」，模型自己用了 `dt` 分区过滤（而不是 `DATE(event_time)`），跑出 14 个品类，然后自己指出「用 item.price 近似实付、未扣优惠退款」这类风险。

详细设计、局限和面试可讲的三个点都写在 `python/ai_sql说明.md`。
