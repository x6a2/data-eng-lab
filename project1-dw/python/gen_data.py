# -*- coding: utf-8 -*-
"""
Day 1：造数 + 入仓
生成 3 张表的数据并写入 MySQL 的 shop 库：
  dim_user            5,000 个用户
  dim_item            2,000 个商品
  ods_user_behavior   100,000 条行为（另外故意掺 3 类脏数据，Day 2 清洗用）

运行：
  .venv\\Scripts\\python.exe project1-dw\\python\\gen_data.py

密码不写进代码（仓库要上 GitHub），从环境变量读，没有就交互式输入：
  set SHOP_DB_PASSWORD=你的密码        # cmd
  $env:SHOP_DB_PASSWORD="你的密码"     # PowerShell
"""
import os
import random
import sys
from datetime import datetime, timedelta

import pymysql

# ---------------- 连接配置 ----------------
DB_HOST = os.environ.get("SHOP_DB_HOST", "127.0.0.1")
DB_PORT = int(os.environ.get("SHOP_DB_PORT", "3306"))
DB_USER = os.environ.get("SHOP_DB_USER", "root")
DB_NAME = "shop"


def get_password():
    """密码优先级：环境变量 > 手动输入。绝不硬编码进代码。"""
    pwd = os.environ.get("SHOP_DB_PASSWORD")
    if pwd:
        return pwd
    import getpass

    return getpass.getpass(f"MySQL {DB_USER}@{DB_HOST} 的密码: ")


# ---------------- 造数参数 ----------------
SEED = 42                 # 固定随机种子，保证每次生成的数据一样（可复现）
N_USER = 5000
N_ITEM = 2000
N_EVENT = 100000
N_DUP = 300               # 脏数据1：完全重复的行
N_FUTURE = 150            # 脏数据2：未来时间（2027 年）
N_ORPHAN = 120            # 脏数据3：user_id 在用户维度表里不存在

START = datetime(2026, 10, 1)     # 行为数据起始日
DAYS = 34                          # 覆盖 2026-10-01 ~ 2026-11-03

CITIES = ["深圳", "广州", "北京", "上海", "杭州", "成都", "武汉", "南京",
          "西安", "长沙", "东莞", "佛山", "苏州", "重庆", "郑州"]

CATEGORIES = ["手机", "笔记本", "耳机", "平板", "家电", "男装", "女装", "鞋靴",
              "美妆", "食品", "生鲜", "母婴", "图书", "运动", "家居", "数码配件",
              "酒水", "宠物", "汽车用品", "办公"]

# 行为分布：浏览 70%、加购 15%、下单 10%、支付 5%
BEHAVIORS = ["view"] * 70 + ["cart"] * 15 + ["order"] * 10 + ["pay"] * 5

# 一天中各小时的活跃权重：白天和晚上各一个高峰
HOUR_WEIGHTS = [1, 1, 1, 1, 1, 2, 3, 5, 7, 8, 9, 10, 10, 9, 8, 7, 7, 8,
                9, 10, 10, 9, 7, 5]

PRICE_POOL = [9.9, 19.9, 29.9, 39.9, 59.0, 79.0, 99.0, 129.0, 159.0, 199.0,
              259.0, 299.0, 399.0, 599.0, 899.0, 1299.0, 1999.0, 2999.0, 4999.0, 6999.0]


def build_users(rng):
    rows = []
    base = datetime(2025, 1, 1)
    for uid in range(1, N_USER + 1):
        reg = base + timedelta(days=rng.randint(0, 660))
        rows.append((uid, reg.date(), rng.choice(CITIES)))
    return rows


def build_items(rng):
    rows = []
    for iid in range(1, N_ITEM + 1):
        cid = rng.randint(1, len(CATEGORIES))
        name = f"{CATEGORIES[cid - 1]}-{iid:04d}"
        price = rng.choice(PRICE_POOL)
        rows.append((iid, name, cid, price))
    return rows


