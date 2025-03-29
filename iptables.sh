#!/bin/bash
#
# 交互式iptables端口IP访问控制脚本
# 用途：通过菜单方式管理端口和IP访问限制

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # 无颜色

# 配置文件
CONFIG_DIR="/etc/iptables-manager"
IP_LIST_FILE="$CONFIG_DIR/allowed_ips.conf"
PORT_CONFIG_FILE="$CONFIG_DIR/port_config.conf"

# 检查是否以root权限运行
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误：此脚本必须以root权限运行${NC}" 
        exit 1
    fi
}

# 初始化配置
init_config() {
    if [ ! -d "$CONFIG_DIR" ]; then
        mkdir -p "$CONFIG_DIR"
        echo -e "${GREEN}创建配置目录: $CONFIG_DIR${NC}"
    fi
    
    if [ ! -f "$IP_LIST_FILE" ]; then
        touch "$IP_LIST_FILE"
        echo -e "${GREEN}创建IP列表文件: $IP_LIST_FILE${NC}"
    fi
    
    if [ ! -f "$PORT_CONFIG_FILE" ]; then
        touch "$PORT_CONFIG_FILE"
        echo -e "${GREEN}创建端口配置文件: $PORT_CONFIG_FILE${NC}"
    fi
}

# 备份当前iptables规则
backup_rules() {
    echo -e "${BLUE}备份当前iptables规则...${NC}"
    BACKUP_FILE="$CONFIG_DIR/iptables_backup_$(date +%Y%m%d_%H%M%S).rules"
    iptables-save > "$BACKUP_FILE"
    echo -e "${GREEN}规则已备份到 $BACKUP_FILE${NC}"
}

# 保存iptables规则
save_rules() {
    echo -e "${BLUE}保存iptables规则...${NC}"
    case "$(lsb_release -is 2>/dev/null || echo "Unknown")" in
        "Debian"|"Ubuntu")
            if command -v netfilter-persistent &> /dev/null; then
                netfilter-persistent save
            else
                echo -e "${YELLOW}netfilter-persistent未安装，使用手动保存方法...${NC}"
                iptables-save > /etc/iptables/rules.v4
            fi
            ;;
        "CentOS"|"RedHat"|"Fedora")
            if command -v service &> /dev/null; then
                service iptables save
            else
                echo -e "${YELLOW}service命令不可用，使用手动保存方法...${NC}"
                iptables-save > /etc/sysconfig/iptables
            fi
            ;;
        *)
            echo -e "${YELLOW}无法识别的系统，使用通用保存方法...${NC}"
            if [ -d "/etc/iptables" ]; then
                iptables-save > /etc/iptables/rules.v4
            else
                iptables-save > /etc/iptables.rules
                echo -e "${YELLOW}规则已保存到 /etc/iptables.rules${NC}"
                echo -e "${YELLOW}您可能需要配置系统在启动时加载这些规则${NC}"
            fi
            ;;
    esac
    echo -e "${GREEN}iptables规则已保存${NC}"
}

# 验证IP地址格式
validate_ip() {
    local ip=$1
    local ip_pattern="^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$"
    
    if [[ ! $ip =~ $ip_pattern ]]; then
        return 1
    fi
    
    # 如果没有CIDR，则验证IP地址每段不超过255
    if [[ ! $ip =~ / ]]; then
        IFS='.' read -r -a ip_segments <<< "$ip"
        for segment in "${ip_segments[@]}"; do
            if [[ $segment -gt 255 ]]; then
                return 1
            fi
        done
    else
        # 如果有CIDR，则验证IP部分
        local ip_part=$(echo $ip | cut -d '/' -f 1)
        local cidr=$(echo $ip | cut -d '/' -f 2)
        
        IFS='.' read -r -a ip_segments <<< "$ip_part"
        for segment in "${ip_segments[@]}"; do
            if [[ $segment -gt 255 ]]; then
                return 1
            fi
        done
        
        # 验证CIDR
        if [[ $cidr -gt 32 ]]; then
            return 1
        fi
    fi
    
    return 0
}

# 验证端口号
validate_port() {
    local port=$1
    if [[ ! $port =~ ^[0-9]+$ ]] || [[ $port -lt 1 ]] || [[ $port -gt 65535 ]]; then
        return 1
    fi
    return 0
}

