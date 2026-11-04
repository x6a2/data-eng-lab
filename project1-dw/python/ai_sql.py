"""自然语言查数：一句中文 -> 一条 SQL -> 跑出结果 -> 模型解释。

这是整个项目里唯一"跟 AI 有关"的代码，也是简历上"用 AI 辅助开发"能被追问的部分。

用法（PowerShell，在 data-eng-lab 目录下）：

    $env:DEEPSEEK_API_KEY = "sk-..."          # 只对当前窗口生效，不要写进文件
    $env:SHOP_DB_PASSWORD = "你的 MySQL 密码"
    .venv\\Scripts\\python.exe project1-dw\\python\\ai_sql.py "上个月每个品类的支付金额和订单数"

    # 只看它生成的 SQL、不执行（调提示词的时候很有用）：
    .venv\\Scripts\\python.exe project1-dw\\python\\ai_sql.py "..." --dry-run

它由六个零件组成，注释里标了 ①-⑥，对着代码看一遍就懂：

    ① 表结构说明（SCHEMA_TEXT）—— 决定模型能不能写对的关键
    ② 提示词（SYSTEM_PROMPT）—— 你要求它怎么想、怎么输出
    ③ 调 API（ask_llm）—— 就是一次 HTTP POST
    ④ 取 SQL（extract_sql）—— 从 ```sql 代码块里抠出来
    ⑤ 安全检查（guard）—— 只允许 SELECT，防止模型写出 DELETE
    ⑥ 执行 + 解释（run_sql / ask_llm 第二次）

刻意没做的事：不重试、不流式、不做多轮记忆。先跑通，再谈工程。
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

import pymysql

# ---------------------------------------------------------------------------
# ① 表结构说明：这一段就是模型的"数据库字典"。
#    写得越清楚，它瞎编字段的概率越低。
#    TODO(你)：跑完下面这条查询，把真实字段补全、补准。
#      SELECT table_name, column_name, column_type, column_comment
#      FROM information_schema.columns
#      WHERE table_schema='shop' ORDER BY table_name, ordinal_position;
# ---------------------------------------------------------------------------
SCHEMA_TEXT = """
库名：shop（MySQL 8.0）

dim_user(用户维表)
  user_id     BIGINT   用户 ID，主键
  gender      VARCHAR  性别：M/F
  age         INT      年龄
  city        VARCHAR  城市
  register_dt DATE     注册日期

dim_item(商品维表)
  item_id     BIGINT   商品 ID，主键
  item_name   VARCHAR  商品名
  category_id BIGINT   品类 ID
  price       DECIMAL  标价

ods_user_behavior(原始行为表，未清洗)
  id          BIGINT   自增主键
  user_id     BIGINT   用户 ID
  item_id     BIGINT   商品 ID
  category_id BIGINT   品类 ID
  behavior    VARCHAR  行为：view / cart / order / pay
  event_time  DATETIME 行为发生时间
  dt          DATE     分区列（= DATE(event_time)）

dwd_user_behavior(明细层，已去重/去未来时间/去孤儿用户)
  字段与 ods 相同，但没有重复行；统计行为一律用这张表。

dws_trade_daily(交易日汇总，一天一行)
  dt          DATE     日期
  pay_amount  DECIMAL  当日支付金额（GMV）
  order_cnt   INT      当日下单数
  pay_cnt     INT      当日支付数

dws_user_daily(用户日汇总，一天一行)
  dt          DATE
  active_users INT     当日活跃用户数（DAU）

口径约定（很重要，模型不知道就要写进提示词）：
  GMV       = SUM(pay_amount) over dws_trade_daily，或 dwd 里 behavior='pay' 的 item 价合计
  订单数     = dwd 里 behavior='order' 去重后的条数
  用户数     = COUNT(DISTINCT user_id)
  时间范围   = 用 dt 列过滤，不要用 DATE(event_time)，会让索引失效
"""

# ---------------------------------------------------------------------------
# ② 提示词：先给规则，再给表结构，最后给问题。
#    TODO(你)：改坏它、看输出怎么变，这是最值得动手的部分。
# ---------------------------------------------------------------------------
SYSTEM_PROMPT = """你是 MySQL 8.0 的数据分析师。根据用户的自然语言问题，写一条可执行的查询。

规则：
1. 只能写一条 SELECT 或 WITH ... SELECT，禁止 INSERT/UPDATE/DELETE/DROP/ALTER/TRUNCATE。
2. 只用下面给出的表和字段，不要臆造字段名；不确定时用最保守的写法。
3. 时间过滤用 dt 列（DATE 类型），不要对 event_time 套函数。
4. 明细统计用 dwd_user_behavior，日汇总用 dws_* 表；两者不要混用。
5. 默认加 LIMIT 200，除非问题本身是聚合单行结果。
6. 输出格式：先用一两句话说明思路，然后 ```sql 代码块，最后一行写"假设："（如果有口径假设）。

数据库结构：
{schema}
"""


# ---------------------------------------------------------------------------
# ③ 调 API：DeepSeek 兼容 OpenAI 的 /chat/completions，所以就是一次 POST。
# ---------------------------------------------------------------------------
API_URL = "https://api.deepseek.com/chat/completions"
MODEL = "deepseek-chat"


def ask_llm(messages: list[dict], temperature: float = 0.0) -> str:
    """发一次对话请求，返回模型回复的纯文本。"""
    key = os.environ.get("DEEPSEEK_API_KEY")
    if not key:
        sys.exit("缺少环境变量 DEEPSEEK_API_KEY（PowerShell: $env:DEEPSEEK_API_KEY=\"sk-...\"）")

    payload = json.dumps(
        {"model": MODEL, "messages": messages, "temperature": temperature, "stream": False},
        ensure_ascii=False,
    ).encode("utf-8")

    req = urllib.request.Request(
        API_URL,
        data=payload,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:  # 401 Key 错 / 402 余额不足 / 429 限流
        body = exc.read().decode("utf-8", "replace")[:300]
        sys.exit(f"API 返回 {exc.code}：{body}")
    except urllib.error.URLError as exc:  # 网络不通
        sys.exit(f"连不上 API：{exc.reason}")

    return data["choices"][0]["message"]["content"]


# ---------------------------------------------------------------------------
# ④ 取 SQL：模型习惯用 ```sql 包起来，也可能裸输出。
# ---------------------------------------------------------------------------
def extract_sql(text: str) -> str:
    m = re.search(r"```sql\s*(.+?)```", text, re.S | re.I) or re.search(r"```\s*(.+?)```", text, re.S)
    sql = (m.group(1) if m else text).strip()
    return sql.strip().rstrip(";").strip()


