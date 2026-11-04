-- ============================================================
-- 03 Day 2：ODS → DWD 清洗
-- 把 100,570 条脏数据洗成 100,000 条干净明细
--
-- 执行方式：DBeaver 里选中全部 → Alt+X（执行脚本）
-- 可重复执行：先 TRUNCATE 再 INSERT，跑多少次结果都一样
-- ============================================================

USE shop;

-- ---------- 1. 建 DWD 明细表 ----------------
-- 和 ODS 的区别：字段更规整（类目冗余进来、拆出小时），且只放干净数据
CREATE TABLE IF NOT EXISTS dwd_user_behavior (
  id         BIGINT      NOT NULL COMMENT '沿用 ODS 的 id，方便回溯',
  user_id    INT         NOT NULL COMMENT '用户ID',
  item_id    INT         NOT NULL COMMENT '商品ID',
  category_id INT        NOT NULL COMMENT '类目ID（从 dim_item 冗余进来）',
  behavior   VARCHAR(16) NOT NULL COMMENT 'view/cart/order/pay',
  event_time DATETIME    NOT NULL COMMENT '行为时间',
  dt         DATE        NOT NULL COMMENT '行为日期',
  hh         TINYINT     NOT NULL COMMENT '小时 0-23（做时段分析用）',
  PRIMARY KEY (id),
  KEY idx_dt_user (dt, user_id),
  KEY idx_behavior_dt (behavior, dt)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='用户行为DWD明细（已清洗）';


-- ---------- 2. 清洗并写入 ----------------
TRUNCATE TABLE dwd_user_behavior;

INSERT INTO dwd_user_behavior (id, user_id, item_id, category_id, behavior, event_time, dt, hh)
SELECT t.id, t.user_id, t.item_id, t.category_id, t.behavior, t.event_time, t.dt, HOUR(t.event_time)
FROM (
    SELECT b.id,
           b.user_id,
           b.item_id,
           i.category_id,
           b.behavior,
           b.event_time,
           b.dt,
           ROW_NUMBER() OVER (
               PARTITION BY b.user_id, b.item_id, b.behavior, b.event_time
               ORDER BY b.id
           ) AS rn
    FROM ods_user_behavior b
    JOIN dim_user u ON u.user_id = b.user_id   -- 规则3：丢掉孤儿用户（内连接天然过滤）
    JOIN dim_item i ON i.item_id = b.item_id   -- 顺便把类目带进来
    WHERE b.event_time <= NOW()                -- 规则2：丢掉未来时间
      AND b.behavior IN ('view', 'cart', 'order', 'pay')  -- 规则4：只留合法行为码
) t
WHERE t.rn = 1;                                -- 规则1：同一行为只留第一条


-- ---------- 3. 验收：清洗掉了多少、留下了多少 ----------------
-- 预期：ods 100570 / dwd 100000 / 洗掉 570
SELECT 'ODS 原始'   AS layer, COUNT(*) AS rows_cnt FROM ods_user_behavior
UNION ALL
SELECT 'DWD 清洗后',          COUNT(*) FROM dwd_user_behavior;


-- ---------- 4. 逐条规则验证（每条应该正好等于预期数字）----------------
SELECT '规则1 重复行' AS rule, COUNT(*) - COUNT(DISTINCT user_id, item_id, behavior, event_time) AS removed
FROM ods_user_behavior
UNION ALL
SELECT '规则2 未来时间', COUNT(*) FROM ods_user_behavior WHERE event_time > NOW()
UNION ALL
SELECT '规则3 孤儿用户', COUNT(*)
FROM ods_user_behavior b LEFT JOIN dim_user u ON u.user_id = b.user_id
WHERE u.user_id IS NULL;


-- ---------- 5. 清洗后应该查不出脏数据（三行都必须是 0）----------------
SELECT 'DWD 里还有重复吗' AS check_item, COUNT(*) - COUNT(DISTINCT user_id, item_id, behavior, event_time) AS bad
FROM dwd_user_behavior
UNION ALL
SELECT 'DWD 里还有未来时间吗', COUNT(*) FROM dwd_user_behavior WHERE event_time > NOW()
UNION ALL
SELECT 'DWD 里还有孤儿用户吗', COUNT(*)
FROM dwd_user_behavior b LEFT JOIN dim_user u ON u.user_id = b.user_id
WHERE u.user_id IS NULL;
