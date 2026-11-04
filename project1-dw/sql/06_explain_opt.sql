-- ============================================================
-- 06 Day 3：EXPLAIN 看执行计划 + 索引优化
-- 一句话：先看 MySQL 打算怎么查，再决定要不要建索引。
-- 执行：一段一段选中执行（Ctrl+Enter），每次只看一条查询
-- ============================================================

USE shop;

-- ============================================================
-- 实验 1：对字段用函数，索引直接失效
-- ============================================================

-- 1.1 慢查询：DATE(event_time) 让 MySQL 无法用 idx_dt
EXPLAIN
SELECT COUNT(*) FROM ods_user_behavior
WHERE DATE(event_time) = '2026-10-15';
-- 看 type 列：ALL（全表扫），rows 约等于总行数，key 是 NULL

-- 1.2 改写：直接用 dt 字段比较，能走索引
EXPLAIN
SELECT COUNT(*) FROM ods_user_behavior
WHERE dt = '2026-10-15';
-- 看 type 列：ref，key 是 idx_dt，rows 只有几千


-- ============================================================
-- 实验 2：EXPLAIN ANALYZE 看真实耗时（MySQL 8.0.18+）
-- 这条会真的执行查询，输出里同时有预估和实际
-- ============================================================
EXPLAIN ANALYZE
SELECT COUNT(*) FROM ods_user_behavior WHERE DATE(event_time) = '2026-10-15';

EXPLAIN ANALYZE
SELECT COUNT(*) FROM ods_user_behavior WHERE dt = '2026-10-15';


-- ============================================================
-- 实验 3：联合索引的最左前缀
-- ============================================================

-- 3.1 等值列 behavior 在最左 → 联合索引 (behavior, dt) 可用
--     用 FORCE INDEX 强制走这个索引，排除优化器自己换索引的干扰
EXPLAIN
SELECT COUNT(*) FROM dwd_user_behavior FORCE INDEX (idx_behavior_dt)
WHERE behavior = 'pay' AND dt >= '2026-10-01' AND dt < '2026-11-01';
-- 预期：type=range，key=idx_behavior_dt

-- 3.2 条件里没有 behavior（最左列缺失）→ 同一个索引用不了
EXPLAIN
SELECT COUNT(*) FROM dwd_user_behavior FORCE INDEX (idx_behavior_dt)
WHERE dt >= '2026-10-01' AND dt < '2026-11-01';
-- 预期：type=ALL，MySQL 只能全表扫

-- 3.3 结论：联合索引 (a, b) 只有在条件里用到 a 时才有机会命中；
--     只查 b 就要么全表扫，要么另建一个以 b 开头的索引（这就是建表时 idx_dt_user 存在的原因）


-- ============================================================
-- 实验 4：覆盖索引，连回表都省了
-- ============================================================

-- 4.1 只查索引里有的列 → Extra 出现 Using index（覆盖索引）
EXPLAIN
SELECT dt, COUNT(*) FROM dwd_user_behavior
WHERE dt = '2026-10-15'
GROUP BY dt;

-- 4.2 多查一个 event_time（不在 idx_dt_user 里）→ 需要回表，Extra 变成 Using where
EXPLAIN
SELECT dt, event_time FROM dwd_user_behavior
WHERE dt = '2026-10-15'
LIMIT 10;


-- ============================================================
-- 怎么读 EXPLAIN 的这几列（面试常问）
--   type:   ALL(全表) > index(扫整个索引) > range(范围) > ref(等值) > const(主键/唯一)
--           越靠右越好；出现 ALL 基本就是缺索引
--   key:    实际用了哪个索引；NULL 表示没用上
--   rows:   预估要扫多少行，越小越好
--   Extra:  Using index     → 覆盖索引，性能最好
--           Using where     → 拿到了索引还要回表再过滤
--           Using filesort  → 额外排序，能用索引顺序避免
--           Using temporary → 建了临时表，GROUP BY 没走索引
-- ============================================================


-- ============================================================
-- 作业
-- 1. 把 3.2 改成能走索引的写法（提示：把 behavior 条件补上）
-- 2. 给 dws_trade_daily 造一条"按支付人数排序取前 10 天"的查询，看有没有 filesort
-- 3. 用 EXPLAIN ANALYZE 对比 4.1 和 4.2 的实际耗时，差多少倍
-- ============================================================