# 端口是否已配置
is_port_configured() {
    local port=$1
    if grep -q "^PORT:$port:" "$PORT_CONFIG_FILE"; then
        return 0
    fi
    return 1
}

# 添加IP到列表
add_ip_to_list() {
    local ip=$1
    local comment=$2
    
    # 检查IP是否已存在
    if grep -q "^$ip:" "$IP_LIST_FILE"; then
        echo -e "${YELLOW}IP $ip 已存在于允许列表中${NC}"
        return 0
    fi
    
    # 添加IP和说明（可选）
    if [[ -n "$comment" ]]; then
        echo "$ip:$comment" >> "$IP_LIST_FILE"
        echo -e "${GREEN}已添加IP: $ip (说明: $comment)${NC}"
    else
        echo "$ip:" >> "$IP_LIST_FILE"
        echo -e "${GREEN}已添加IP: $ip${NC}"
    fi
    sort -u -o "$IP_LIST_FILE" "$IP_LIST_FILE"
}

# 从列表中删除IP
remove_ip_from_list() {
    local ip=$1
    
    # 检查IP是否存在
    if ! grep -q "^$ip:" "$IP_LIST_FILE"; then
        echo -e "${YELLOW}IP $ip 不在允许列表中${NC}"
        return 1
    fi
    
    # 删除IP
    sed -i "/^$ip:/d" "$IP_LIST_FILE"
    echo -e "${GREEN}已从列表中删除IP: $ip${NC}"
    return 0
}

# 列出所有允许的IP
list_allowed_ips() {
    echo -e "${BLUE}允许访问的IP列表:${NC}"
    if [ ! -s "$IP_LIST_FILE" ]; then
        echo -e "${YELLOW}列表为空，没有允许的IP${NC}"
        return
    fi
    
    echo -e "${CYAN}序号  IP地址\t\t说明${NC}"
    echo "------------------------------------------------"
    awk -F':' '{printf "%-5d %-20s %s\n", NR, $1, $2}' "$IP_LIST_FILE"
}

# 配置端口访问限制
configure_port() {
    local port=$1
    local chain_name="PORT_${port}_ACCESS"
    
    # 检查规则链是否已存在
    iptables -L "$chain_name" -n >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${BLUE}创建新的规则链 $chain_name...${NC}"
        iptables -N "$chain_name"
    else
        echo -e "${YELLOW}清空现有规则链 $chain_name...${NC}"
        iptables -F "$chain_name"
    fi
    
    # 从IP列表文件读取IP地址
    echo -e "${BLUE}添加允许的IP地址到端口 $port...${NC}"
    local count=0
    
    while IFS=':' read -r ip comment || [[ -n "$ip" ]]; do
        if [[ -n "$ip" && ! "$ip" =~ ^[[:space:]]*$ ]]; then
            echo -e "允许IP: ${YELLOW}$ip${NC} 访问端口: ${YELLOW}$port${NC}"
            iptables -A "$chain_name" -s "$ip" -p tcp --dport "$port" -j ACCEPT
            count=$((count+1))
        fi
    done < "$IP_LIST_FILE"
    
    if [ $count -eq 0 ]; then
        echo -e "${RED}警告: 没有添加任何IP地址到允许列表！${NC}"
        echo -e "${RED}这将导致所有IP都无法访问端口 $port${NC}"
        echo -ne "${YELLOW}是否继续？这可能导致您被锁定 [y/N]: ${NC}"
        read -r confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo -e "${GREEN}已取消操作${NC}"
            return 1
        fi
    fi
    
    # 设置默认拒绝策略
    iptables -A "$chain_name" -p tcp --dport "$port" -j DROP
    
    # 检查是否已存在引用到这个链的规则
    iptables -L INPUT -n | grep "$chain_name" > /dev/null
    if [ $? -ne 0 ]; then
        # 将流量引导到新的规则链
        echo -e "${BLUE}将端口 $port 的流量重定向到规则链...${NC}"
        iptables -I INPUT -p tcp --dport "$port" -j "$chain_name"
    else
        echo -e "${YELLOW}已存在到 $chain_name 的规则引用，无需添加${NC}"
    fi
    
    # 记录配置信息
    if ! is_port_configured "$port"; then
        echo "PORT:$port:$(date +%Y-%m-%d_%H:%M:%S)" >> "$PORT_CONFIG_FILE"
    fi
    
    echo -e "${GREEN}端口 $port 的访问限制已配置完成，允许 $count 个IP地址访问${NC}"
    return 0
}