# ---------------------------------------------------------------------------
# ⑤ 安全检查：模型是会写出 DELETE 的，这一层不能省。
# ---------------------------------------------------------------------------
FORBIDDEN = re.compile(
    r"\b(insert|update|delete|drop|alter|truncate|create|replace|grant|revoke|load_file|into\s+outfile)\b",
    re.I,
)


def guard(sql: str) -> str:
    """只放行单条 SELECT / WITH 查询，并按需补 LIMIT。"""
    body = sql.strip()
    if ";" in body:
        raise ValueError("检测到多条语句（含分号），拒绝执行")
    if not re.match(r"^\s*(select|with)\b", body, re.I):
        raise ValueError("不是 SELECT / WITH 查询，拒绝执行")
    if FORBIDDEN.search(body):
        raise ValueError(f"包含危险关键字：{FORBIDDEN.search(body).group(0)}")
    if not re.search(r"\blimit\b", body, re.I):
        body += "\nLIMIT 200"
    return body


# ---------------------------------------------------------------------------
# ⑥ 执行 + 打印。注意：这里是只读账号更稳妥，练习阶段用 root 也行。
# ---------------------------------------------------------------------------
def connect():
    pwd = os.environ.get("SHOP_DB_PASSWORD")
    if not pwd:
        sys.exit('缺少环境变量 SHOP_DB_PASSWORD（PowerShell: $env:SHOP_DB_PASSWORD="你的密码"）')
    return pymysql.connect(
        host="127.0.0.1", port=3306, user="root", password=pwd,
        database="shop", charset="utf8mb4", cursorclass=pymysql.cursors.Cursor,
    )


def run_sql(sql: str) -> tuple[list[str], list[tuple], float]:
    t0 = time.perf_counter()
    conn = connect()
    try:
        with conn.cursor() as cur:
            cur.execute(sql)
            cols = [d[0] for d in cur.description] if cur.description else []
            rows = cur.fetchall() if cur.description else []
    finally:
        conn.close()
    return cols, rows, time.perf_counter() - t0


def print_table(cols: list[str], rows: list[tuple], limit: int = 20) -> None:
    if not cols:
        print("（没有结果集）")
        return
    widths = [max(len(str(c)), *(len(str(r[i])) for r in rows[:limit])) if rows else len(str(c))
              for i, c in enumerate(cols)]
    line = " | ".join(str(c).ljust(w) for c, w in zip(cols, widths))
    print(line)
    print("-+-".join("-" * w for w in widths))
    for r in rows[:limit]:
        print(" | ".join(str(v).ljust(w) for v, w in zip(r, widths)))
    if len(rows) > limit:
        print(f"... 共 {len(rows)} 行，只显示前 {limit} 行")


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry_run = "--dry-run" in sys.argv
    if not args:
        sys.exit('用法：python ai_sql.py "上个月每个品类的支付金额和订单数" [--dry-run]')
    question = args[0]

    print(f"问题：{question}\n")
    t0 = time.perf_counter()
    answer = ask_llm([
        {"role": "system", "content": SYSTEM_PROMPT.format(schema=SCHEMA_TEXT)},
        {"role": "user", "content": question},
    ])
    print(f"--- 模型输出（{time.perf_counter() - t0:.1f}s）---\n{answer}\n")

    sql = extract_sql(answer)
    print(f"--- 取出的 SQL ---\n{sql}\n")

    try:
        safe_sql = guard(sql)
    except ValueError as exc:
        sys.exit(f"安全检查未通过：{exc}")

    if dry_run:
        print("（--dry-run：只生成不执行）")
        return

    try:
        cols, rows, cost = run_sql(safe_sql)
    except pymysql.MySQLError as exc:
        sys.exit(f"SQL 执行失败：{exc}")

    print(f"--- 执行结果（{cost * 1000:.0f} ms，{len(rows)} 行）---")
    print_table(cols, rows, limit=20)

    # 第二问：让它解释这条 SQL 在干什么，以及哪里可能算错。
    # 这就是你面试时"AI 写完你怎么把关"的答案素材。
    explain = ask_llm([
        {"role": "system", "content": "你是严格的 SQL 评审。用中文、分点、不超过 150 字。"},
        {"role": "user", "content": (
            f"问题：{question}\nSQL：\n{safe_sql}\n"
            f"结果列：{cols}；前几行：{rows[:3]}\n"
            "请说明：这条 SQL 做了什么、口径上有什么假设、哪种情况下结果会错。"
        )},
    ])
    print("\n--- 自我评审 ---")
    print(explain)


if __name__ == "__main__":
    main()
