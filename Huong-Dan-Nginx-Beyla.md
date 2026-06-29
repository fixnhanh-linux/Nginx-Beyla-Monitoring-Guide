# Hướng dẫn Toàn diện: Giám sát NGINX bằng Grafana Beyla & eBPF

Grafana Beyla là một công cụ mã nguồn mở được phát triển bởi Grafana Labs, giúp tự động giám sát (auto-instrumentation) các ứng dụng và dịch vụ mạng bằng công nghệ **eBPF (Extended Berkeley Packet Filter)**.

Điểm đặc biệt của Beyla là khả năng **"zero-code instrumentation"** – bạn hoàn toàn không cần phải sửa đổi mã nguồn ứng dụng hay thay đổi cấu hình phức tạp của NGINX (như việc phải kích hoạt module `stub_status` ở các giải pháp cũ). Thay vào đó, Beyla can thiệp ở cấp độ hạt nhân (kernel) để lắng nghe và phân tích trực tiếp lưu lượng mạng (HTTP/S, gRPC) cũng như các lệnh gọi dịch vụ (service calls).

---

## 1. Kiến trúc hệ thống giám sát
Mô hình triển khai phổ biến với Grafana Beyla sẽ trông như sau:
1. **NGINX**: Đóng vai trò là Web Server hoặc Reverse Proxy xử lý Request.
2. **Grafana Beyla (eBPF)**: Lắng nghe ở mức Kernel, tự động bắt các HTTP Request/Response đi qua NGINX để tạo ra Metrics (Độ trễ, Tỉ lệ lỗi, Băng thông,...) và Traces.
3. **Backend lưu trữ**: Beyla xuất dữ liệu dạng OpenTelemetry tới các hệ thống như Prometheus (để lưu Metrics) và Grafana Tempo (để lưu Traces).
4. **Grafana Dashboard**: Trực quan hóa dữ liệu được lưu trữ.

---

## 2. Yêu cầu hệ thống
- **Hệ điều hành**: Linux hỗ trợ eBPF (Kernel >= 4.18 cho các tính năng cơ bản, khuyến nghị dùng Kernel >= 5.8 để tối ưu hiệu năng).
- **Quyền hạn**: Beyla cần được chạy với quyền `root` hoặc có Capability `CAP_SYS_ADMIN` để tải các chương trình eBPF vào kernel.
- **Backend lưu trữ**: Đã cài đặt sẵn Prometheus (cho metrics) và Grafana (để hiển thị).

---

## 3. Triển khai trên máy chủ Linux (Bare-metal / VM)

### 3.1. Cài đặt Beyla
Tải xuống và phân quyền thực thi cho file nhị phân của Beyla:
```bash
# Lấy phiên bản mới nhất từ GitHub API
BEYLA_VERSION=$(curl -s https://api.github.com/repos/grafana/beyla/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

# Tải bản phát hành (tar.gz) mới nhất dành cho Linux AMD64
wget "https://github.com/grafana/beyla/releases/download/${BEYLA_VERSION}/beyla-linux-amd64-${BEYLA_VERSION}.tar.gz"

# Giải nén file
tar -xvzf beyla-linux-amd64-${BEYLA_VERSION}.tar.gz

# Di chuyển vào thư mục hệ thống để dễ sử dụng
chmod +x beyla
sudo mv beyla /usr/local/bin/beyla
```

### 3.2. Cấu hình quét NGINX
Beyla cung cấp một cơ chế gọi là **Discovery** để tự động nhận diện ứng dụng. Cấu hình Beyla sẽ được định nghĩa qua file YAML. 

Tạo một thư mục cấu hình và tạo file `beyla-config.yaml` (ví dụ đặt tại `/etc/beyla/` cho chuẩn mực hệ thống):
```bash
sudo mkdir -p /etc/beyla
sudo nano /etc/beyla/beyla-config.yaml
```

