import socket
import numpy as np
import cv2
try:
    from numba import njit
    NUMBA_AVAILABLE = True
except ImportError:
    njit = None
    NUMBA_AVAILABLE = False

try:
    from ultralytics import YOLO
    YOLO_AVAILABLE = True
except ImportError:
    YOLO_AVAILABLE = False
    print("[警告] ultralytics 未安装，目标检测功能不可用。请运行: pip install ultralytics")

WIDTH, HEIGHT = 640, 480
HALF_WIDTH = WIDTH // 2
RGB_PER_HALF = HALF_WIDTH * 3

LISTEN_IP = '192.168.240.2'
LISTEN_PORT = 2

RGB_SWAP = True

ENABLE_YOLO = True
YOLO_MODEL = 'yolov8n.pt'
YOLO_CONF_THRESHOLD = 0.25
YOLO_IOU_THRESHOLD = 0.45
YOLO_DETECT_INTERVAL = 1

MIN_SHIFT_PIXELS = 2
MAX_SHIFT_PIXELS = WIDTH - 1
SEAM_MAD_FACTOR = 4.0
SEAM_MEDIAN_FACTOR = 2.0
SEAM_PEAK_RATIO = 1.5
SEAM_PEAK_DELTA = 12.0

FIX_BLACK_LINES = True
BLACK_LINE_THRESHOLD = 15
MIN_BLACK_LINE_HEIGHT = 100
BLACK_LINE_WIDTH = 3

DEBUG = False
DEBUG_PRINT_SEQ = DEBUG
DEBUG_PACKET_LOG = DEBUG

fps_counter = 0
fps_start = cv2.getTickCount()
FPS_FONT = cv2.FONT_HERSHEY_SIMPLEX
FPS_COLOR = (0, 255, 0)
fps_val = 0.0

if NUMBA_AVAILABLE:
    @njit(cache=True)
    def _column_mean_abs_diff(gray):
        h, w = gray.shape
        scores = np.zeros(w, dtype=np.float32)
        for c in range(w):
            nxt = (c + 1) % w
            acc = 0.0
            for r in range(h):
                acc += abs(int(gray[r, c]) - int(gray[r, nxt]))
            scores[c] = acc / h
        return scores
else:
    def _column_mean_abs_diff(gray):
        gray_i16 = gray.astype(np.int16, copy=False)
        diff = np.abs(gray_i16 - np.roll(gray_i16, -1, axis=1))
        return diff.mean(axis=0)


def detect_frame_seam(gray):
    _, w = gray.shape
    scores = _column_mean_abs_diff(gray)
    seam_idx = int(np.argmax(scores))
    peak = float(scores[seam_idx])
    median = float(np.median(scores))
    mad = float(np.median(np.abs(scores - median))) + 1e-6
    second_peak = float(np.max(np.delete(scores, seam_idx))) if w > 1 else 0.0

    if peak < median * SEAM_MEDIAN_FACTOR:
        return 0, peak, median, mad
    if peak < median + SEAM_MAD_FACTOR * mad:
        return 0, peak, median, mad
    if second_peak > 0.0 and peak < max(second_peak * SEAM_PEAK_RATIO,
                                        second_peak + SEAM_PEAK_DELTA):
        return 0, peak, median, mad

    shift = seam_idx + 1
    if shift >= w:
        return 0, peak, median, mad
    max_allowed = min(MAX_SHIFT_PIXELS, w - MIN_SHIFT_PIXELS)
    if shift < MIN_SHIFT_PIXELS or shift > max_allowed:
        return 0, peak, median, mad

    return shift, peak, median, mad


def correct_frame_shift(img):
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    shift, peak, median, mad = detect_frame_seam(gray)

    if shift:
        img = np.roll(img, -shift, axis=1)
        gray = np.roll(gray, -shift, axis=1)

    return img, gray, shift, (peak, median, mad)


