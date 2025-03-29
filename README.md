# iptables端口IP访问控制脚本

这是一个用于配置iptables防火墙的脚本，主要功能是限制特定端口只允许指定IP地址访问。

## 功能特点

- 限制指定端口只允许特定IP访问
- 支持同时添加多个允许访问的IP地址
- 支持从文件批量导入IP地址列表
- 内置常用服务的端口预设（SSH、HTTP、HTTPS等）
- 支持清除已设置的规则
- 自动备份现有规则
- 彩色输出，提高可读性
- 多发行版支持（自动适应不同Linux发行版的保存规则方法）

## 使用前提

- 必须以root权限运行
- 系统中已安装iptables
- Linux系统环境

## 使用方法

### 基本用法

```bash
./iptables_port_restrict.sh -p 端口号 -i IP地址
```

### 选项说明

- `-p, --port PORT` : 要限制的端口号
- `-i, --ip IP_ADDRESS` : 允许访问的IP地址（可多次使用此参数添加多个IP）
- `-f, --file FILE` : 从文件读取IP列表（每行一个IP）
- `-s, --service SERVICE` : 预定义服务（如ssh, http, https）
- `-c, --clear` : 清除指定端口的所有限制规则
- `-l, --list` : 列出当前所有iptables规则
- `-h, --help` : 显示帮助信息

### 使用示例

1. 限制SSH端口(22)只允许192.168.1.100访问：
   ```bash
   ./iptables_port_restrict.sh -p 22 -i 192.168.1.100
   ```

2. 使用预定义服务名称：
   ```bash
   ./iptables_port_restrict.sh -s ssh -i 192.168.1.100
   ```

3. 允许多个IP访问HTTP端口：
   ```bash
   ./iptables_port_restrict.sh -p 80 -i 192.168.1.100 -i 10.0.0.5
   ```

4. 从文件导入IP列表：
   ```bash
   ./iptables_port_restrict.sh -p 80 -f allowed_ips.txt
   ```

5. 清除某个端口的限制规则：
   ```bash
   ./iptables_port_restrict.sh -p 22 -c
   ```

6. 查看当前iptables规则：
   ```bash
   ./iptables_port_restrict.sh -l
   ```

## IP列表文件格式

IP列表文件格式为纯文本，每行一个IP地址。支持CIDR格式。例如：

```
192.168.1.100
10.0.0.0/24
# 这是注释，会被忽略
172.16.0.1  # 这是办公室IP
```

## 注意事项

1. 请确保您对iptables有基本了解，错误的防火墙规则可能导致您无法访问系统
2. 脚本会在应用规则前备份当前规则到/tmp目录
3. 在生产环境使用前，建议先在测试环境验证
4. 对于远程服务器，确保您不会锁定自己的访问权限

## 系统要求

- 任何支持iptables的Linux系统
- bash shell
- 管理员权限 
