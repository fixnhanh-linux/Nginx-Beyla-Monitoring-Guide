# Hướng dẫn Monitor NGINX bằng Grafana Beyla

Grafana Beyla là một công cụ mã nguồn mở của Grafana cho phép tự động giám sát (auto-instrumentation) các ứng dụng web và dịch vụ mạng bằng công nghệ **eBPF** (Extended Berkeley Packet Filter). 

Với Beyla, bạn có thể giám sát NGINX một cách "zero-code", tức là không cần phải sửa đổi mã nguồn hay cấu hình phức tạp của NGINX như các phương pháp truyền thống (ví dụ: dùng `nginx-prometheus-exporter`). Beyla hoạt động ở cấp độ kernel, cho phép quan sát trực tiếp lưu lượng mạng và các lệnh gọi dịch vụ, rất hiệu quả và dễ triển khai trên nhiều môi trường như Linux hay Kubernetes.

---

## 1. Yêu cầu hệ thống
- Hệ điều hành Linux hỗ trợ eBPF (Kernel >= 4.18 cho các tính năng cơ bản, khuyến nghị >= 5.8).
- NGINX đang chạy trên máy chủ Linux hoặc trong Kubernetes cluster.
- Quyền `root` hoặc CAP_SYS_ADMIN để có thể tải các chương trình eBPF vào kernel.

---

## 2. Giám sát NGINX trên máy chủ Linux thông thường

### Bước 1: Cài đặt Beyla
Tải phiên bản mới nhất của Beyla từ kho lưu trữ GitHub của Grafana:
```bash
wget https://github.com/grafana/beyla/releases/latest/download/beyla-linux-amd64
chmod +x beyla-linux-amd64
sudo mv beyla-linux-amd64 /usr/local/bin/beyla
```

### Bước 2: Cấu hình Beyla
Beyla cần biết process (tiến trình) nào cần được giám sát. Bạn có thể mục tiêu NGINX bằng cách chỉ định tên file thực thi (`exe_path`) hoặc port mà nó đang lắng nghe.

Tạo một file cấu hình có tên `beyla-config.yaml`:
```yaml
discovery:
  services:
    - name: "nginx-service"
      exe_path: "nginx" # Hoặc open_ports: 80, 443

otel_traces_export:
  endpoint: "http://<YOUR_OTEL_COLLECTOR_OR_TEMPO>:4318" # Thay đổi tùy thuộc vào backend của bạn

otel_metrics_export:
  endpoint: "http://<YOUR_OTEL_COLLECTOR_OR_PROMETHEUS>:4318"
```
*(Lưu ý: Thay thế các endpoint xuất dữ liệu bằng thông tin hệ thống OpenTelemetry/Prometheus/Tempo của bạn).*

### Bước 3: Chạy Beyla
Sử dụng cấu hình vừa tạo và chạy Beyla (cần quyền sudo/root):
```bash
sudo BEYLA_CONFIG_PATH=beyla-config.yaml beyla
```
---

## 3. Giám sát NGINX trong Kubernetes

Trong Kubernetes, Beyla có thể tự động khám phá các pod thông qua metadata. Cách phổ biến nhất là cài đặt Beyla dưới dạng DaemonSet qua Helm chart.

### Bước 1: Chuẩn bị Helm values
Tạo file `helm-beyla.yaml` với cấu hình sau để tìm các pod NGINX:
```yaml
config:
  data:
    discovery:
      services:
        - k8s_pod_labels:
            app: nginx # Sửa label này cho khớp với pod NGINX của bạn
```

### Bước 2: Cài đặt Beyla qua Helm
Chạy lệnh sau để thêm repository và cài đặt:
```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm upgrade --install beyla grafana/beyla -f helm-beyla.yaml -n monitoring --create-namespace
```

---

## 4. Trực quan hóa dữ liệu trên Grafana

Sau khi Beyla bắt đầu bắt lưu lượng, nó sẽ tạo ra các metric (tốc độ request, tỷ lệ lỗi, độ trễ) và trace (dấu vết) cho NGINX.

1. **Kết nối Data Source:** Đảm bảo Grafana của bạn đã kết nối tới database nhận dữ liệu (Prometheus, Grafana Alloy, hoặc Grafana Cloud).
2. **Import Dashboard:** 
   - Vào Grafana -> **Dashboards** -> **Import**.
   - Tìm kiếm các dashboard có sẵn trong thư viện Grafana bằng cách nhập **ID: 19923** (đây là ID phổ biến cho các dịch vụ được giám sát bởi Beyla) và tiến hành load.
3. **Kiểm tra dữ liệu:** Mở dashboard và bạn sẽ thấy các thông số hiệu suất NGINX của mình hiển thị realtime.

---

## Khi nào nên dùng Beyla vs NGINX Prometheus Exporter?
| Phương pháp | Phù hợp nhất cho | Yêu cầu cấu hình NGINX |
| :--- | :--- | :--- |
| **Grafana Beyla** | Muốn khả năng theo dõi request flows, RED metrics nhanh chóng, "zero-code" | Không yêu cầu cấu hình NGINX |
| **NGINX Exporter** | Cần metric chuyên sâu từ nội bộ NGINX (cache hits, worker connection saturation) | Cần module `stub_status` |

> **Khuyên dùng:** Nếu muốn xem nhanh luồng request và đo lường độ trễ mạng mà không muốn đụng vào file cấu hình NGINX, hãy sử dụng **Beyla**. Nếu bạn cần đo sức khỏe hệ thống NGINX (như số worker trống, hàng đợi kết nối), kết hợp dùng cả `nginx-prometheus-exporter`.