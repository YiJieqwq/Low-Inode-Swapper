# Low Inode Swapper

在已 root 的 Android 设备上，通过批量创建/删除目录推动文件系统 inode 分配器回绕，将 `/data/local/tmp` 的 inode 号压低到 10000 以内。

## 原理

ext4/f2fs 的 inode 分配器按顺序递增分配，到达上限后回绕到低位。脚本以每批 200 个目录的速度不断 `mkdir` → 检查 inode → `rm`，迫使分配器转子走过整个 inode 空间，最终在低区捕获一个 ≤10000 的目录，替换原 `/data/local/tmp`。

## 适用场景

- Android 设备已 root，`/data` 分区为 ext4 或 f2fs
- 用于过某些检测 `/data/local/tmp` inode 号的环境检查，如春秋检测Suspicious suroundings(b)检测项

## 使用方法

直接 以ROOT权限运行 即可

脚本会自动完成：
1. 环境检查（root、目录存在、可写）
2. 探测文件系统总 inode 数
3. 批量轮询搜索低 inode 目录
4. 原子替换 + 权限/属主/SELinux 恢复
5. 询问是否重启

## 注意事项

- 必须 root 权限
- 运行期间 `/data/local/` 下会产生临时目录，脚本退出前会自动清理
- 替换完成后建议重启设备
- 如果当前 inode 已经 ≤10000，脚本会直接退出，不做任何操作

## 作者
YiJieqwq异界，基于MIT协议开源
