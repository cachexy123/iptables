#!/bin/bash
#
# iptables端口访问控制脚本
# 用途：限制指定端口只允许特定IP访问
# 作者：Claude
# 日期：$(date +%Y-%m-%d)

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 检查是否以root权限运行
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：此脚本必须以root权限运行${NC}" 
   exit 1
fi

# 显示使用方法
show_usage() {
    echo -e "${BLUE}用法:${NC}"
    echo -e "  $0 [选项]"
    echo -e "\n${BLUE}选项:${NC}"
    echo -e "  -p, --port PORT       ${YELLOW}要限制的端口号${NC}"
    echo -e "  -i, --ip IP_ADDRESS   ${YELLOW}允许访问的IP地址（可多次使用此参数添加多个IP）${NC}"
    echo -e "  -f, --file FILE       ${YELLOW}从文件读取IP列表（每行一个IP）${NC}"
    echo -e "  -s, --service SERVICE ${YELLOW}预定义服务（如ssh,http,https）${NC}"
    echo -e "  -c, --clear           ${YELLOW}清除指定端口的所有限制规则${NC}"
    echo -e "  -l, --list            ${YELLOW}列出当前所有iptables规则${NC}"
    echo -e "  -h, --help            ${YELLOW}显示此帮助信息${NC}"
    echo -e "\n${BLUE}示例:${NC}"
    echo -e "  $0 -p 22 -i 192.168.1.100 -i 10.0.0.5"
    echo -e "  $0 -s ssh -i 192.168.1.100"
    echo -e "  $0 -p 80 -f allowed_ips.txt"
    echo -e "  $0 -p 22 -c"
    echo -e "  $0 -l"
    exit 1
}

# 初始化变量
PORT=""
SERVICE=""
ALLOWED_IPS=()
IP_FILE=""
CLEAR_RULES=false
LIST_RULES=false

# 处理参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--port)
            PORT="$2"
            shift 2
            ;;
        -i|--ip)
            ALLOWED_IPS+=("$2")
            shift 2
            ;;
        -f|--file)
            IP_FILE="$2"
            shift 2
            ;;
        -s|--service)
            SERVICE="$2"
            shift 2
            ;;
        -c|--clear)
            CLEAR_RULES=true
            shift
            ;;
        -l|--list)
            LIST_RULES=true
            shift
            ;;
        -h|--help)
            show_usage
            ;;
        *)
            echo -e "${RED}错误: 未知参数 $1${NC}"
            show_usage
            ;;
    esac
done

# 列出当前规则
if [ "$LIST_RULES" = true ]; then
    echo -e "${BLUE}当前iptables规则:${NC}"
    iptables -L INPUT -n --line-numbers
    exit 0
fi

# 检查参数
if [ "$CLEAR_RULES" = false ] && [ -z "$PORT" ] && [ -z "$SERVICE" ]; then
    echo -e "${RED}错误: 必须指定端口(-p)或服务(-s)${NC}"
    show_usage
fi

# 如果指定了服务，则获取对应的端口
if [ -n "$SERVICE" ]; then
    case $SERVICE in
        ssh)
            PORT=22
            ;;
        http)
            PORT=80
            ;;
        https)
            PORT=443
            ;;
        ftp)
            PORT=21
            ;;
        dns)
            PORT=53
            ;;
        *)
            echo -e "${RED}错误: 不支持的服务 $SERVICE${NC}"
            exit 1
            ;;
    esac
    echo -e "${GREEN}服务 $SERVICE 对应端口 $PORT${NC}"
fi

# 清除指定端口的规则
if [ "$CLEAR_RULES" = true ]; then
    if [ -z "$PORT" ] && [ -z "$SERVICE" ]; then
        echo -e "${RED}错误: 清除规则时必须指定端口(-p)或服务(-s)${NC}"
        show_usage
    fi
    
    echo -e "${YELLOW}正在清除端口 $PORT 的所有限制规则...${NC}"
    
    # 获取并删除与该端口相关的所有规则
    iptables-save | grep "dport $PORT " | while read -r line; do
        rule=$(echo "$line" | sed 's/^-A/-D/')
        iptables $rule 2>/dev/null
    done
    
    echo -e "${GREEN}已清除端口 $PORT 的所有限制规则${NC}"
    iptables -L INPUT -n | grep "$PORT"
    exit 0