# 清除端口访问限制
clear_port_config() {
    local port=$1
    local chain_name="PORT_${port}_ACCESS"
    
    # 检查端口是否已配置
    if ! is_port_configured "$port"; then
        echo -e "${YELLOW}端口 $port 未配置访问限制${NC}"
        return 1
    fi
    
    # 移除对应端口的INPUT规则
    iptables-save | grep "dport $port " | grep "$chain_name" | while read -r line; do
        rule=$(echo "$line" | sed 's/^-A/-D/')
        iptables $rule 2>/dev/null
    done
    
    # 清空并删除链
    iptables -F "$chain_name" 2>/dev/null
    iptables -X "$chain_name" 2>/dev/null
    
    # 从配置文件中移除
    sed -i "/^PORT:$port:/d" "$PORT_CONFIG_FILE"
    
    echo -e "${GREEN}已清除端口 $port 的所有访问限制${NC}"
    return 0
}

# 更新所有端口配置
update_all_ports() {
    echo -e "${BLUE}更新所有已配置端口的访问限制...${NC}"
    
    if [ ! -s "$PORT_CONFIG_FILE" ]; then
        echo -e "${YELLOW}没有已配置的端口${NC}"
        return 0
    fi
    
    local count=0
    while IFS=':' read -r prefix port timestamp; do
        if [[ "$prefix" == "PORT" && -n "$port" ]]; then
            echo -e "${YELLOW}更新端口 $port 的访问配置...${NC}"
            configure_port "$port"
            count=$((count+1))
        fi
    done < "$PORT_CONFIG_FILE"
    
    echo -e "${GREEN}已更新 $count 个端口的访问配置${NC}"
    return 0
}

# 显示当前iptables规则
show_iptables_rules() {
    echo -e "${BLUE}当前iptables规则:${NC}"
    echo -e "${CYAN}INPUT链规则:${NC}"
    iptables -L INPUT -n --line-numbers
    
    # 显示自定义链规则
    echo -e "\n${CYAN}端口访问控制链:${NC}"
    for chain in $(iptables-save | grep "^:PORT_" | cut -d ' ' -f 1 | tr -d ':'); do
        echo -e "\n${YELLOW}$chain:${NC}"
        iptables -L "$chain" -n --line-numbers
    done
}

# 添加单个IP菜单
add_ip_menu() {
    clear
    echo -e "${BLUE}===== 添加允许访问的IP地址 =====${NC}"
    echo
    
    while true; do
        echo -ne "${YELLOW}请输入要添加的IP地址 (或按q返回): ${NC}"
        read -r ip
        
        if [[ "$ip" == "q" || "$ip" == "Q" ]]; then
            return
        fi
        
        if validate_ip "$ip"; then
            echo -ne "${YELLOW}添加说明 (可选): ${NC}"
            read -r comment
            add_ip_to_list "$ip" "$comment"
            
            echo -ne "${YELLOW}是否继续添加IP? [y/N]: ${NC}"
            read -r choice
            if [[ ! "$choice" =~ ^[Yy]$ ]]; then
                break
            fi
        else
            echo -e "${RED}无效的IP地址格式${NC}"
        fi
    done
}