Dán nội dung sau vào file vừa tạo:
```yaml
discovery:
  services:
    - name: "nginx-proxy"
      # Beyla sẽ tự động tìm các tiến trình có tên là "nginx"
      exe_path: "nginx" 
      # Hoặc bạn có thể dùng port: 
      # open_ports: 80, 443

# Cấu hình đẩy dữ liệu Traces (Tùy chọn nếu dùng Tempo)
otel_traces_export:
  endpoint: "http://localhost:4318" 

# Cấu hình đẩy dữ liệu Metrics (Tùy chọn nếu dùng Prometheus qua OTel Collector)
otel_metrics_export:
  endpoint: "http://localhost:4318" 
  
# Nếu bạn muốn Prometheus tự pull dữ liệu từ Beyla, sử dụng cấu hình này thay thế:
prometheus_export:
  port: 8999
  path: "/metrics"
```
*Lưu ý: Nếu dùng cấu hình `prometheus_export`, bạn cần cấu hình Prometheus thêm 1 job scrape vào `IP_CUA_MAY_CHU:8999/metrics`.*

### 3.3. Khởi chạy Beyla
Chạy Beyla (Cần quyền root do sử dụng eBPF). Trỏ biến môi trường `BEYLA_CONFIG_PATH` tới file cấu hình bạn vừa tạo:
```bash
sudo BEYLA_CONFIG_PATH=/etc/beyla/beyla-config.yaml beyla
```
### 3.4. Cấu hình chạy ngầm với systemd
Để Beyla chạy ngầm ổn định và tự khởi động lại khi server reboot, bạn hãy tạo file service:
```bash
sudo nano /etc/systemd/system/beyla.service
```

Dán cấu hình sau vào:
```ini
[Unit]
Description=Grafana Beyla - eBPF Auto-instrumentation
After=network.target

[Service]
Type=simple
# Đường dẫn tới file config và file chạy
Environment="BEYLA_CONFIG_PATH=/etc/beyla/beyla-config.yaml"
# (Tùy chọn) Ghi đè port Prometheus nếu không dùng file yaml: Environment="BEYLA_PROMETHEUS_PORT=8999"
ExecStart=/usr/local/bin/beyla
Restart=always
User=root

[Install]
WantedBy=multi-user.target
```

Khởi động và kích hoạt service:
```bash
sudo systemctl daemon-reload
sudo systemctl enable beyla
sudo systemctl start beyla
sudo systemctl status beyla
```

---

## 4. Triển khai trên Kubernetes

Trong môi trường Kubernetes, cách tốt nhất là triển khai Beyla dưới dạng **DaemonSet**. Beyla sẽ quét toàn bộ các Pod trên Node để tìm NGINX thông qua metadata (labels/annotations).

### 4.1. Chuẩn bị file cấu hình Helm (helm-beyla.yaml)
Tạo file `helm-beyla.yaml` để chỉ định Beyla giám sát các pod NGINX:
```yaml
config:
  data:
    discovery:
      services:
        - name: "nginx-ingress-or-web"
          k8s_pod_labels:
            app: nginx # Sửa thành label NGINX thực tế trong cluster của bạn
    
    # Kích hoạt xuất metrics cho Prometheus scrape
    prometheus_export:
      port: 8999
      path: "/metrics"
```

### 4.2. Cài đặt bằng Helm
```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Cài đặt vào namespace monitoring
helm upgrade --install beyla grafana/beyla -f helm-beyla.yaml -n monitoring --create-namespace
```

---

## 5. Triển khai trọn gói bằng Docker Compose (Khuyến nghị)

Để bạn có thể thử nghiệm ngay lập tức toàn bộ hệ thống (NGINX + Beyla + Prometheus + Grafana), repository này đã cấu hình sẵn một ngăn xếp Docker Compose.

### 5.1. Kiến trúc Docker Compose
- **NGINX** (`:8080`): Máy chủ web mục tiêu.
- **Grafana Beyla**: Theo dõi NGINX sử dụng `pid: "service:nginx"` và chế độ `privileged: true` để chạy eBPF.
- **Prometheus** (`:9090`): Tự động scrape dữ liệu từ Beyla.
- **Grafana** (`:3000`): Tự động provision (cấu hình sẵn) Data source Prometheus và import sẵn Dashboard Beyla (từ file `beyla-dashboard.json`).

### 5.2. Chạy thử nghiệm

1. Clone repository này về máy của bạn:
   ```bash
   git clone https://github.com/fixnhanh-linux/Nginx-Beyla-Monitoring-Guide.git
   cd Nginx-Beyla-Monitoring-Guide
   ```

