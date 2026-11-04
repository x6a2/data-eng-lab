-- ============================================================
-- 05 Day 3：DWD → DWS 汇总 + ADS 视图
-- 为什么要汇总：DWD 是明细（10 万行），报表要的是「每天一行」。
-- 让 BI 每次都扫 10 万行算 GMV，既慢又浪费；预聚合到 DWS，查询变成 34 行。
--
-- 执行：全选 → Alt+X（可重复执行）
-- ============================================================

USE shop;


-- ---------- 1. DWS：交易域日汇总 ----------------
CREATE TABLE IF NOT EXISTS dws_trade_daily (
  dt              DATE          NOT NULL COMMENT '日期',
  gmv             DECIMAL(14,2) NOT NULL COMMENT '成交总额',
  pay_cnt         INT           NOT NULL COMMENT '支付笔数',
  pay_users       INT           NOT NULL COMMENT '支付人数',
  avg_order_value DECIMAL(10,2) NOT NULL COMMENT '笔单价 = GMV / 支付笔数',
  avg_user_value  DECIMAL(10,2) NOT NULL COMMENT '客单价 = GMV / 支付人数',
  PRIMARY KEY (dt)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='交易域日汇总';

TRUNCATE TABLE dws_trade_daily;

INSERT INTO dws_trade_daily (dt, gmv, pay_cnt, pay_users, avg_order_value, avg_user_value)
SELECT b.dt,
       ROUND(SUM(i.price), 2)                        AS gmv,
       COUNT(*)                                      AS pay_cnt,
       COUNT(DISTINCT b.user_id)                     AS pay_users,
       ROUND(SUM(i.price) / COUNT(*), 2)             AS avg_order_value,
       ROUND(SUM(i.price) / COUNT(DISTINCT b.user_id), 2) AS avg_user_value
FROM dwd_user_behavior b
JOIN dim_item i ON i.item_id = b.item_id
WHERE b.behavior = 'pay'
GROUP BY b.dt;


-- ---------- 2. DWS：用户域日汇总 ----------------
CREATE TABLE IF NOT EXISTS dws_user_daily (
  dt          DATE         NOT NULL COMMENT '日期',
  pv          INT          NOT NULL COMMENT '行为总条数',
  dau         INT          NOT NULL COMMENT '活跃用户数',
  view_users  INT          NOT NULL COMMENT '浏览人数',
  cart_users  INT          NOT NULL COMMENT '加购人数',
  order_users INT          NOT NULL COMMENT '下单人数',
  pay_users   INT          NOT NULL COMMENT '支付人数',
  cart_rate   DECIMAL(5,2) NOT NULL COMMENT '加购率 = 加购人数 / 日活',
  pay_rate    DECIMAL(5,2) NOT NULL COMMENT '付费率 = 支付人数 / 日活',
  PRIMARY KEY (dt)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='用户域日汇总';

TRUNCATE TABLE dws_user_daily;

INSERT INTO dws_user_daily (dt, pv, dau, view_users, cart_users, order_users, pay_users, cart_rate, pay_rate)
SELECT dt,
       COUNT(*)                                                             AS pv,
       COUNT(DISTINCT user_id)                                              AS dau,
       COUNT(DISTINCT CASE WHEN behavior = 'view'  THEN user_id END)         AS view_users,
       COUNT(DISTINCT CASE WHEN behavior = 'cart'  THEN user_id END)         AS cart_users,
       COUNT(DISTINCT CASE WHEN behavior = 'order' THEN user_id END)         AS order_users,
       COUNT(DISTINCT CASE WHEN behavior = 'pay'   THEN user_id END)         AS pay_users,
       ROUND(COUNT(DISTINCT CASE WHEN behavior = 'cart' THEN user_id END) * 100.0
             / COUNT(DISTINCT user_id), 2)                                   AS cart_rate,
       ROUND(COUNT(DISTINCT CASE WHEN behavior = 'pay' THEN user_id END) * 100.0
             / COUNT(DISTINCT user_id), 2)                                   AS pay_rate
FROM dwd_user_behavior
GROUP BY dt;


-- ---------- 3. ADS：给报表用的视图（不存数据，只是把两张汇总表拼起来）----------------
CREATE OR REPLACE VIEW ads_daily_overview AS
SELECT t.dt,
       t.gmv,
       t.pay_cnt,
       t.pay_users,
       t.avg_order_value,
       u.dau,
       u.pv,
       u.cart_rate,
       u.pay_rate,
       ROUND(t.pay_users * 100.0 / u.dau, 2) AS pay_user_rate
FROM dws_trade_daily t
LEFT JOIN dws_user_daily u ON u.dt = t.dt;


-- ---------- 4. 验收 ----------------
-- 预期：34 行（2026-10-01 到 2026-11-03）
SELECT 'dws_trade_daily' AS t, COUNT(*) AS rows_cnt FROM dws_trade_daily
UNION ALL
SELECT 'dws_user_daily',      COUNT(*) FROM dws_user_daily;

-- 看一眼成品（这就是 BI 报表的数据源）
SELECT * FROM ads_daily_overview ORDER BY dt LIMIT 10;

-- 对比：同样一个问题，明细层要扫多少行，汇总层只扫多少行
SELECT (SELECT COUNT(*) FROM dwd_user_behavior) AS dwd_rows,
       (SELECT COUNT(*) FROM dws_trade_daily)    AS dws_rows;
