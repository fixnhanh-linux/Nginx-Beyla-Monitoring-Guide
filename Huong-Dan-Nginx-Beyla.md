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
# Tải bản phát hành mới nhất dành cho Linux AMD64
wget https://github.com/grafana/beyla/releases/latest/download/beyla-linux-amd64
chmod +x beyla-linux-amd64

# Di chuyển vào thư mục hệ thống để dễ sử dụng
sudo mv beyla-linux-amd64 /usr/local/bin/beyla
```

### 3.2. Cấu hình quét NGINX
Beyla cung cấp một cơ chế gọi là **Discovery** để tự động nhận diện ứng dụng. Cấu hình Beyla sẽ được định nghĩa qua file YAML. 

Tạo file `beyla-config.yaml` trên máy chủ:
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
```bash
sudo BEYLA_CONFIG_PATH=beyla-config.yaml beyla
```
Bạn có thể sử dụng `systemd` để cấu hình Beyla chạy ngầm và khởi động cùng hệ thống.

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

## 6. Trực quan hóa với Grafana Dashboard

Trong kho lưu trữ này (repository), tôi đã đính kèm sẵn file **`beyla-dashboard.json`** (phiên bản chuẩn hóa từ ID 19923 của thư viện Grafana) để bạn có thể import và xem ngay lập tức.

### Hướng dẫn Import Dashboard:
1. Mở giao diện **Grafana**.
2. Đảm bảo bạn đã thêm Data Source là **Prometheus** (nơi chứa dữ liệu Beyla gửi về). Nếu bạn chạy bằng Docker Compose, Data Source này đã được tạo sẵn.
3. Ở thanh menu bên trái, chọn biểu tượng **Dashboards** (hình 4 ô vuông) -> Nhấn vào nút **New** -> Chọn **Import**.
4. Bạn có 2 cách để nhập:
   - **Cách 1 (Sử dụng file có sẵn):** Nhấn **Upload dashboard JSON file** và chọn file `beyla-dashboard.json` nằm trong thư mục `grafana/provisioning/dashboards/` của mã nguồn này.
   - **Cách 2 (Sử dụng ID online):** Dán số `19923` vào ô *Import via grafana.com* và nhấn **Load**.
5. Trong bước tiếp theo, hãy chọn Data Source Prometheus của bạn ở mục thả xuống và nhấn **Import**.

**Các chỉ số và biểu đồ chính bạn sẽ xem được:**
1. **Overview — RED Index:**
   - **Rate (Tốc độ)**: Số lượng request mỗi giây.
   - **Errors (Lỗi)**: Tỉ lệ phần trăm các request bị lỗi (4xx, 5xx...).
   - **Duration (Độ trễ)**: Thời gian xử lý phản hồi mạng (Latency tính theo P90/P95/P99).
2. **Time Series — Traffic & Latency:**
   - Biểu đồ theo thời gian thực (Time Series) hiển thị xu hướng lưu lượng truy cập (Traffic / số lượng request).
   - Biểu đồ biến động độ trễ (Latency) theo từng mốc thời gian, giúp bạn dễ dàng phát hiện các điểm nghẽn cổ chai (bottlenecks) hay sự cố mạng bất thường.
   - Lưu lượng băng thông (Bandwidth) inbound/outbound đi qua NGINX.
3. **Breakdown — Routes & Status Codes:**
   - Phân tích chi tiết từng đường dẫn (Route) API hoặc HTTP cụ thể mà NGINX đang phục vụ.
   - Thống kê trực quan các trạng thái trả về (Status Codes như 200, 404, 500...), cho phép bạn nhanh chóng định vị được endpoint nào đang phát sinh lỗi.
4. **Distributed Tracing (Dấu vết phân tán):**
   - Ngoài các biểu đồ Metric tổng quan, Beyla có khả năng tự động sinh ra các đoạn Trace. Nếu kết nối với backend như Grafana Tempo, bạn có thể click trực tiếp từ một request lỗi trên dashboard để xem chính xác thời gian xử lý qua từng service (Span).
5. **Inbound vs Outbound Traffic Differentiation:**
   - Hệ thống tự động phân tách các request đi vào NGINX (Inbound) và các request mà NGINX proxy/gọi ngược ra các dịch vụ backend khác (Outbound), giúp cô lập lỗi nằm ở frontend hay backend.
6. **Top Slowest Endpoints (P95):**
   - Bảng xếp hạng trực quan các đường dẫn (HTTP routes) hoặc dịch vụ RPC có thời gian phản hồi chậm nhất (P95). Đây là cơ sở tuyệt vời để bạn biết chính xác cần ưu tiên tối ưu hóa (optimize) đoạn mã hay API nào.
7. **Service Topology / Dependency Map:**
   - Thông qua lượng dữ liệu eBPF khổng lồ, khi kết hợp với hệ thống Tracing, Grafana có thể tự động vẽ bản đồ luồng đi của dữ liệu (Node Graph), cho thấy NGINX đang liên kết với các microservices nào mà không cần bạn vẽ tay.

---

## 7. Các tính năng nâng cao nổi bật

Một trong những "vũ khí bí mật" mạnh mẽ nhất của Grafana Beyla (nhờ eBPF) là khả năng **Giám sát lưu lượng HTTPS/TLS**.
- Với các công cụ bắt gói tin mạng thông thường (như Wireshark, tcpdump), bạn sẽ chỉ thấy dữ liệu đã bị mã hoá nếu NGINX phục vụ qua HTTPS.
- Tuy nhiên, Beyla móc nối (hook) trực tiếp vào các thư viện mã hoá (như OpenSSL/BoringSSL) bên trong tiến trình NGINX. Do đó, nó có thể lấy được Request/Response HTTP ở dạng **chưa mã hoá (plaintext)** ngay trước khi dữ liệu bị mã hoá để gửi đi, hoặc ngay sau khi vừa được giải mã. Việc này hoàn toàn tự động và không cần bạn cung cấp TLS Certificate hay Private Key cho Beyla.

---

## 8. So sánh: Beyla vs NGINX Prometheus Exporter

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