def detect_and_fix_black_lines(img):
    if not FIX_BLACK_LINES:
        return img, 0

    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    h, w = gray.shape

    black_columns = []
    for col in range(w):
        column_data = gray[:, col]
        black_pixel_count = np.sum(column_data < BLACK_LINE_THRESHOLD)
        if black_pixel_count >= MIN_BLACK_LINE_HEIGHT:
            black_columns.append(col)

    if not black_columns:
        return img, 0

    fixed_img = img.copy()
    for col in black_columns:
        left_start = max(0, col - BLACK_LINE_WIDTH)
        left_end = col
        right_start = col + 1
        right_end = min(w, col + 1 + BLACK_LINE_WIDTH)

        neighbor_cols = []
        if left_start < left_end:
            neighbor_cols.extend(range(left_start, left_end))
        if right_start < right_end:
            neighbor_cols.extend(range(right_start, right_end))

        neighbor_cols = [c for c in neighbor_cols if c not in black_columns]

        if neighbor_cols:
            neighbor_data = img[:, neighbor_cols, :]
            fixed_img[:, col, :] = neighbor_data.mean(axis=1).astype(np.uint8)

    if DEBUG and black_columns:
        print(f"[修复] 检测到 {len(black_columns)} 条黑线，位置: {black_columns[:10]}{'...' if len(black_columns) > 10 else ''}")

    return fixed_img, len(black_columns)


