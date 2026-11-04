# Git 与 GitHub 上手（第一次推送全流程）

> 目标：把 `data-eng-lab` 推到 GitHub，让别人能点开看你的代码。
> 全程大约 20 分钟，卡住的地方在最后一节「常见报错」。

---

## 0. 两个前提，先说清楚

**① 只在 `data-eng-lab` 里 init，不要在工作区根目录 init。**

`D:\Ti\learn\dsworkplace` 下面还有 `BossHunter`、`resume_work` 这些目录，里面有配置文件和个人信息。如果从根目录 `git init`，`git add .` 会把它们全提交上去。

正确位置：

```
D:\Ti\learn\dsworkplace\data-eng-lab    ← 只在这里 git init
```

**② 提交前先看一眼 `git status`，确认没有 `.venv`、没有密码、没有 pdf。**

`.gitignore` 已经写好了，但你第一次用，值得亲眼确认一遍。

---

## 1. 配置身份（只做一次）

Git 要知道"这次提交是谁干的"：

```bash
git config --global user.name "Peng Shilin"
git config --global user.email "你的GitHub邮箱"
git config --global core.quotepath false   # 让中文文件名正常显示，不转成 \344\275...
```

验证：

```bash
git config --global --list
```

> `user.email` 建议用 GitHub 账号的主邮箱，这样 GitHub 上的提交才会关联到你头像，否则显示成一个灰色小人。

---

## 2. 在 GitHub 上建空仓库

1. 打开 https://github.com/new
2. Repository name：`data-eng-lab`
3. 可见性：**Public**（简历上用得到；实在不想公开就先 Private，投简历时再改）
4. **不要勾** "Add a README file"、不要勾 .gitignore、不要选 license
5. 点 Create repository

建完会看到一个空仓库页面，上面写着 `git remote add origin ...`。**记住这个地址**，下一步要用。

---

## 3. 本地初始化 + 第一次提交

在 `data-eng-lab` 目录下打开终端（PowerShell 或 Git Bash 都行）：

```bash
cd D:\Ti\learn\dsworkplace\data-eng-lab

git init                      # 初始化，会多出一个隐藏的 .git 目录
git status                    # 看一眼：应该只有 sql/ python/ docs/ README.md .gitignore
```

`git status` 里如果出现了 `.venv/`，说明 `.gitignore` 没生效，**先别 add**，停下来检查。

确认没问题后：

```bash
git add .                     # 把当前所有改动放进"暂存区"
git status                    # 再确认一次：现在应该是绿色的 "Changes to be committed"
git commit -m "feat: 电商用户行为离线数仓 Day1-3（建表/造数/清洗/汇总/EXPLAIN）"
```

---

## 4. 关联远程仓库并推送

```bash
git remote add origin https://github.com/你的用户名/data-eng-lab.git
git branch -M main            # 把默认分支改名为 main（GitHub 的约定）
git push -u origin main
```

第一次 push 会弹出浏览器，让你登录 GitHub 授权。**用 HTTPS 就是为了这一步**——Git for Windows 自带凭据管理器，登一次以后就不用再管。

授权完回到终端，看到类似这样的输出就成功了：

```
To https://github.com/你的用户名/data-eng-lab.git
 * [new branch]      main -> main
branch 'main' set up to track 'origin/main'.
```

---

## 5. 验证

1. 刷新 GitHub 仓库页面，应该能看到 `README.md`、`sql/`、`python/`、`docs/`
2. 点进 `project1-dw/sql/03_dwd_build.sql`，确认代码能正常显示（中文不乱码）
3. 看提交记录，你的头像应该出现在提交旁边

---

## 6. 以后每天的固定三步

```bash
git add .
git commit -m "feat: 完成 Day4 GitHub 推送"   # 说清楚改了什么
git push
```

第二行是重点。`commit -m "update"` 这种提交信息，三个月后你自己都看不懂。规范写法见第 8 节。

---

## 7. 常见报错

| 报错 | 原因 | 解决 |
| --- | --- | --- |
| `fatal: not a git repository` | 不在仓库目录里，或忘了 `git init` | `cd` 到 `data-eng-lab`，再 `git init` |
| `error: remote origin already exists` | 已经加过 origin | `git remote set-url origin <新地址>` |
| `error: failed to push some refs ... rejected` | 远程仓库里已经有东西（比如建仓库时勾了 README） | `git pull --rebase origin main` 再 `git push` |
| `Permission denied (publickey)` | 用了 SSH 地址（`git@github.com:`）但没配密钥 | 把地址改成 `https://github.com/...` |
| `Authentication failed` / `403` | 凭据过期或密码错 | Windows 设置 → 凭据管理器 → 删除 github 相关条目，重新 push |
| 中文文件名显示成一串数字 | `core.quotepath` 默认开着 | `git config --global core.quotepath false` |

---

## 8. 提交信息写法

```
<类型>: <一句话说清做了什么>
```

| 类型 | 用在哪 |
| --- | --- |
| `feat` | 新功能、新表、新脚本 |
| `fix` | 修 bug |
| `docs` | 只改文档/README |
| `refactor` | 重写但不改功能 |
| `chore` | 环境、依赖、配置 |

好例子：

- `feat: 新增 dws_trade_daily 日汇总表`
- `fix: 修复次日留存把最后一天算进去的问题`
- `docs: 补 README 中的数据字典`

坏例子：`update`、`修改`、`123`。

---

## 9. 之后进阶（现在不用看）

- **分支**：`git switch -c dev` 开分支改，改完合回 main
- **Pull Request**：团队协作的标准流程，自己一个人练也可以走一遍
- **SSH 免密**：配好 `ssh-keygen` + `ssh-agent` 后，push 不用弹浏览器
- **GitHub Actions**：每次 push 自动跑测试/检查

先把这一周跑顺，这些后面再说。