fi

# 从文件读取IP
if [ -n "$IP_FILE" ]; then
    if [ ! -f "$IP_FILE" ]; then
        echo -e "${RED}错误: IP文件 $IP_FILE 不存在${NC}"
        exit 1
    fi
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        # 跳过空行和注释
        if [[ -n "$line" && ! "$line" =~ ^[[:space:]]*# ]]; then
            # 提取IP地址部分（如果行中有注释或其他内容）
            ip=$(echo "$line" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?')
            if [[ -n "$ip" ]]; then
                ALLOWED_IPS+=("$ip")
            fi
        fi
    done < "$IP_FILE"
    
    echo -e "${GREEN}已从文件 $IP_FILE 加载 ${#ALLOWED_IPS[@]} 个IP地址${NC}"
fi

# 检查是否提供了IP地址
if [ ${#ALLOWED_IPS[@]} -eq 0 ]; then
    echo -e "${RED}错误: 未提供允许访问的IP地址${NC}"
    show_usage
fi

# 备份当前iptables规则
echo -e "${BLUE}备份当前iptables规则...${NC}"
BACKUP_FILE="/tmp/iptables_backup_$(date +%Y%m%d_%H%M%S).rules"
iptables-save > "$BACKUP_FILE"
echo -e "${GREEN}规则已备份到 $BACKUP_FILE${NC}"

# 检查规则链是否已存在
CHAIN_NAME="PORT_${PORT}_ACCESS"
iptables -L "$CHAIN_NAME" -n >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "${BLUE}创建新的规则链 $CHAIN_NAME...${NC}"
    iptables -N "$CHAIN_NAME"
else
    echo -e "${YELLOW}清空现有规则链 $CHAIN_NAME...${NC}"
    iptables -F "$CHAIN_NAME"
fi

# 添加允许的IP地址到规则链
echo -e "${BLUE}添加允许的IP地址...${NC}"
for ip in "${ALLOWED_IPS[@]}"; do
    echo -e "允许IP: ${YELLOW}$ip${NC} 访问端口: ${YELLOW}$PORT${NC}"
    iptables -A "$CHAIN_NAME" -s "$ip" -p tcp --dport "$PORT" -j ACCEPT
done

# 设置默认拒绝策略
iptables -A "$CHAIN_NAME" -p tcp --dport "$PORT" -j DROP

# 检查是否已存在引用到这个链的规则
iptables -L INPUT -n | grep "$CHAIN_NAME" > /dev/null
if [ $? -ne 0 ]; then
    # 将流量引导到新的规则链
    echo -e "${BLUE}将端口 $PORT 的流量重定向到规则链...${NC}"
    iptables -I INPUT -p tcp --dport "$PORT" -j "$CHAIN_NAME"
else
    echo -e "${YELLOW}已存在到 $CHAIN_NAME 的规则引用，无需添加${NC}"
fi

# 保存规则到配置文件
echo -e "${BLUE}保存iptables规则...${NC}"
case "$(lsb_release -is 2>/dev/null || echo "Unknown")" in
    "Debian"|"Ubuntu")
        netfilter-persistent save
        ;;
    "CentOS"|"RedHat"|"Fedora")
        service iptables save
        ;;
    *)
        echo -e "${YELLOW}无法自动保存规则，尝试手动保存...${NC}"
        if [ -d "/etc/iptables" ]; then
            iptables-save > /etc/iptables/rules.v4
            echo -e "${GREEN}规则已保存到 /etc/iptables/rules.v4${NC}"
        else
            iptables-save > /etc/iptables.rules
            echo -e "${GREEN}规则已保存到 /etc/iptables.rules${NC}"
            echo -e "${YELLOW}注意：您可能需要配置系统在启动时加载这些规则${NC}"
        fi
        ;;
esac

# 显示当前规则
echo -e "\n${BLUE}当前针对端口 $PORT 的iptables规则:${NC}"
iptables -L "$CHAIN_NAME" -n --line-numbers

echo -e "\n${GREEN}✓ 配置完成！${NC}"
echo -e "${YELLOW}现在端口 $PORT 只能被指定的IP地址访问${NC}"
echo -e "${YELLOW}使用 '$0 -p $PORT -c' 命令可清除这些限制${NC}" 