# 批量添加IP菜单
batch_add_ip_menu() {
    clear
    echo -e "${BLUE}===== 批量添加IP地址 =====${NC}"
    echo
    
    echo -e "${YELLOW}请输入IP地址列表文件路径: ${NC}"
    read -r file_path
    
    if [ ! -f "$file_path" ]; then
        echo -e "${RED}错误: 文件不存在${NC}"
        echo -ne "${YELLOW}按任意键返回...${NC}"
        read -n 1
        return
    fi
    
    local count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        # 跳过空行和注释
        if [[ -n "$line" && ! "$line" =~ ^[[:space:]]*# ]]; then
            # 提取IP地址部分
            ip=$(echo "$line" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?')
            comment=$(echo "$line" | sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]{1,2})?[ \t]*//g' | sed 's/^[ \t]*#[ \t]*//g')
            
            if [[ -n "$ip" ]] && validate_ip "$ip"; then
                add_ip_to_list "$ip" "$comment"
                count=$((count+1))
            fi
        fi
    done < "$file_path"
    
    echo -e "${GREEN}已成功导入 $count 个IP地址${NC}"
    echo -ne "${YELLOW}按任意键返回...${NC}"
    read -n 1
}

# 删除IP菜单
remove_ip_menu() {
    while true; do
        clear
        echo -e "${BLUE}===== 删除IP地址 =====${NC}"
        echo
        
        list_allowed_ips
        
        echo
        echo -e "${YELLOW}请选择操作:${NC}"
        echo -e "1) 按序号删除"
        echo -e "2) 按IP地址删除"
        echo -e "q) 返回主菜单"
        echo
        echo -ne "${YELLOW}请选择 [1-2或q]: ${NC}"
        read -r choice
        
        case $choice in
            1)
                echo -ne "${YELLOW}请输入要删除的IP序号: ${NC}"
                read -r num
                if [[ "$num" =~ ^[0-9]+$ ]]; then
                    ip=$(sed -n "${num}p" "$IP_LIST_FILE" | cut -d ':' -f 1)
                    if [[ -n "$ip" ]]; then
                        remove_ip_from_list "$ip"
                        echo -ne "${YELLOW}按任意键继续...${NC}"
                        read -n 1
                    else
                        echo -e "${RED}无效的序号${NC}"
                        echo -ne "${YELLOW}按任意键继续...${NC}"
                        read -n 1
                    fi
                else
                    echo -e "${RED}请输入有效的数字${NC}"
                    echo -ne "${YELLOW}按任意键继续...${NC}"
                    read -n 1
                fi
                ;;
            2)
                echo -ne "${YELLOW}请输入要删除的IP地址: ${NC}"
                read -r ip
                if validate_ip "$ip"; then
                    remove_ip_from_list "$ip"
                else
                    echo -e "${RED}无效的IP地址格式${NC}"
                fi
                echo -ne "${YELLOW}按任意键继续...${NC}"
                read -n 1
                ;;
            q|Q)
                return
                ;;
            *)
                echo -e "${RED}无效的选择${NC}"
                echo -ne "${YELLOW}按任意键继续...${NC}"
                read -n 1
                ;;
        esac
    done
}

# 端口管理菜单
port_management_menu() {
    while true; do
        clear
        echo -e "${BLUE}===== 端口访问管理 =====${NC}"
        echo
        
        # 显示已配置的端口
        echo -e "${CYAN}已配置的端口:${NC}"
        if [ -s "$PORT_CONFIG_FILE" ]; then
            echo -e "${CYAN}端口\t配置时间${NC}"
            echo "-----------------------------------"
            while IFS=':' read -r prefix port timestamp; do
                if [[ "$prefix" == "PORT" ]]; then
                    echo -e "$port\t$timestamp"
                fi
            done < "$PORT_CONFIG_FILE"
        else
            echo -e "${YELLOW}没有已配置的端口${NC}"
        fi
        
        echo
        echo -e "${YELLOW}请选择操作:${NC}"
        echo -e "1) 配置新端口"
        echo -e "2) 更新端口配置"
        echo -e "3) 删除端口配置"
        echo -e "4) 更新所有端口配置"
        echo -e "q) 返回主菜单"
        echo
        echo -ne "${YELLOW}请选择 [1-4或q]: ${NC}"
        read -r choice
        
        case $choice in
            1)
                echo -ne "${YELLOW}请输入要配置的端口号: ${NC}"
                read -r port
                if validate_port "$port"; then
                    configure_port "$port"
                    save_rules
                else
                    echo -e "${RED}无效的端口号${NC}"
                fi
                echo -ne "${YELLOW}按任意键继续...${NC}"
                read -n 1
                ;;
            2)
                echo -ne "${YELLOW}请输入要更新的端口号: ${NC}"
                read -r port
                if validate_port "$port"; then
                    if is_port_configured "$port"; then
                        configure_port "$port"
                        save_rules
                    else
                        echo -e "${RED}端口 $port 尚未配置${NC}"
                    fi
                else
                    echo -e "${RED}无效的端口号${NC}"
                fi
                echo -ne "${YELLOW}按任意键继续...${NC}"
                read -n 1
                ;;
            3)
                echo -ne "${YELLOW}请输入要删除配置的端口号: ${NC}"
                read -r port
                if validate_port "$port"; then
                    clear_port_config "$port"
                    save_rules
                else
                    echo -e "${RED}无效的端口号${NC}"
                fi
                echo -ne "${YELLOW}按任意键继续...${NC}"
                read -n 1
                ;;
            4)
                update_all_ports
                save_rules
                echo -ne "${YELLOW}按任意键继续...${NC}"
                read -n 1
                ;;
            q|Q)
                return
                ;;
            *)
                echo -e "${RED}无效的选择${NC}"
                echo -ne "${YELLOW}按任意键继续...${NC}"
                read -n 1
                ;;
        esac
    done
}