2. Khởi chạy toàn bộ hệ thống với Docker Compose:
   ```bash
   docker-compose up -d
   ```

3. Tạo một số luồng dữ liệu ảo vào NGINX để Beyla bắt được metrics:
   ```bash
   curl http://localhost:8080
   curl http://localhost:8080/test-404
   ```

4. Truy cập Grafana tại `http://localhost:3000` (Tài khoản mặc định: `admin` / `admin`).
5. Vào menu **Dashboards** -> Chọn thư mục **Beyla** -> Mở dashboard **Overview — RED Index** (hoặc **Beyla RED Metrics**) để xem kết quả trực quan hoá.

---

## 6. Trực quan hóa với Grafana Dashboard (Phiên bản Doanh nghiệp)

Trong kho lưu trữ này, tôi đã thiết kế và căn chỉnh sẵn file **`beyla-dashboard.json`** (được nâng cấp toàn diện từ thư viện gốc) để biến hệ thống của bạn thành một trung tâm giám sát (NOC) chuyên nghiệp.

### Hướng dẫn Import Dashboard:
1. Mở giao diện **Grafana**.
2. Ở thanh menu bên trái, chọn biểu tượng **Dashboards** -> Nhấn nút **New** -> Chọn **Import**.
3. Nhấn **Upload dashboard JSON file** và chọn file `beyla-dashboard.json` nằm trong thư mục `grafana/provisioning/dashboards/` của mã nguồn này.
4. Chọn Data Source Prometheus và nhấn **Import**.

### Cấu trúc Dashboard (Bố cục tối ưu 100%):

Giao diện Dashboard được tinh chỉnh tỉ mỉ theo từng hàng (Row) để giúp kỹ sư và quản lý dễ dàng nắm bắt sức khỏe hệ thống từ tổng quan đến chi tiết:

#### 🌟 Hàng 1: Các "Chỉ số sinh tử" (Big Number / Stat Panels)
Nằm chễm chệ ngay trên cùng là 4 ô chỉ số cực lớn được tô màu cảnh báo chuẩn mực, giúp bạn liếc mắt 1 giây là biết server đang sống hay chết:
- 🟡 **Request Rate (RPS)**: Tổng số lượt truy cập mỗi giây (Tốc độ gọi API).
- 🟡 **Error Rate (4xx + 5xx)**: Tỷ lệ lỗi hiện tại (Tự động chuyển **đỏ rực** nếu vượt ngưỡng báo động 5%).
- 🔴 **p99 Latency (server)**: Tốc độ phản hồi của 99% request (Thời gian chờ tối đa mà người dùng đang phải chịu).
- 🔵 **Avg Response Size**: Dung lượng phản hồi trung bình (Giúp phát hiện bất thường nếu API trả về cục dữ liệu quá to).

#### 📊 Hàng 2: Phân bổ trạng thái & Băng thông (Status Codes & Bandwidth)
- **HTTP Status Codes Breakdown (Cột/Bar chart)**: Chiếm 2/3 diện tích bên trái, thể hiện biến động số lượng các loại mã (200, 404, 500) theo trục thời gian.
  > [!NOTE] 
  > **Ghi chú về Đơn vị đếm (RPS vs Count):** Mặc định, các công cụ giám sát DevOps chuyên nghiệp luôn hiển thị Tốc độ truy cập (RPS - Requests per second) sử dụng hàm `rate()`, dẫn đến việc số lượng truy cập thường bị lẻ thập phân (ví dụ: `1.27 req/s`). Tuy nhiên, để thân thiện và trực quan hơn với người mới, Dashboard này đã được tôi tinh chỉnh tùy biến lại (dùng hàm `increase()` và ép `decimals: 0`) để nó luôn hiển thị **chính xác tổng số lượng request (ra số nguyên chẵn như 1, 2, 5, 20)** thay vì tốc độ.
- **Status Code Allocation (Tròn/Pie chart)**: Chiếm 1/3 diện tích bên phải, thể hiện tỷ lệ % trực quan giữa các mã trạng thái (Ví dụ: 80% là mã 200, 15% là mã 404, 5% là mã 500).
- **Network Traffic / Bandwidth (Full-width)**: Biểu đồ đường kéo dài toàn màn hình hiển thị lượng băng thông Inbound/Outbound. Việc trải rộng 100% giúp biểu đồ không bị gò bó, dễ dàng soi xét từng đợt "sóng" traffic.