def random_time(rng):
    day = rng.randrange(DAYS)
    hour = rng.choices(range(24), weights=HOUR_WEIGHTS, k=1)[0]
    return START + timedelta(days=day, hours=hour,
                             minutes=rng.randrange(60),
                             seconds=rng.randrange(60))


def build_events(rng):
    rows = []
    for _ in range(N_EVENT):
        uid = rng.randint(1, N_USER)
        iid = rng.randint(1, N_ITEM)
        behavior = rng.choice(BEHAVIORS)
        ts = random_time(rng)
        rows.append((uid, iid, behavior, ts, ts.date()))

    # 脏数据1：完全重复的行为（埋点重复上报）
    for row in rng.sample(rows, N_DUP):
        rows.append(tuple(row))

    # 脏数据2：未来时间（客户端时钟错误）
    for _ in range(N_FUTURE):
        ts = datetime(2027, 3, 1) + timedelta(days=rng.randrange(30),
                                              seconds=rng.randrange(86400))
        rows.append((rng.randint(1, N_USER), rng.randint(1, N_ITEM),
                     rng.choice(BEHAVIORS), ts, ts.date()))

    # 脏数据3：用户 ID 不存在（历史表字段含义变更 / 用户被物理删除）
    for i in range(N_ORPHAN):
        ts = random_time(rng)
        rows.append((900000 + i, rng.randint(1, N_ITEM), rng.choice(BEHAVIORS),
                     ts, ts.date()))

    rng.shuffle(rows)
    return rows


def insert_in_batches(cursor, sql, rows, batch=5000, label=""):
    total = len(rows)
    for i in range(0, total, batch):
        cursor.executemany(sql, rows[i:i + batch])
        done = min(i + batch, total)
        print(f"  {label} {done:,}/{total:,}", flush=True)


def main():
    rng = random.Random(SEED)

    print("1) 造数中 ...")
    users = build_users(rng)
    items = build_items(rng)
    events = build_events(rng)
    print(f"   用户 {len(users):,} 行 / 商品 {len(items):,} 行 / 行为 {len(events):,} 行")

    print("2) 连接 MySQL ...")
    conn = pymysql.connect(host=DB_HOST, port=DB_PORT, user=DB_USER,
                           password=get_password(), database=DB_NAME,
                           charset="utf8mb4", autocommit=False)
    try:
        with conn.cursor() as cur:
            print("3) 清空目标表（可重复执行）...")
            for t in ("ods_user_behavior", "dim_item", "dim_user"):
                cur.execute(f"TRUNCATE TABLE {t}")

            print("4) 写入 dim_user / dim_item ...")
            insert_in_batches(cur, "INSERT INTO dim_user (user_id, register_date, city) VALUES (%s,%s,%s)",
                              users, label="dim_user")
            insert_in_batches(cur, "INSERT INTO dim_item (item_id, item_name, category_id, price) VALUES (%s,%s,%s,%s)",
                              items, label="dim_item")

            print("5) 写入 ods_user_behavior ...")
            insert_in_batches(cur,
                              "INSERT INTO ods_user_behavior (user_id, item_id, behavior, event_time, dt) "
                              "VALUES (%s,%s,%s,%s,%s)",
                              events, label="behavior")
        conn.commit()

        print("6) 校验 ...")
        with conn.cursor() as cur:
            for t in ("dim_user", "dim_item", "ods_user_behavior"):
                cur.execute(f"SELECT COUNT(*) FROM {t}")
                print(f"   {t:22s} {cur.fetchone()[0]:>9,} 行")
            cur.execute("SELECT dt, COUNT(*) c FROM ods_user_behavior GROUP BY dt ORDER BY dt LIMIT 3")
            print("   最早 3 天:", cur.fetchall())
        print("\n完成。Day 1 的目标是「数据进去了」，脏数据 Day 2 再洗。")
    except Exception as e:
        conn.rollback()
        print(f"\n失败，已回滚：{e}", file=sys.stderr)
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()
