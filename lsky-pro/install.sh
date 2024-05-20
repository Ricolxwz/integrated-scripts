echo "---------- 安装基础依赖 ----------"
apt install cron git curl wget unzip ca-certificates -y
echo "---------- IPv6启动 ----------"
echo "net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0" >> /etc/sysctl.conf
sysctl -p
echo "---------- IPv4优先级更高 ----------"
echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
echo "---------- DDNS安装配置 ----------"
cd /root
git clone https://github.com/timothymiller/cloudflare-ddns.git
cd cloudflare-ddns
touch config.json
read -p "请输入DNS服务商API: " api
read -p "请输入域名区域id: " zone
read -p "请输入二级域名: " sub_domain
echo -e "{
  \x22cloudflare\x22: [
    {
      \x22authentication\x22: {
        \x22api_token\x22: \x22$api\x22
      },
      \x22zone_id\x22: \x22$zone\x22,
      \x22subdomains\x22: [
        {
          \x22name\x22: \x22$sub_domain\x22,
          \x22proxied\x22: false
        }
      ]
    }
  ],
  \x22a\x22: true,
  \x22aaaa\x22: true,
  \x22purgeUnknownRecords\x22: false,
  \x22ttl\x22: 300
}" > config.json
apt install python3 python3-venv -y
python3 -m venv venv
./start-sync.sh
echo "---------- Crontab配置 ----------"
cd /var/spool/cron/crontabs
touch root
echo "*/15 * * * * cd /root/cloudflare-ddns && ./start-sync.sh" >> root
echo "@reboot cd /root/cloudflare-ddns && ./start-sync.sh" >> root
systemctl restart cron
echo "---------- ACME配置 ----------"
cd /root
curl https://get.acme.sh | sh
read -p "请输入邮箱: " email
read -p "请输入域名: " domain
echo "请选择一个SSL证书机构:"
options=("letsencrypt" "buypass" "zerossl" "ssl.com" "google")
select opt in "${options[@]}"
do
    case $opt in
        "letsencrypt")
            echo "Switching to Let's Encrypt"
            ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
            break
            ;;
        "buypass")
            echo "Switching to Buypass"
            ~/.acme.sh/acme.sh --set-default-ca --server buypass
            break
            ;;
        "zerossl")
            echo "Switching to ZeroSSL"
            ~/.acme.sh/acme.sh --set-default-ca --server zerossl
            break
            ;;
        "ssl.com")
            echo "Switching to SSL.com"
            ~/.acme.sh/acme.sh --set-default-ca --server ssl.com
            break
            ;;
        "google")
            echo "Switching to Google Public CA"
            ~/.acme.sh/acme.sh --set-default-ca --server google
            break
            ;;
        *) echo "Invalid option. Please try again.";;
    esac
done
echo "你选择的SSL证书机构为: $opt"
~/.acme.sh/acme.sh --register-account -m $email
~/.acme.sh/acme.sh --issue -d $domain --standalone
~/.acme.sh/acme.sh --installcert -d $domain --key-file /root/private.key --fullchain-file /root/cert.crt
echo "---------- 安装php ----------"
apt install php -y
echo "---------- 安装sqlite3 ----------"
apt install sqlite3 -y
echo "---------- 安装nginx ----------"
apt install php-fpm -y
systemctl stop apache2
systemctl disable apache2
apt purge apache2 -y
apt autoremove -y
apt install nginx -y
echo "---------- 安装redis ----------"
apt install redis -y
echo "---------- 安装php扩展 ----------"
apt install php-mysqli php-sqlite3 php-curl php-mbstring php-imagick php-redis php-dom php-bcmath -y
systemctl restart nginx
echo "---------- 建立网站 ----------"
read -p "Please input download url: " download_url
cd /var/www/html
rm -rf * .*
wget $download_url
unzip *
ls -a | grep 'zip' | xargs -d '\n' rm
systemctl reload nginx
echo "---------- 配置nginx ----------"
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html
chmod 755 /var/www/html/.env
chown www-data:www-data /var/www/html/.env
cd /etc/nginx/sites-available
echo -e "server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    return 301 https:///x24server_name/x24request_uri;
}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $domain;
    ssl_certificate /root/cert.crt;
    ssl_certificate_key /root/private.key;
    client_max_body_size 100M;
    root /var/www/html/public;
    index index.php;
    location / {
            try_files /x24uri /x24uri/ /index.php?/x24query_string;
            proxy_set_header Host /x24host;
            proxy_set_header X-Real-IP /x24remote_addr;
            proxy_set_header X-Forwarded-For /x24proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto /x24scheme;
            proxy_set_header REMOTE-HOST /x24remote_addr;
    }
    location ~ \.php/x24 {
            include snippets/fastcgi-php.conf;
            fastcgi_pass unix:/run/php/php8.2-fpm.sock;
    }
    location ~ /\.ht {
            deny all;
    }
}" > default
systemctl restart nginx
echo "---------- 配置env ----------"
cd /var/www/html
php artisan key:generate
app_url="https://$domain"
read -p "Please input serial no: " serial_no
read -p "Please input secret: " app_secret
sed -i "s|APP_URL=.*|APP_URL=${app_url}|" .env
sed -i "s|APP_SERIAL_NO=.*|APP_SERIAL_NO=${serial_no}|" .env
sed -i "s|APP_SECRET=.*|APP_SECRET=${app_secret}|" .env
echo "---------- Supervisor配置 ----------"
apt install supervisor -y
cd /etc/supervisor/conf.d
touch lsky-pro.conf
echo "[program:lsky-pro-worker]
process_name=%(program_name)s_%(process_num)02d
command=php artisan queue:work --queue=emails,images,thumbnails
directory=/var/www/html/
user=root
numprocs=1
autorestart=true
startsecs=3
startretries=3
stdout_logfile=/var/www/html/storage/logs/supervisor.out.log
stderr_logfile=/var/www/html/storage/logs/supervisor.err.log
stdout_logfile_maxbytes=2MB
stderr_logfile_maxbytes=2MB" > lsky-pro.conf
supervisorctl reread
supervisorctl update
supervisorctl start lsky-pro-worker:*
echo "---------- Crontab配置2 ----------"
cd /var/spool/cron/crontabs
echo "* * * * * cd /var/www/html && php artisan schedule:run >> /dev/null 2>&1" >> root
systemctl restart cron