#### 🐌 Hàng 3: Xác định nút thắt cổ chai (Slowest Endpoints)
- **Slowest HTTP routes (P95)**: Bảng xếp hạng các đường dẫn (URL/API) có thời gian xử lý chậm nhất. Bảng này được kéo rộng toàn màn hình để đảm bảo các chuỗi URL dài không bao giờ bị cắt xén hay che khuất.

#### 🕵️ Hàng 4: Truy vết phân tán & Sơ đồ kiến trúc (Tracing & Topology)
Đây là "trái tim" của công nghệ eBPF khi kết hợp với Grafana Tempo:
- **Recent Traces (Bảng TraceQL)**: Hiển thị danh sách các request theo thời gian thực (Trace ID, Tên API, Thời gian thực thi). Khi click vào một Trace ID, bạn sẽ nhìn thấu ruột gan của request đó (thời gian đi qua NGINX mất bao lâu, đi qua Backend mất bao lâu).
- **Service Topology (Sơ đồ mạng nhện)**: Hệ thống tự động vẽ ra bản đồ liên kết của các microservices (Ví dụ: `frontend` gọi tới `fixcham.cloud`, `fixcham.cloud` gọi tới `backend-api`). Nhìn vào đây, bạn sẽ lập tức biết kiến trúc hệ thống đang giao tiếp thế nào mà không cần phải tự vẽ sơ đồ tay!

---

## 7. Trải nghiệm Demo "Thế giới thực" (Gắn tên miền & Giả lập Microservice)

Để biến bài lab này thành một hệ thống thực tế (Production-like), kịch bản chạy ngầm đã được cấu hình để bơm **hàng loạt luồng dữ liệu ảo nhưng mang hình hài thật**. 

Thay vì mọi thứ chỉ hiển thị là `localhost`, hệ thống đang liên tục giả lập các truy cập vào đa dạng tên miền của hệ sinh thái **`fixcham.cloud`**:
1. **`api.fixcham.cloud`**: Phục vụ API người dùng (`/api/v1/users`), sản phẩm, và đôi lúc cố tình nhả lỗi 500.
2. **`auth.fixcham.cloud`**: Hệ thống xác thực (`/login`, `/register`, `/oauth/token`).
3. **`payments.fixcham.cloud`**: Cổng thanh toán (`/checkout`, Webhook Stripe).
4. **`static.fixcham.cloud`**: Phục vụ file tĩnh (JS, CSS) và đôi khi truy cập file không tồn tại để sinh lỗi 404.

**Kết quả:** Khi mở Grafana, bạn sẽ thấy Dashboard ngập tràn dữ liệu đa dạng y hệt như một hệ thống thương mại điện tử lớn đang phục vụ hàng nghìn người dùng cùng lúc. Tên dịch vụ (Service Name) cũng đã được cấu hình tĩnh lại thành **`fixcham.cloud`** để đồng bộ nhận diện.

---

## 7. Các tính năng nâng cao nổi bật

Một trong những "vũ khí bí mật" mạnh mẽ nhất của Grafana Beyla (nhờ eBPF) là khả năng **Giám sát lưu lượng HTTPS/TLS**.
- Với các công cụ bắt gói tin mạng thông thường (như Wireshark, tcpdump), bạn sẽ chỉ thấy dữ liệu đã bị mã hoá nếu NGINX phục vụ qua HTTPS.
- Tuy nhiên, Beyla móc nối (hook) trực tiếp vào các thư viện mã hoá (như OpenSSL/BoringSSL) bên trong tiến trình NGINX. Do đó, nó có thể lấy được Request/Response HTTP ở dạng **chưa mã hoá (plaintext)** ngay trước khi dữ liệu bị mã hoá để gửi đi, hoặc ngay sau khi vừa được giải mã. Việc này hoàn toàn tự động và không cần bạn cung cấp TLS Certificate hay Private Key cho Beyla.

---

## 8. Hướng dẫn thêm Website thật để giám sát (Thêm Monitor)

Nếu bạn muốn áp dụng hệ thống giám sát này cho một trang web thực tế (ví dụ: `fixcham.cloud`) chạy trên NGINX thay vì chỉ dùng dữ liệu giả lập, việc này vô cùng đơn giản.

