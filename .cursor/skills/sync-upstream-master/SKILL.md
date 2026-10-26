---
name: sync-upstream-master
description: >-
  Reset this ShellCrash fork's master onto upstream juewuy/ShellCrash master,
  replay this fork's extra commits, and push master directly with no pull
  request. Use when the user asks to align, reset, or拉齐 master with upstream,
  reapply this repo's own commits, or sync the fork without opening a PR.
---

# 对齐上游 master 并重放本仓库提交

把 `ericsyj/ShellCrash` 的 `master` 重置到上游 `juewuy/ShellCrash` 的 `master`，再按原来的提交顺序重放本仓库多出来的改动，并直接推送到 `origin/master`。不要开 PR，不要改打包流程。

## 固定约定

- 上游：`https://github.com/juewuy/ShellCrash.git` 的 `master`。抓到 `refs/remotes/upstream/master`，不必长期添加 remote。
- 只动 `master`。没有另说时不要改 `dev` 或其他分支。
- 作者和提交者都是 `ericsyj <97294040+ericsyj@users.noreply.github.com>`。
- 提交说明里不要有 `Co-authored-by`、`Signed-off-by` 或其他合作者。Cursor 的 `commit-msg` 钩子会自动追加 `Co-authored-by`，所以这次流程里的提交必须用 `git -c core.hooksPath=/dev/null`。不要改钩子，也不要改用户的 git 配置。
- 不要修改 `.github/workflows/package.yaml`。打包脚本、它使用的 git 身份、以及 push 后自动 amend，都保持原样。
- 用户调用本 skill 即表示允许用 `--force-with-lease` 重写并推送 `origin/master`。不要用无 lease 的 `--force`。

## 1. 找出本仓库多出来的提交

```bash
git fetch https://github.com/juewuy/ShellCrash.git master:refs/remotes/upstream/master
git fetch origin master
git checkout master
git log --reverse --format='%H%n%an <%ae>%n%s%n%b%n---' upstream/master..master
```

`upstream/master..master` 里的提交就是要重放的额外提交，按从旧到新的顺序处理。这里面通常包括「个性化配置」、TproxyMix，以及本 skill 自己。不要把上游已有的提交再提交一遍。

若这个范围为空，说明没有本仓库独有的提交。此时若 `master` 只是落后于上游，快进推送即可；不要空重置。

合并提交如果只是把上游并进来，不要当作额外改动重放。重置之后上游内容已经在新的 `master` 上。

## 2. 记下每个提交要重放的内容

对每个额外提交 `C`（父提交为 `C^`）：

- 保留原来的标题和正文，删掉 `Co-authored-by` 和 `Signed-off-by`。
- 导出**除发布包以外**的 diff：

```bash
git diff C^ C -- . ':(exclude)ShellCrash.tar.gz' ':(exclude)bin/clashfm.tar.gz'
```

不要把旧的 `ShellCrash.tar.gz` 或 `bin/clashfm.tar.gz` 拣回来。它们是旧基线上的打包结果，直接套用会丢掉上游脚本更新。

把每个 patch 和对应说明先存到临时目录，再重置分支。

## 3. 重置到上游

```bash
git reset --hard upstream/master
```

## 4. 逐个重放

对每个 patch：

1. `git apply`。能用三方合并时再用 `git apply --3way`。
2. 补丁对不上时，保留上游新逻辑，只把本仓库原来的行为补回等价位置。不要为了应用补丁而回退上游修复。`scripts/libs/get_config.sh` 曾经在上游多了一行 `directories.env`，旧补丁因此失败；正确做法是保留该行，再在读完 `ShellCrash.cfg` 之后加回本仓库的配置迁移。
3. 新文件保持原来的可执行位（例如 `tests/tproxy_mix_test.sh` 是 `100755`）。
4. 按下面与 `package.yaml` 相同的方式重打发布包，不要改 workflow 文件：

```bash
rm -rf pack
mkdir pack
cp -rf scripts/* pack/
cp -rf public/*.list pack/
cp -f rules/singbox_providers/singbox_providers.list pack/
cp -f rules/clash_providers/clash_providers.list pack/
cp -f version pack/
(cd pack && tar -czf ../ShellCrash.tar.gz *)
rm -rf pack
cp -f ShellCrash.tar.gz bin/clashfm.tar.gz
```

这个配方不包含上游包里可能有的 `cn_ip.txt` 和 `cn_ipv6.txt`。这是本仓库打包流程的既有结果，不要擅自加回去。

5. 该提交带了或改了测试时，提交前跑一遍。TproxyMix 用 `sh tests/tproxy_mix_test.sh`。失败就先修再提交。
6. 提交。作者和提交者都设成 ericsyj，并绕过会追加合作者的钩子：

```bash
GIT_AUTHOR_NAME='ericsyj' \
GIT_AUTHOR_EMAIL='97294040+ericsyj@users.noreply.github.com' \
GIT_COMMITTER_NAME='ericsyj' \
GIT_COMMITTER_EMAIL='97294040+ericsyj@users.noreply.github.com' \
git -c core.hooksPath=/dev/null commit -m "<原来的说明，且无合作者行>"
```

`.cursor/skills/**` 若出现在额外提交里，按普通文本一起重放，不要漏掉。

## 5. 直接推送 master

先确认 `upstream/master` 是 `HEAD` 的祖先，且 `upstream/master..HEAD` 只有刚重放的提交。

```bash
git fetch origin master
git push --force-with-lease=refs/heads/master:<推送前的 origin/master SHA> origin master
```

不要创建 PR。

## 6. 等打包流程改写最后一次提交

推送到 `master` 会触发 `.github/workflows/package.yaml`。它会重新打包，对最新提交执行 `git commit --amend --no-edit`，再 `git push -f`。

结果是：

- 作者仍是 ericsyj，说明里仍然没有合作者。
- 提交者变成 `github-actions[bot]`。这是打包流程的既有行为，不要改 workflow，也不要再 amend 一次把提交者改回去。
- 通常只有两个 tar 包的字节发生变化。

等 `master` 上的 `package` 工作流结束，然后：

```bash
git fetch origin master
git reset --hard origin/master
```

本地 `HEAD` 必须等于 `origin/master`。

## 完成前检查

- `git merge-base --is-ancestor upstream/master HEAD` 成功。
- `git status` 干净。
- 每个重放提交的作者都是 ericsyj，说明里没有 `Co-authored-by`。
- 没有改 `.github/workflows/package.yaml`。
- 相关测试已通过。
