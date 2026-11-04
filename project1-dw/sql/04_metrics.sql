-- ============================================================
-- 04 Day 2：4 个业务指标（直接在 DWD 上算，先跑通再谈分层）
-- 顺序：GMV → DAU → 次日留存 → 复购率 → 转化漏斗
-- 每段都能单独选中执行（Ctrl+Enter）
--
-- 说明：这是练习环境，金额直接用 dim_item.price。
--       真实生产里必须用「下单时的价格快照」，否则商品改价会让历史 GMV 跟着变。
-- ============================================================

USE shop;


-- ---------- 指标1：GMV（按天）----------------
-- 口径：当天所有「支付」行为对应的商品金额之和
SELECT dt,
       ROUND(SUM(i.price), 2) AS gmv,
       COUNT(*)               AS pay_cnt
FROM dwd_user_behavior b
JOIN dim_item i ON i.item_id = b.item_id
WHERE b.behavior = 'pay'
GROUP BY dt
ORDER BY dt;


-- ---------- 指标2：DAU（日活，按天去重用户数）----------------
SELECT dt,
       COUNT(DISTINCT user_id) AS dau,
       COUNT(*)                AS pv
FROM dwd_user_behavior
GROUP BY dt
ORDER BY dt;


-- ---------- 指标3：次日留存率 ----------------
-- 口径：某天来过的人里，第二天还来的比例
-- 最后一天没有「第二天」，所以要排除，否则会被算成 0
WITH daily AS (
    SELECT DISTINCT dt, user_id
    FROM dwd_user_behavior
)
SELECT a.dt,
       COUNT(DISTINCT a.user_id) AS dau,
       COUNT(DISTINCT b.user_id) AS next_day_alive,
       ROUND(COUNT(DISTINCT b.user_id) * 100.0 / COUNT(DISTINCT a.user_id), 2) AS retention_pct
FROM daily a
LEFT JOIN daily b
       ON b.user_id = a.user_id
      AND b.dt = a.dt + INTERVAL 1 DAY
WHERE a.dt < (SELECT MAX(dt) FROM dwd_user_behavior)
GROUP BY a.dt
ORDER BY a.dt;


-- ---------- 指标4：复购率 ----------------
-- 口径：支付过的用户里，支付 ≥2 次的人占多少
SELECT COUNT(*)                                              AS pay_users,
       SUM(CASE WHEN cnt >= 2 THEN 1 ELSE 0 END)             AS repeat_users,
       ROUND(SUM(CASE WHEN cnt >= 2 THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS repurchase_pct
FROM (
    SELECT user_id, COUNT(*) AS cnt
    FROM dwd_user_behavior
    WHERE behavior = 'pay'
    GROUP BY user_id
) t;


-- ---------- 指标5：转化漏斗（浏览 → 加购 → 下单 → 支付）----------------
SELECT behavior,
       COUNT(*)                AS cnt,
       COUNT(DISTINCT user_id) AS users
FROM dwd_user_behavior
GROUP BY behavior
ORDER BY FIELD(behavior, 'view', 'cart', 'order', 'pay');


-- ---------- 附加：按小时看行为分布（为后面分时调度做准备）----------------
SELECT hh,
       COUNT(*)                                           AS cnt,
       SUM(behavior = 'view')                             AS view_cnt,
       SUM(behavior = 'pay')                              AS pay_cnt
FROM dwd_user_behavior
GROUP BY hh
ORDER BY hh;
