#!/bin/bash
# Kịch bản tự động thiết lập Website thực tế trên NGINX để kiểm thử với Beyla

DOMAIN="fixcham.cloud"
WEB_DIR="/var/www/$DOMAIN/html"
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"

echo "1. Tạo thư mục chứa mã nguồn web tại $WEB_DIR..."
sudo mkdir -p $WEB_DIR

echo "2. Tạo file index.html..."
sudo bash -c "cat << 'EOF' > $WEB_DIR/index.html
<!DOCTYPE html>
<html lang=\"en\">
<head>
    <meta charset=\"UTF-8\">
    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
    <title>$DOMAIN - Monitored by Beyla</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background-color: #121212; color: #ffffff; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
        .container { text-align: center; background: #1e1e1e; padding: 40px; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.5); border-top: 4px solid #f39c12; }
        h1 { color: #f39c12; margin-bottom: 10px; }
        p { color: #aaaaaa; font-size: 1.1em; }
        .status { margin-top: 20px; padding: 10px; background: #27ae60; color: white; font-weight: bold; border-radius: 6px; display: inline-block; }
    </style>
</head>
<body>
    <div class=\"container\">
        <h1>Welcome to $DOMAIN</h1>
        <p>This actual web file is served by NGINX and actively monitored by <b>Grafana Beyla (eBPF)</b>.</p>
        <div class=\"status\">System Status: Online & Monitored</div>
    </div>
</body>
</html>
EOF"

echo "3. Tạo cấu hình Virtual Host cho NGINX..."
sudo bash -c "cat << 'EOF' > $NGINX_CONF
server {
    listen 80;
    server_name fixcham.cloud www.fixcham.cloud;
    
    root /var/www/fixcham.cloud/html;
    index index.html;
    
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF"

echo "4. Kích hoạt Website và khởi động lại NGINX..."
sudo ln -sf $NGINX_CONF /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

echo "Hoàn tất! Trang web $DOMAIN đã sẵn sàng."
echo "Hãy kiểm tra bằng lệnh: curl -H \"Host: $DOMAIN\" http://localhost"
