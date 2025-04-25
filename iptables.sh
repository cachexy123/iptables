#!/bin/bash

# iptables端口访问控制管理脚本
# 用于限制特定端口只能由指定IP访问，包括Docker映射的端口

# 检查是否以root权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 请使用root权限运行此脚本"
    exit 1
fi

# 检查docker命令是否存在
check_docker() {
    if ! command -v docker &> /dev/null; then
        echo "警告: docker命令未找到，Docker相关功能将不可用"
        return 1
    fi
    return 0
}

# 常量定义
RULE_CHAIN="PORT_ACCESS_CONTROL"

# 函数: 显示帮助信息
show_help() {
    echo "=================================================="
    echo "          iptables 端口访问控制管理脚本           "
    echo "=================================================="
    echo "使用方法:"
    echo "  1) 初始化规则链"
    echo "  2) 添加端口访问规则"
    echo "  3) 删除端口访问规则"
    echo "  4) 查看当前规则"
    echo "  5) 清空所有规则"
    echo "  6) Docker容器端口限制"
    echo "  0) 退出"
    echo "=================================================="
}

# 函数: 初始化规则链
init_chain() {
    echo "正在初始化规则链..."
    
    # 检查规则链是否已存在，如存在则先清空
    if iptables -L $RULE_CHAIN >/dev/null 2>&1; then
        echo "规则链 $RULE_CHAIN 已存在，正在清空..."
        iptables -F $RULE_CHAIN
    else
        echo "创建新的规则链 $RULE_CHAIN..."
        iptables -N $RULE_CHAIN
    fi
    
    # 检查INPUT链中是否已有引用，如没有则添加
    if ! iptables -C INPUT -j $RULE_CHAIN >/dev/null 2>&1; then
        echo "将 $RULE_CHAIN 链添加到INPUT链..."
        iptables -A INPUT -j $RULE_CHAIN
    fi
    
    # 检查FORWARD链中是否已有引用（对Docker很重要）
    if ! iptables -C FORWARD -j $RULE_CHAIN >/dev/null 2>&1; then
        echo "将 $RULE_CHAIN 链添加到FORWARD链..."
        iptables -A FORWARD -j $RULE_CHAIN
    fi
    
    # 检查是否存在DOCKER-USER链（Docker创建的特殊链）
    if iptables -L DOCKER-USER >/dev/null 2>&1; then
        if ! iptables -C DOCKER-USER -j $RULE_CHAIN >/dev/null 2>&1; then
            echo "将 $RULE_CHAIN 链添加到DOCKER-USER链..."
            iptables -A DOCKER-USER -j $RULE_CHAIN
        fi
    fi
    
    echo "规则链初始化完成!"
}

# 函数: 添加端口访问规则
add_rule() {
    echo "添加端口访问规则"
    echo "-----------------"
    
    # 获取用户输入
    read -p "请输入端口号: " port
    read -p "请输入允许访问的IP地址: " ip_address
    read -p "请选择协议 [tcp/udp/both]: " protocol
    
    # 验证输入
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "错误: 无效的端口号! 端口必须是1-65535之间的数字。"
        return 1
    fi
    
    if ! [[ "$ip_address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "错误: 无效的IP地址格式!"
        return 1
    fi
    
    # 添加规则
    case "$protocol" in
        tcp|TCP)
            # 阻止其他IP访问该端口
            iptables -A $RULE_CHAIN -p tcp --dport $port -j DROP
            # 允许指定IP访问
            iptables -I $RULE_CHAIN -p tcp -s $ip_address --dport $port -j ACCEPT
            echo "已添加规则: 允许 $ip_address 通过TCP协议访问端口 $port"
            ;;
        udp|UDP)
            iptables -A $RULE_CHAIN -p udp --dport $port -j DROP
            iptables -I $RULE_CHAIN -p udp -s $ip_address --dport $port -j ACCEPT
            echo "已添加规则: 允许 $ip_address 通过UDP协议访问端口 $port"
            ;;
        both|BOTH)
            iptables -A $RULE_CHAIN -p tcp --dport $port -j DROP
            iptables -I $RULE_CHAIN -p tcp -s $ip_address --dport $port -j ACCEPT
            iptables -A $RULE_CHAIN -p udp --dport $port -j DROP
            iptables -I $RULE_CHAIN -p udp -s $ip_address --dport $port -j ACCEPT
            echo "已添加规则: 允许 $ip_address 通过TCP和UDP协议访问端口 $port"
            ;;
        *)
            echo "错误: 无效的协议选择! 请选择 tcp, udp 或 both。"
            return 1
            ;;
    esac
    
    echo "规则添加成功!"
    
    # 询问是否保存规则
    read -p "是否保存规则以便系统重启后生效? [y/n]: " save_rules
    if [[ "$save_rules" =~ ^[Yy]$ ]]; then
        if command -v iptables-save >/dev/null 2>&1; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || iptables-save > /etc/iptables.rules
            echo "规则已保存!"
        else
            echo "警告: 无法找到 iptables-save 命令，规则未保存。"
        fi
    fi
}

