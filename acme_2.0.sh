#!/bin/bash

# 确保脚本在遇到错误时退出
set -e

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
read -p "请输入电子邮件地址: " EMAIL

# 显示选项菜单
echo "请选择要使用的证书颁发机构 (CA):"
echo "1) Let's Encrypt"
echo "2) Buypass"
echo "3) ZeroSSL"
read -p "输入选项 (1, 2, or 3): " CA_OPTION

# 根据用户选择设置CA参数
case $CA_OPTION in
    1)
        CA_SERVER="letsencrypt"
        ;;
    2)
        CA_SERVER="buypass"
        ;;
    3)
        CA_SERVER="zerossl"
        ;;
    *)
        echo "无效选项"
        exit 1
        ;;
esac

# 提示用户是否关闭防火墙
echo "是否关闭防火墙？"
echo "1) 是"
echo "2) 否"
read -p "输入选项 (1 或 2): " FIREWALL_OPTION

# 如果用户选择不关闭防火墙，提示用户是否放行端口
if [ "$FIREWALL_OPTION" -eq 2 ]; then
    echo "是否放行特定端口？"
    echo "1) 是"
    echo "2) 否"
    read -p "输入选项 (1 或 2): " PORT_OPTION

    # 如果用户选择放行端口，提示用户输入端口号
    if [ "$PORT_OPTION" -eq 1 ]; then
        read -p "请输入要放行的端口号: " PORT
    fi
fi

# 安装依赖项、cron并关闭防火墙或放行端口
case $OS in
    ubuntu|debian)
        sudo apt update
        sudo apt upgrade -y
        sudo apt install -y curl socat git cron
        if [ "$FIREWALL_OPTION" -eq 1 ]; then
            if command -v ufw >/dev/null 2>&1; then
                sudo ufw disable
            else
                echo "UFW 未安装，跳过关闭防火墙步骤。"
            fi
        elif [ "$PORT_OPTION" -eq 1 ]; then
            if command -v ufw >/dev/null 2>&1; then
                sudo ufw allow $PORT
            else
                echo "UFW 未安装，跳过放行端口步骤。"
            fi
        fi
        ;;
    centos)
        sudo yum update -y
        sudo yum install -y curl socat git cronie
        sudo systemctl start crond
        sudo systemctl enable crond
        if [ "$FIREWALL_OPTION" -eq 1 ]; then
            sudo systemctl stop firewalld
            sudo systemctl disable firewalld
        elif [ "$PORT_OPTION" -eq 1 ]; then
            sudo firewall-cmd --permanent --add-port=${PORT}/tcp
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

# 添加执行权限
chmod +x "$HOME/.acme.sh/acme.sh"

# 注册帐户（使用用户提供的电子邮件地址）
acme.sh --register-account -m $EMAIL --server $CA_SERVER

# 申请 SSL 证书（使用用户提供的域名）
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

# 提示用户证书已生成
echo "SSL证书和私钥已生成:"
echo "证书: /root/${DOMAIN}.crt"
echo "私钥: /root/${DOMAIN}.key"

# 创建自动续期的脚本
cat << EOF > /root/renew_cert.sh
#!/bin/bash

# 设置 acme.sh 的路径
export PATH="$HOME/.acme.sh:$PATH"

# 设置日志文件路径
LOGFILE="/var/log/renew_cert.log"

# 获取当前时间的时间戳
CURRENT_TIME_STR=$(date "+%Y-%m-%d %H:%M:%S")

# 获取证书的信息
CERT_INFO=$(/root/.acme.sh/acme.sh --info -d www.www.www)

# 检查获取到的证书信息
if [ -z "$CERT_INFO" ]; then
    echo "$CURRENT_TIME_STR - 未能获取证书的信息，请检查 acme.sh 是否正确安装和配置。" >> $LOGFILE
    exit 1
fi

# 提取下次续期时间（ISO 8601 格式）
NEXT_RENEW_TIME_STR=$(echo "$CERT_INFO" | grep "Le_NextRenewTimeStr" | awk -F "=" '{print $2}' | tr -d '[:space:]')

# 检查是否成功提取下次续期时间
if [ -z "$NEXT_RENEW_TIME_STR" ]; then
    echo "$CURRENT_TIME_STR - 未能解析证书的续期时间，请检查证书信息。" >> $LOGFILE
    echo "$CURRENT_TIME_STR - 证书信息:" >> $LOGFILE
    echo "$CERT_INFO" >> $LOGFILE
    exit 1
fi

# 将续期时间从 ISO 8601 格式转换为 Unix 时间戳
NEXT_RENEW_TIME=$(date --date="${NEXT_RENEW_TIME_STR}" +%s 2>/dev/null)

# 如果上面的转换失败，手动替换 'T' 和 'Z' 格式
if [ -z "$NEXT_RENEW_TIME" ]; then
    NEXT_RENEW_TIME=$(date --date="${NEXT_RENEW_TIME_STR//T/ }" +%s 2>/dev/null)
fi

# 如果转换还是失败，退出
if [ -z "$NEXT_RENEW_TIME" ]; then
    echo "$CURRENT_TIME_STR - 无法解析续期时间，格式不正确或系统不支持该格式。" >> $LOGFILE
    exit 1
fi

# 获取当前时间的 Unix 时间戳
CURRENT_TIME=$(date +%s)

# 如果下次续期时间距离现在超过 30 天，不进行续期
if [ "$NEXT_RENEW_TIME" -gt "$((CURRENT_TIME + 2592000))" ]; then
    echo "$CURRENT_TIME_STR - 证书剩余有效期大于30天，跳过续期。" >> $LOGFILE
    exit 0
fi

# 停止 nginx 服务
if systemctl is-active --quiet nginx; then
    echo "$CURRENT_TIME_STR - nginx 服务正在运行，正在停止 nginx..." >> $LOGFILE
    sudo systemctl stop nginx
else
    echo "$CURRENT_TIME_STR - nginx 服务未运行，开始更新证书" >> $LOGFILE
fi

# 否则，进行续期
echo "$CURRENT_TIME_STR - 证书剩余有效期小于30天，正在续期..." >> $LOGFILE
/root/.acme.sh/acme.sh --renew -d hk.hankingv.top --server zerossl --force >> $LOGFILE 2>&1

# 检查续期是否成功
if [ $? -eq 0 ]; then
    echo "$CURRENT_TIME_STR - 证书续期成功" >> $LOGFILE
else
    echo "$CURRENT_TIME_STR - 证书续期失败" >> $LOGFILE
fi

# 重新启动 nginx 服务
if ! systemctl is-active --quiet nginx; then
    echo "$CURRENT_TIME_STR - nginx 服务未运行，正在启动 nginx..." >> $LOGFILE
    sudo systemctl start nginx
else
    echo "$CURRENT_TIME_STR - nginx 服务已在运行。" >> $LOGFILE
fi
EOF
chmod +x /root/renew_cert.sh

# 创建自动续期的 cron 任务，每天午夜执行一次
(crontab -l 2>/dev/null; echo "0 0 * * * /root/renew_cert.sh > /dev/null 2>&1") | crontab -
