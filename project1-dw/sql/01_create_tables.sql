-- ============================================================
-- 01 建库建表：ODS 层（贴源层）+ 维度表
-- 运行方式：在 DBeaver 里连上 MySQL 后，打开本文件，全选执行
-- 可重复执行：建库/建表都带 IF NOT EXISTS，不会报错
-- ============================================================

CREATE DATABASE IF NOT EXISTS shop
  DEFAULT CHARACTER SET utf8mb4
  COLLATE utf8mb4_0900_ai_ci;

USE shop;

-- ---------- 维度表：用户 ----------
CREATE TABLE IF NOT EXISTS dim_user (
  user_id       INT          NOT NULL COMMENT '用户ID',
  register_date DATE         NOT NULL COMMENT '注册日期',
  city          VARCHAR(32)  NOT NULL COMMENT '城市',
  PRIMARY KEY (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='用户维度表';

-- ---------- 维度表：商品 ----------
CREATE TABLE IF NOT EXISTS dim_item (
  item_id     INT           NOT NULL COMMENT '商品ID',
  item_name   VARCHAR(64)   NOT NULL COMMENT '商品名',
  category_id INT           NOT NULL COMMENT '类目ID',
  price       DECIMAL(10,2) NOT NULL COMMENT '单价',
  PRIMARY KEY (item_id),
  KEY idx_category (category_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='商品维度表';

-- ---------- ODS 层：用户行为原始日志 ----------
-- 注意：ODS 层不加任何清洗逻辑，脏数据原样落库，
--       清洗留给 DWD 层做（这是数仓分层的核心约定）
CREATE TABLE IF NOT EXISTS ods_user_behavior (
  id         BIGINT      NOT NULL AUTO_INCREMENT COMMENT '自增主键（仅用于定位行）',
  user_id    INT         NOT NULL COMMENT '用户ID',
  item_id    INT         NOT NULL COMMENT '商品ID',
  behavior   VARCHAR(16) NOT NULL COMMENT '行为：view/cart/order/pay',
  event_time DATETIME    NOT NULL COMMENT '行为发生时间',
  dt         DATE        NOT NULL COMMENT '行为日期（按天裁选用）',
  PRIMARY KEY (id),
  KEY idx_dt (dt),
  KEY idx_user_dt (user_id, dt)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='用户行为ODS表';