# 函数: 删除端口访问规则
delete_rule() {
    echo "删除端口访问规则"
    echo "-----------------"
    
    # 显示当前规则
    echo "当前规则列表:"
    iptables -L $RULE_CHAIN --line-numbers
    
    # 获取用户输入
    read -p "请输入要删除的规则编号 (输入'c'取消): " rule_number
    
    if [[ "$rule_number" =~ ^[Cc]$ ]]; then
        echo "取消删除操作。"
        return 0
    fi
    
    if ! [[ "$rule_number" =~ ^[0-9]+$ ]]; then
        echo "错误: 请输入有效的规则编号!"
        return 1
    fi
    
    # 执行删除
    if iptables -D $RULE_CHAIN $rule_number 2>/dev/null; then
        echo "规则 #$rule_number 已成功删除!"
    else
        echo "错误: 无法删除规则 #$rule_number"
        return 1
    fi
    
    # 询问是否保存规则
    read -p "是否保存规则以便系统重启后生效? [y/n]: " save_rules
    if [[ "$save_rules" =~ ^[Yy]$ ]]; then
        if command -v iptables-save >/dev/null 2>&1; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || iptables-save > /etc/iptables.rules
            echo "规则已保存!"
        else
            echo "警告: 无法找到 iptables-save 命令，规则未保存。"
        fi
    fi
}

# 函数: 查看当前规则
view_rules() {
    echo "当前端口访问控制规则"
    echo "--------------------"
    
    if iptables -L $RULE_CHAIN >/dev/null 2>&1; then
        iptables -L $RULE_CHAIN -v --line-numbers
    else
        echo "规则链 $RULE_CHAIN 不存在，请先初始化。"
    fi
    
    echo ""
    read -p "按回车键继续..." dummy
}

# 函数: 清空所有规则
clear_rules() {
    echo "清空所有规则"
    echo "------------"
    
    read -p "警告: 此操作将删除所有端口访问控制规则。确定继续? [y/n]: " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if iptables -L $RULE_CHAIN >/dev/null 2>&1; then
            iptables -F $RULE_CHAIN
            echo "已清空所有规则!"
        else
            echo "规则链 $RULE_CHAIN 不存在，无需清空。"
        fi
        
        # 询问是否保存规则
        read -p "是否保存更改以便系统重启后生效? [y/n]: " save_rules
        if [[ "$save_rules" =~ ^[Yy]$ ]]; then
            if command -v iptables-save >/dev/null 2>&1; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || iptables-save > /etc/iptables.rules
                echo "更改已保存!"
            else
                echo "警告: 无法找到 iptables-save 命令，更改未保存。"
            fi
        fi
    else
        echo "操作已取消。"
    fi
}