Điểm tuyệt vời của Beyla là tính năng **Zero-code**: Chỉ cần NGINX chạy một trang web thực tế, Beyla sẽ tự động "đánh hơi" và giám sát nó mà không cần cài đặt thêm bất kỳ thư viện (agent) nào vào mã nguồn của bạn.

Để giúp bạn thử nghiệm nhanh chóng, tôi đã đóng gói toàn bộ quy trình tạo Website (gồm tạo thư mục web `/var/www/`, tạo file `index.html` giao diện xịn, và viết cấu hình Server Block Virtual Host cho NGINX) vào một kịch bản duy nhất.

### Cách triển khai Website:
Ngay trong thư mục gốc của repository này, bạn chỉ cần chạy lệnh sau:
```bash
# Phân quyền thực thi
chmod +x setup_real_web.sh

# Chạy kịch bản tự động
sudo ./setup_real_web.sh
```

**Kết quả:** Kịch bản sẽ tự động tạo ra một trang web tĩnh tuyệt đẹp tại domain `fixcham.cloud` và khởi động lại NGINX. 

Ngay lúc này, bất cứ ai truy cập vào trang web của bạn thông qua domain `fixcham.cloud`, công nghệ eBPF của Beyla sẽ lập tức chụp lấy request đó ở cấp độ nhân hệ điều hành (Kernel) và bắn lên Dashboard Grafana để bạn theo dõi băng thông, độ trễ và các lỗi (nếu có).

---

## 9. So sánh: Beyla vs NGINX Prometheus Exporter

Việc lựa chọn công cụ phụ thuộc vào mục đích đo lường của bạn:

| Tính năng / Đặc điểm | Grafana Beyla (eBPF) | NGINX Prometheus Exporter |
| :--- | :--- | :--- |
| **Cách hoạt động** | eBPF (Bắt gói tin từ Kernel) | Kéo (Pull) dữ liệu từ `stub_status` của NGINX |
| **Yêu cầu cấu hình NGINX** | Không cần cấu hình (Zero-code) | Bắt buộc phải thêm `location /nginx_status` |
| **RED Metrics (Request, Error, Traces)** | Cực kỳ chi tiết, theo dõi được từng endpoint cụ thể | Chỉ theo dõi được tổng số request toàn cục |
| **Chỉ số nội bộ NGINX** | ❌ Không có | ✅ Có (Số kết nối Active, Reading, Writing, Waiting) |
| **Ảnh hưởng hiệu năng** | Rất thấp (Nhờ eBPF) | Rất thấp |

> **Lời khuyên thực tiễn:**
> Bạn hoàn toàn có thể **kết hợp cả hai công cụ**. Hãy dùng `NGINX Prometheus Exporter` để theo dõi sức khoẻ của tiến trình NGINX (số lượng worker, connection queue), và dùng **Grafana Beyla** để theo dõi chi tiết hiệu năng của dòng chảy dữ liệu (lưu lượng HTTP, độ trễ từng API) một cách tự động.

---

## 9. Khắc phục sự cố thường gặp (Troubleshooting)

1. **Beyla không bắt được metrics:**
   - Kiểm tra xem Linux Kernel của bạn có tương thích không (`uname -r` >= 4.18, tốt nhất là 5.8+).
   - Đảm bảo Beyla chạy bằng quyền `root` hoặc container đã được set `privileged: true` / `cap_add: [SYS_ADMIN]`.
2. **Prometheus không hiển thị dữ liệu:**
   - Nếu bạn dùng port `:8999` để scrape, hãy xem log của Beyla xem port đã được mở thành công chưa.
   - Nếu bạn dùng `otel_metrics_export` (đẩy Push về Collector), hãy đảm bảo địa chỉ OTel Collector là chính xác và port `4318` đang mở.
3. **Dashboard Grafana bị trống (No Data):**
   - Kiểm tra lại phần chọn Data Source trên cùng của Dashboard.
   - Xác minh xem có request thực tế nào đang gọi vào NGINX không (nếu không có traffic, Beyla sẽ không sinh metric). Thử dùng lệnh `curl` liên tục để tạo dữ liệu mồi.