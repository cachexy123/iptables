# iptables端口访问控制管理脚本

这个脚本可以限制特定端口只能由指定IP地址访问，包括Docker容器映射的端口。

## 功能

- 初始化规则链
- 添加端口访问规则（指定允许访问的IP地址）
- 删除端口访问规则
- 查看当前规则
- 清空所有规则
- Docker容器端口访问控制

## 使用方法

推荐一键使用：
   ```bash
   bash <(curl -s https://raw.githubusercontent.com/cachexy123/iptables/refs/heads/main/iptables.sh)
   ```


## 常见问题

- 脚本需要root权限才能运行
- 规则保存位置：/etc/iptables/rules.v4 或 /etc/iptables.rules
