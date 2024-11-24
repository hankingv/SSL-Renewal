#!/bin/bash

# 确保脚本在遇到错误时退出
set -e
trap 'echo "脚本执行出错，请检查！"; exit 1' ERR

# 日志文件路径
LOGFILE="/var/log/renew_cert.log"
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

# 安装依赖项
case $OS in
    ubuntu|debian)
        sudo apt update
        sudo apt upgrade -y
        sudo apt install -y curl socat git cron
        ;;
    centos)
        sudo yum update -y
        sudo yum install -y curl socat git cronie
        sudo systemctl start crond
        sudo systemctl enable crond
        ;;
    *)
        echo "不支持的操作系统：$OS"
        exit 1
        ;;
esac

# 安装 acme.sh
curl https://get.acme.sh | sh

# 设置 acme.sh 路径并验证安装
export PATH="$HOME/.acme.sh:$PATH"
echo "当前 PATH 路径: $PATH"

# 检查 acme.sh 是否存在
if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
    echo "acme.sh 安装失败，请检查错误！" >> $LOGFILE
    exit 1
fi

# 注册帐户
~/.acme.sh/acme.sh --register-account -m $EMAIL --server $CA_SERVER

# 如果 nginx 在运行，停止它
if systemctl is-active --quiet nginx; then
    echo "nginx 服务正在运行，正在停止 nginx..."
    sudo systemctl stop nginx
else
    echo "nginx 服务未运行，无需停止。"
fi

# 删除旧证书文件（如果存在）
echo "删除旧证书文件（如果有）..."
rm -rf /root/.acme.sh/$DOMAIN_ecc
rm -f /etc/v2ray/server.key /etc/v2ray/server.crt

# 强制申请 SSL 证书
if ! ~/.acme.sh/acme.sh --issue --standalone -d $DOMAIN --server $CA_SERVER --force; then
    echo "证书申请失败，删除已生成的文件和文件夹。" >> $LOGFILE
    rm -f /etc/v2ray/server.key /etc/v2ray/server.crt
    ~/.acme.sh/acme.sh --remove -d $DOMAIN
    exit 1
fi

# 安装 SSL 证书
~/.acme.sh/acme.sh --installcert -d $DOMAIN \
    --key-file       /etc/v2ray/server.key \
    --fullchain-file /etc/v2ray/server.crt

# 设置权限
chmod 600 /etc/v2ray/server.key
chmod 644 /etc/v2ray/server.crt

# 重新启动 nginx
if systemctl is-active --quiet nginx; then
    echo "nginx 服务正在运行，正在重新启动 nginx..."
    sudo systemctl start nginx
else
    echo "nginx 服务未运行，无需重新启动。"
fi

echo "SSL证书和私钥已生成:"
echo "证书: /etc/v2ray/server.crt"
echo "私钥: /etc/v2ray/server.key"

# 创建自动续期脚本
cat << EOF > /root/renew_cert.sh
#!/bin/bash
export PATH="\$HOME/.acme.sh:\$PATH"

# 获取证书的剩余有效期
REMAINING_DAYS=\$(~/.acme.sh/acme.sh --info -d $DOMAIN | grep "Valid till" | awk '{print \$4}')

# 如果剩余有效期大于30天，不进行续期
if [ "\$REMAINING_DAYS" -gt 30 ]; then
    echo "证书剩余有效期大于30天，跳过续期：\$REMAINING_DAYS 天" >> $LOGFILE
    exit 0
fi

# 否则，进行续期
~/.acme.sh/acme.sh --renew -d $DOMAIN --server $CA_SERVER >> $LOGFILE 2>&1
if [ \$? -eq 0 ]; then
    echo "证书续期成功: \$(date)" >> $LOGFILE
else
    echo "证书续期失败: \$(date)" >> $LOGFILE
fi
EOF

chmod +x /root/renew_cert.sh

# 创建自动续期任务
(crontab -l 2>/dev/null; echo "0 0 * * * /root/renew_cert.sh") | crontab -

echo "自动续期任务已添加，脚本执行完成！" >> $LOGFILE
