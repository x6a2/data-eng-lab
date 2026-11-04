-- ============================================================
-- 02 Day 1 验收：确认数据真的进去了，并做一次"脏数据体检"
-- 在 DBeaver 里逐段执行（选中一段按 Ctrl+Enter），看结果对不对
-- ============================================================

USE shop;

-- ---------- 1. 三张表各多少行 ----------------
-- 预期：dim_user 5000 / dim_item 2000 / ods_user_behavior 100570
SELECT 'dim_user'          AS table_name, COUNT(*) AS rows_cnt FROM dim_user
UNION ALL
SELECT 'dim_item',                        COUNT(*) FROM dim_item
UNION ALL
SELECT 'ods_user_behavior',               COUNT(*) FROM ods_user_behavior;


-- ---------- 2. 每天的行为量 PV 和活跃用户数 UV ----------------
-- 第一列是日期，第二列是当天行为条数，第三列是当天有多少个不同用户
SELECT dt,
       COUNT(*)               AS pv,
       COUNT(DISTINCT user_id) AS uv
FROM ods_user_behavior
GROUP BY dt
ORDER BY dt
LIMIT 10;


-- ---------- 3. 行为类型分布 ----------------
-- 预期：view 约 70%、cart 15%、order 10%、pay 5%
SELECT behavior,
       COUNT(*) AS cnt,
       ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM ods_user_behavior), 2) AS pct
FROM ods_user_behavior
GROUP BY behavior
ORDER BY cnt DESC;


-- ---------- 4. 脏数据体检（这是 Day 2 要洗掉的东西）----------------
-- 预期三行：重复行 300 / 未来时间 150 / 孤儿用户 120
SELECT '重复行(多出来的条数)' AS issue,
       COALESCE(SUM(cnt - 1), 0) AS cnt
FROM (
    SELECT user_id, item_id, behavior, event_time, COUNT(*) AS cnt
    FROM ods_user_behavior
    GROUP BY user_id, item_id, behavior, event_time
    HAVING COUNT(*) > 1
) t
UNION ALL
SELECT '未来时间', COUNT(*)
FROM ods_user_behavior
WHERE event_time > NOW()
UNION ALL
SELECT '孤儿用户(user_id 不在 dim_user)', COUNT(*)
FROM ods_user_behavior b
LEFT JOIN dim_user u ON b.user_id = u.user_id
WHERE u.user_id IS NULL;


-- ---------- 5. 随便看 5 条长什么样 ----------------
SELECT * FROM ods_user_behavior ORDER BY id LIMIT 5;


-- ---------- 6. 自己动手（Day 1 作业，写在这下面）----------------
-- 6.1 查 2026-10-01 这一天，每种 behavior 各有多少条
-- 6.2 查"加购(cart)但没下单(order)"的用户数，提示：用 NOT EXISTS 或 LEFT JOIN ... IS NULL
-- 6.3 查购买金额最高的 5 个商品（用 ods_user_behavior 里 behavior='pay' 关联 dim_item.price）