# 查看规则菜单
view_rules_menu() {
    clear
    echo -e "${BLUE}===== 查看当前规则 =====${NC}"
    echo
    
    show_iptables_rules
    
    echo
    echo -ne "${YELLOW}按任意键返回...${NC}"
    read -n 1
}

# 关于和帮助菜单
about_menu() {
    clear
    echo -e "${BLUE}===== 关于和使用说明 =====${NC}"
    echo
    echo -e "${CYAN}iptables交互式端口访问控制脚本${NC}"
    echo -e "版本: 1.0"
    echo
    echo -e "${CYAN}功能介绍:${NC}"
    echo -e "1. 管理允许访问特定端口的IP地址列表"
    echo -e "2. 为多个端口配置访问控制"
    echo -e "3. 实时应用iptables规则"
    echo -e "4. 保存配置以便系统重启后仍然有效"
    echo
    echo -e "${CYAN}使用说明:${NC}"
    echo -e "1. 首先添加允许的IP地址到'IP地址管理'"
    echo -e "2. 然后在'端口访问管理'中配置需要限制的端口"
    echo -e "3. 系统会自动应用配置并保存规则"
    echo -e "4. 使用'查看当前规则'验证配置是否正确"
    echo
    echo -e "${CYAN}注意事项:${NC}"
    echo -e "- 确保在添加IP限制前已将自己的IP加入允许列表"
    echo -e "- 配置SSH端口(22)时需特别小心，以免锁定自己"
    echo -e "- 所有配置保存在 $CONFIG_DIR 目录"
    echo
    echo -ne "${YELLOW}按任意键返回...${NC}"
    read -n 1
}

# 主菜单
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}=======================================${NC}"
        echo -e "${BLUE}      iptables端口访问控制系统        ${NC}"
        echo -e "${BLUE}=======================================${NC}"
        echo
        echo -e "${YELLOW}请选择操作:${NC}"
        echo -e "1) IP地址管理"
        echo -e "   1.1) 添加IP地址"
        echo -e "   1.2) 批量导入IP"
        echo -e "   1.3) 删除IP地址"
        echo -e "   1.4) 查看IP列表"
        echo -e "2) 端口访问管理"
        echo -e "3) 查看当前规则"
        echo -e "4) 备份当前规则"
        echo -e "5) 关于和帮助"
        echo -e "q) 退出"
        echo
        echo -ne "${YELLOW}请选择 [1-5或q]: ${NC}"
        read -r choice
        
        case $choice in
            1|1.1)
                add_ip_menu
                ;;
            1.2)
                batch_add_ip_menu
                ;;
            1.3)
                remove_ip_menu
                ;;
            1.4)
                clear
                echo -e "${BLUE}===== 允许访问的IP列表 =====${NC}"
                echo
                list_allowed_ips
                echo
                echo -ne "${YELLOW}按任意键返回...${NC}"
                read -n 1
                ;;
            2)
                port_management_menu
                ;;
            3)
                view_rules_menu
                ;;
            4)
                backup_rules
                echo -ne "${YELLOW}按任意键返回...${NC}"
                read -n 1
                ;;
            5)
                about_menu
                ;;
            q|Q)
                echo -e "${GREEN}感谢使用iptables端口访问控制系统，再见！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效的选择${NC}"
                echo -ne "${YELLOW}按任意键继续...${NC}"
                read -n 1
                ;;
        esac
    done
}

# 主程序开始
check_root
init_config
main_menu 