def live_preview():
    global fps_counter, fps_start, fps_val

    yolo_model = None
    if ENABLE_YOLO and YOLO_AVAILABLE:
        try:
            print(f'正在加载 YOLO 模型: {YOLO_MODEL} ...')
            yolo_model = YOLO(YOLO_MODEL)
            print('YOLO 模型加载成功!')
        except Exception as e:
            print(f'[错误] 无法加载 YOLO 模型: {e}')
            print('目标检测功能已禁用')

    yolo_enabled = False

    frame_counter = 0
    last_detections = None

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 2 * 1024 * 1024)

    sock.bind((LISTEN_IP, LISTEN_PORT))
    sock.settimeout(1.0)
    print(f'UDP 监听 {LISTEN_IP}:{LISTEN_PORT} …')

    actual_buf = sock.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
    print(f'接收缓冲区大小: {actual_buf} 字节')

    half_rows = {}
    win_name = 'Live UDP 640x480'
    print("提示: 在窗口内按 'y' 切换 YOLO 检测，按 'q' 退出")

    img = np.zeros((HEIGHT, WIDTH, 3), dtype=np.uint8)
    empty_half = np.zeros(RGB_PER_HALF, np.uint8)

    received_seqs = set()
    total_packets = 0
    total_frames = 0
    correction_events = 0
    black_line_fixes = 0

    log_file = None
    if DEBUG_PACKET_LOG:
        import datetime
        log_name = f"udp_debug_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}.log"
        log_file = open(log_name, 'w')
        print(f"调试日志: {log_name}")

    while True:
        try:
            data, _ = sock.recvfrom(1024)
            if len(data) != 969:
                continue

            p0, p1, p2, zero, seq_hi, seq_lo, s0, s1, s2 = data[0:9]
            if not (p0 == 0xFF and p1 == 0x00 and p2 == 0xFF and
                    zero == 0x00 and
                    s0 == 0x00 and s1 == 0xFF and s2 == 0x00):
                continue

            seq = (seq_hi << 8) | seq_lo

            if DEBUG and DEBUG_PACKET_LOG and log_file:
                log_file.write(f"{seq}\n")

            if seq < 0 or seq >= 960:
                continue

            row, half = divmod(seq, 2)
            half_rows.setdefault(row, {})[half] = np.frombuffer(data[9:969], dtype=np.uint8)

            received_seqs.add(seq)
            total_packets += 1

            if seq == 959:
                total_frames += 1

                expected_seqs = set(range(960))
                missing_seqs = expected_seqs - received_seqs
                head_row_missing = missing_seqs == {0, 1}
                if DEBUG and missing_seqs and not head_row_missing:
                    missing_list = sorted(missing_seqs)
                    print(f"\n[警告] 帧 {total_frames} 丢包: {len(missing_list)}/{960} 个 ({len(missing_list)/960*100:.1f}%)")
                    if len(missing_list) <= 50:
                        print(f"  丢失序列号: {missing_list}")
                    else:
                        print(f"  前20个: {missing_list[:20]}")
                        print(f"  后20个: {missing_list[-20:]}")
                elif DEBUG and total_frames % 100 == 0:
                    print(f"[正常] 已接收 {total_frames} 帧，无丢包")

                img[:] = 0
                for r in range(HEIGHT):
                    left = half_rows.get(r, {}).get(0, empty_half)
                    right = half_rows.get(r, {}).get(1, empty_half)
                    if RGB_SWAP:
                        row_rgb = np.concatenate((left, right)).reshape(WIDTH, 3)
                        row_rgb = row_rgb[:, ::-1]
                        img[r, :] = row_rgb
                    else:
                        img[r, :] = np.concatenate((left, right)).reshape(WIDTH, 3)

                if head_row_missing:
                    img[0, :] = 0

                img, _, applied_shift, metrics = correct_frame_shift(img)

                if DEBUG and applied_shift != 0 and metrics is not None:
                    correction_events += 1
                    peak, median, mad = metrics
                    if correction_events <= 10 or correction_events % 50 == 0:
                        print(f"[修复] 帧 {total_frames}: 平移 {applied_shift} px，列差 {peak:.1f} (median {median:.1f}, mad {mad:.1f})")

                img, black_line_count = detect_and_fix_black_lines(img)
                if black_line_count > 0:
                    black_line_fixes += 1

                frame_counter += 1
                if yolo_model is not None and yolo_enabled and frame_counter % YOLO_DETECT_INTERVAL == 0:
                    try:
                        results = yolo_model(img, conf=YOLO_CONF_THRESHOLD,
                                            iou=YOLO_IOU_THRESHOLD, verbose=False)
                        last_detections = results[0]
                    except Exception as e:
                        print(f'[错误] YOLO 检测失败: {e}')

                if last_detections is not None:
                    try:
                        boxes = last_detections.boxes
                        for box in boxes:
                            x1, y1, x2, y2 = box.xyxy[0].cpu().numpy().astype(int)
                            conf = float(box.conf[0])
                            cls = int(box.cls[0])
                            label = f'{last_detections.names[cls]} {conf:.2f}'

                            cv2.rectangle(img, (x1, y1), (x2, y2), (0, 255, 0), 2)

                            label_size, _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.5, 1)
                            y1_label = max(y1, label_size[1] + 10)
                            cv2.rectangle(img, (x1, y1_label - label_size[1] - 10),
                                        (x1 + label_size[0], y1_label), (0, 255, 0), -1)

                            cv2.putText(img, label, (x1, y1_label - 5),
                                      cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 0, 0), 1)
                    except Exception as e:
                        print(f'[错误] 绘制检测结果失败: {e}')

                fps_counter += 1
                t_now = cv2.getTickCount()
                time_elapse = (t_now - fps_start) / cv2.getTickFrequency()
                if time_elapse >= 1.0:
                    fps_val = fps_counter / time_elapse
                    fps_counter = 0
                    fps_start = t_now
                cv2.putText(img, f'FPS:{fps_val:.1f}', (10, 30),
                            FPS_FONT, 1.0, FPS_COLOR, 2)

                cv2.imshow(win_name, img)
                key = cv2.waitKey(1) & 0xFF
                if key == ord('q'):
                    break
                elif key == ord('y'):
                    yolo_enabled = not yolo_enabled
                    if not yolo_enabled:
                        last_detections = None
                    if DEBUG:
                        print(f"[INFO] YOLO 检测 {'启用' if yolo_enabled else '禁用'}")
                half_rows.clear()
                received_seqs.clear()

        except socket.timeout:
            continue
        except KeyboardInterrupt:
            break

    sock.close()
    cv2.destroyAllWindows()


if __name__ == '__main__':
    live_preview()