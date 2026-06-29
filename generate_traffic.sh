#!/bin/bash
# Script tạo lưu lượng truy cập ảo (Fake Traffic Generator) cho NGINX
# Sử dụng để test Grafana Dashboard kết hợp với Beyla (eBPF)

TARGET_IP="103.48.195.8"
TARGET_PORT="80"
BASE_URL="http://$TARGET_IP:$TARGET_PORT"

echo "======================================================"
echo "🚀 BẮT ĐẦU DỘI BOM TRAFFIC VÀO: $BASE_URL"
echo "======================================================"
echo "Nhấn Ctrl+C để dừng kịch bản."
echo ""

# Danh sách các endpoints để tạo sự đa dạng cho biểu đồ Breakdown Routes
ENDPOINTS=("/" "/api/login" "/api/data" "/admin-panel" "/trang-khong-ton-tai" "/assets/logo.png")

# Tỷ lệ phần trăm các mã lỗi (Phần lớn là 200, thỉnh thoảng 404)
# Mẹo: Khai báo mảng chứa nhiều endpoint chuẩn để tăng tỷ lệ 200 OK
WEIGHTED_ENDPOINTS=(
  "/" "/" "/" "/" "/"
  "/api/data" "/api/data"
  "/api/login"
  "/trang-khong-ton-tai"
  "/admin-panel"
)

# Danh sách phương thức HTTP (Thêm GRPC giả mạo để biểu đồ RPC sáng đèn)
METHODS=("GET" "GET" "GET" "GET" "POST" "GRPC")

while true; do
  # Lấy ngẫu nhiên đường dẫn và phương thức
  RANDOM_EP=${WEIGHTED_ENDPOINTS[$RANDOM % ${#WEIGHTED_ENDPOINTS[@]}]}
  RANDOM_METHOD=${METHODS[$RANDOM % ${#METHODS[@]}]}
  
  # Thời gian hiện tại để in log
  TIME=$(date +'%H:%M:%S')

  # In ra màn hình đang bắn request nào
  echo -n "[$TIME] $RANDOM_METHOD $RANDOM_EP ... "

  # Thực thi curl ngầm và chỉ lấy ra HTTP Status Code
  if [ "$RANDOM_METHOD" == "POST" ]; then
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST -d "{\"test\":\"data\"}" "$BASE_URL$RANDOM_EP")
  elif [ "$RANDOM_METHOD" == "GRPC" ]; then
    # Fake gRPC request để kích hoạt biểu đồ RPC (cố tình ép dùng HTTP/2)
    # NGINX sẽ trả về 400 hoặc 404, nhưng Beyla sẽ bắt được header application/grpc
    STATUS=$(curl --http2-prior-knowledge -s -o /dev/null -w "%{http_code}" -H "Content-Type: application/grpc" -H "TE: trailers" -X POST "$BASE_URL/FakeGRPCService/FakeMethod")
  else
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL$RANDOM_EP")
  fi

  # Tô màu cho Status Code để log nhìn chuyên nghiệp
  if [[ "$STATUS" == 2* ]]; then
    echo -e "\e[32m[Thành công - $STATUS]\e[0m" # Màu xanh
  elif [[ "$STATUS" == 3* ]]; then
    echo -e "\e[33m[Chuyển hướng - $STATUS]\e[0m" # Màu vàng
  elif [[ "$STATUS" == 4* ]]; then
    echo -e "\e[31m[Lỗi Client - $STATUS]\e[0m" # Màu đỏ
  elif [[ "$STATUS" == 000 ]]; then
    # curl báo 000 thường là lỗi kết nối HTTP/2 khi server không hỗ trợ
    echo -e "\e[35m[Fake gRPC Đã Bắn]\e[0m" # Màu tím
  else
    echo -e "\e[31m[Lỗi Server - $STATUS]\e[0m" # Màu đỏ
  fi

  # Nghỉ ngẫu nhiên từ 0.1 đến 0.5 giây để biểu đồ Traffic lượn sóng tự nhiên
  SLEEP_TIME=$(awk -v min=0.1 -v max=0.5 'BEGIN{srand(); print min+rand()*(max-min)}')
  sleep $SLEEP_TIME
done
