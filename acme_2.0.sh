#!/bin/bash

# 确保脚本在遇到错误时退出
set -e
trap 'echo "脚本执行出错，请检查！"; exit 1' ERR

# 日志文件路径
LOGFILE="/var/log/ssl_script.log"
exec > >(tee -a $LOGFILE) 2>&1
echo "==== 开始执行脚本 $(date) ===="

# 检查系统类型
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
elif command -v lsb_release >/dev/null 2>&1; then
    OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
else
    echo "无法确定操作系统类型，请手动安装依赖项。"
    exit 1
fi

# 提示用户输入域名和电子邮件地址
read -p "请输入域名: " DOMAIN
if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    echo "无效的域名格式，请检查输入！"
    exit 1
fi

read -p "请输入电子邮件地址: " EMAIL
if [[ ! "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo "无效的电子邮件地址格式，请检查输入！"
    exit 1
fi

# 显示选项菜单
echo "请选择要使用的证书颁发机构 (CA):"
echo "1) Let's Encrypt"
echo "2) Buypass"
echo "3) ZeroSSL"
read -p "输入选项 (1, 2, or 3): " CA_OPTION

case $CA_OPTION in
    1) CA_SERVER="letsencrypt" ;;
    2) CA_SERVER="buypass" ;;
    3) CA_SERVER="zerossl" ;;
    *) echo "无效选项"; exit 1 ;;
esac

# 提示用户是否关闭防火墙
echo "是否关闭防火墙？"
echo "1) 是"
echo "2) 否"
read -p "输入选项 (1 或 2): " FIREWALL_OPTION

# 如果用户选择不关闭防火墙，提示是否放行端口
if [ "$FIREWALL_OPTION" -eq 2 ]; then
    echo "是否放行特定端口？"
    echo "1) 是"
    echo "2) 否"
    read -p "输入选项 (1 或 2): " PORT_OPTION

    if [ "$PORT_OPTION" -eq 1 ]; then
        read -p "请输入要放行的端口号: " PORT
        if [[ ! "$PORT" =~ ^[0-9]+$ ]]; then
            echo "无效的端口号，请输入数字！"
            exit 1
        fi
    fi
fi

# 安装依赖项、配置防火墙
case $OS in
    ubuntu|debian)
        sudo apt update
        sudo apt upgrade -y
        sudo apt install -y curl socat git cron
        if [ "$FIREWALL_OPTION" -eq 1 ]; then
            if command -v ufw >/dev/null 2>&1; then
                sudo ufw disable || echo "UFW 已关闭"
            else
                echo "未检测到 UFW，跳过防火墙操作。"
            fi
        elif [ "$PORT_OPTION" -eq 1 ]; then
            if command -v ufw >/dev/null 2>&1; then
                sudo ufw allow $PORT || echo "端口 $PORT 已放行"
            else
                echo "未检测到 UFW，无法放行端口。"
            fi
        fi
        ;;
    centos)
        sudo yum update -y
        sudo yum install -y curl socat git cronie
        sudo systemctl start crond
        sudo systemctl enable crond
        if [ "$FIREWALL_OPTION" -eq 1 ]; then
            sudo systemctl stop firewalld || echo "Firewalld 已关闭"
            sudo systemctl disable firewalld
        elif [ "$PORT_OPTION" -eq 1 ]; then
            sudo firewall-cmd --permanent --add-port=${PORT}/tcp || echo "端口 $PORT 已放行"
            sudo firewall-cmd --reload
        fi
        ;;
    *)
        echo "不支持的操作系统：$OS"
        exit 1
        ;;
esac

# 安装 acme.sh
curl https://get.acme.sh | sh

# 使 acme.sh 脚本可用
export PATH="$HOME/.acme.sh:$PATH"
chmod +x "$HOME/.acme.sh/acme.sh"

# 注册帐户
~/.acme.sh/acme.sh --register-account -m $EMAIL --server $CA_SERVER

# 申请 SSL 证书
if ! ~/.acme.sh/acme.sh --issue --standalone -d $DOMAIN --server $CA_SERVER; then
    echo "证书申请失败，删除已生成的文件和文件夹。"
    rm -f /root/${DOMAIN}.key /root/${DOMAIN}.crt
    ~/.acme.sh/acme.sh --remove -d $DOMAIN
    exit 1
fi

# 安装 SSL 证书
~/.acme.sh/acme.sh --installcert -d $DOMAIN \
    --key-file       /root/${DOMAIN}.key \
    --fullchain-file /root/${DOMAIN}.crt

# 设置权限
chmod 600 /root/${DOMAIN}.key
chmod 644 /root/${DOMAIN}.crt

echo "SSL证书和私钥已生成:"
echo "证书: /root/${DOMAIN}.crt"
echo "私钥: /root/${DOMAIN}.key"

# 创建自动续期脚本
cat << EOF > /root/renew_cert.sh
#!/bin/bash
export PATH="\$HOME/.acme.sh:\$PATH"
~/.acme.sh/acme.sh --renew -d $DOMAIN --server $CA_SERVER > /var/log/renew_cert.log 2>&1
if [ \$? -eq 0 ]; then
    echo "证书续期成功: \$(date)" >> /var/log/renew_cert.log
else
    echo "证书续期失败: \$(date)" >> /var/log/renew_cert.log
fi
EOF

chmod +x /root/renew_cert.sh

# 创建自动续期任务
(crontab -l 2>/dev/null; echo "0 0 * * * /root/renew_cert.sh") | crontab -

echo "自动续期任务已添加，脚本执行完成！"