# 函数：显示正在运行的Docker容器
list_docker_containers() {
    if ! check_docker; then
        return 1
    fi
    
    echo "正在获取Docker容器列表..."
    echo "--------------------------"
    docker ps --format "ID: {{.ID}}\n名称: {{.Names}}\n镜像: {{.Image}}\n端口: {{.Ports}}\n状态: {{.Status}}\n" | grep -v "^$"
    echo "--------------------------"
}

# 函数：提取Docker容器的端口映射信息
get_container_ports() {
    container_id=$1
    if ! check_docker; then
        return 1
    fi
    
    # 获取端口映射信息
    port_info=$(docker port $container_id 2>/dev/null)
    if [ -z "$port_info" ]; then
        echo "未找到端口映射信息"
        return 1
    fi
    
    echo "$port_info"
}

# 函数：为Docker容器的端口添加访问控制
docker_port_control() {
    echo "Docker容器端口访问控制"
    echo "----------------------"
    
    if ! check_docker; then
        read -p "按回车键继续..." dummy
        return 1
    fi
    
    # 显示容器列表
    list_docker_containers
    
    # 获取用户输入
    read -p "请输入要限制的容器ID (输入'c'取消): " container_id
    
    if [[ "$container_id" =~ ^[Cc]$ ]]; then
        echo "取消操作。"
        return 0
    fi
    
    # 获取容器端口映射
    port_info=$(get_container_ports $container_id)
    if [ $? -ne 0 ]; then
        echo "无法获取容器端口信息或容器没有映射端口。"
        read -p "按回车键继续..." dummy
        return 1
    fi
    
    # 显示端口信息
    echo "容器端口映射信息:"
    echo "$port_info" | nl
    
    # 选择端口
    read -p "请选择要限制访问的端口序号 (输入'a'限制所有端口, 输入'c'取消): " port_selection
    
    if [[ "$port_selection" =~ ^[Cc]$ ]]; then
        echo "取消操作。"
        return 0
    fi
    
    # 获取允许访问的IP
    read -p "请输入允许访问的IP地址: " ip_address
    
    if ! [[ "$ip_address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "错误: 无效的IP地址格式!"
        read -p "按回车键继续..." dummy
        return 1
    fi
    
    # 处理端口限制
    if [[ "$port_selection" =~ ^[Aa]$ ]]; then
        # 限制所有端口
        echo "正在为所有映射端口设置访问控制..."
        
        while IFS= read -r mapping; do
            parse_and_apply_rule "$mapping" "$ip_address"
        done <<< "$port_info"
    else
        # 限制选定的端口
        if ! [[ "$port_selection" =~ ^[0-9]+$ ]]; then
            echo "错误: 无效的端口序号!"
            read -p "按回车键继续..." dummy
            return 1
        fi
        
        # 获取对应的端口映射行
        mapping=$(echo "$port_info" | sed -n "${port_selection}p")
        
        if [ -z "$mapping" ]; then
            echo "错误: 无效的选择!"
            read -p "按回车键继续..." dummy
            return 1
        fi
        
        parse_and_apply_rule "$mapping" "$ip_address"
    fi
    
    echo "Docker容器端口访问规则添加成功!"
    
    # 检查必要的链
    check_and_add_docker_chains
    
    # 询问是否保存规则
    read -p "是否保存规则以便系统重启后生效? [y/n]: " save_rules
    if [[ "$save_rules" =~ ^[Yy]$ ]]; then
        if command -v iptables-save >/dev/null 2>&1; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || iptables-save > /etc/iptables.rules
            echo "规则已保存!"
        else
            echo "警告: 无法找到 iptables-save 命令，规则未保存。"
        fi
    fi
    
    read -p "按回车键继续..." dummy
}

# 函数：检查并添加Docker相关的链
check_and_add_docker_chains() {
    # 检查FORWARD链中是否已有引用
    if ! iptables -C FORWARD -j $RULE_CHAIN >/dev/null 2>&1; then
        echo "将 $RULE_CHAIN 链添加到FORWARD链..."
        iptables -A FORWARD -j $RULE_CHAIN
    fi
    
    # 检查是否存在DOCKER-USER链
    if iptables -L DOCKER-USER >/dev/null 2>&1; then
        if ! iptables -C DOCKER-USER -j $RULE_CHAIN >/dev/null 2>&1; then
            echo "将 $RULE_CHAIN 链添加到DOCKER-USER链..."
            iptables -A DOCKER-USER -j $RULE_CHAIN
        fi
    fi
    
    # 尝试在nat表中添加规则（Docker使用DNAT进行端口映射）
    # 注意：这需要谨慎，可能会影响Docker的正常工作
    echo "检查Docker NAT规则..."
    
    # 添加规则到PREROUTING链（处理流量在进入路由之前）
    if iptables -t nat -L PREROUTING >/dev/null 2>&1; then
        echo "确保NAT规则正确应用..."
        # 这里不直接修改NAT表，而是确保我们的过滤规则能捕获所有流量
    fi
}

# 函数：解析端口映射并应用规则
parse_and_apply_rule() {
    local mapping="$1"
    local ip_address="$2"
    local host_port=""
    local protocol=""
    
    # 提取端口和协议信息 - 直接处理输入，不调用外部命令
    if [[ "$mapping" == *" -> "* ]]; then
        # docker port命令格式: 80/tcp -> 0.0.0.0:20005
        container_port_with_proto=${mapping%% -> *}
        protocol=${container_port_with_proto#*/}
        host_with_port=${mapping##* -> }
        
        # 提取主机端口 - 根据不同格式处理
        if [[ "$host_with_port" == *":"* ]]; then
            # 格式: 0.0.0.0:20005 或 :::20005
            host_port=${host_with_port##*:}
        else
            # 直接是端口号
            host_port=$host_with_port
        fi
    else
        # docker ps格式: 0.0.0.0:20004->80/tcp 或 :::20004->80/tcp
        if [[ "$mapping" == *":"*"->"* ]]; then
            # 有IP和端口
            part_before_arrow=${mapping%%->*}
            host_port=${part_before_arrow##*:}
        elif [[ "$mapping" == *"->"* ]]; then
            # 只有端口
            host_port=${mapping%%->*}
        fi
        
        if [[ "$mapping" == *"/"* ]]; then
            # 提取协议
            protocol=${mapping##*/}
        fi
    fi
    
    # 清理协议字符串 - 只保留字母
    protocol=$(echo "$protocol" | tr -cd 'a-zA-Z')
    
    # 清理端口号 - 只保留数字
    host_port=$(echo "$host_port" | tr -cd '0-9')
    
    # 验证提取的信息
    if [ -n "$host_port" ] && [ -n "$protocol" ]; then
        # 添加iptables规则 - 同时在INPUT和FORWARD链添加
        iptables -A $RULE_CHAIN -p $protocol --dport $host_port -j DROP
        iptables -I $RULE_CHAIN -p $protocol -s $ip_address --dport $host_port -j ACCEPT
        
        echo "已添加规则: 允许 $ip_address 通过${protocol^^}协议访问端口 $host_port"
        
        # 添加Docker特定规则
        if iptables -L DOCKER-USER >/dev/null 2>&1; then
            echo "检查Docker专用规则..."
        fi
        
        return 0
    else
        echo "警告: 无法解析端口映射: $mapping"
        return 1
    fi
}

# 主菜单
while true; do
    clear
    show_help
    read -p "请选择操作 [0-6]: " choice
    
    case $choice in
        0)
            echo "退出程序..."
            exit 0
            ;;
        1)
            init_chain
            ;;
        2)
            add_rule
            ;;
        3)
            delete_rule
            ;;
        4)
            view_rules
            ;;
        5)
            clear_rules
            ;;
        6)
            docker_port_control
            ;;
        *)
            echo "无效的选择，请重试。"
            ;;
    esac
    
    echo ""
    read -p "按回车键继续..." dummy
done 
