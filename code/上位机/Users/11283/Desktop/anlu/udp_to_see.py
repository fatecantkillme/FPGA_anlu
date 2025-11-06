# 黑线修复参数
FIX_BLACK_LINES = True            # 是否启用黑线修复
BLACK_LINE_THRESHOLD = 10         # 检测黑线的亮度阈值（0-255）
MIN_BLACK_LINE_HEIGHT = 50        # 黑线最小高度（像素），低于此值不认为是黑线
BLACK_LINE_WIDTH = 3              # 修复时使用左右各N列的平均值


def detect_and_fix_black_lines(img):
    """检测并修复图像中的纵向黑线。
    
    原理：
    1. 使用CLAHE增强局部对比度
    2. 检测低于阈值的列
    3. 使用双边滤波器平滑修复
    """
    if not FIX_BLACK_LINES:
        return img, 0
    
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    
    # 增强对比度以应对高亮度场景
    clahe = cv2.createCLAHE(clipLimit=0.02, tileGridSize=(8,8))
    enhanced_gray = clahe.apply(gray)
    
    h, w = enhanced_gray.shape
    
    # 找出黑色列（降低阈值，提高灵敏度）
    black_columns = []
    for col in range(w):
        column_data = enhanced_gray[:, col]
        black_pixel_count = np.sum(column_data < BLACK_LINE_THRESHOLD)
        if black_pixel_count >= MIN_BLACK_LINE_HEIGHT * 0.5:  # 降低高度要求
            black_columns.append(col)
    
    if not black_columns:
        return img, 0
    
    # 修复黑线（使用双边滤波器平滑）
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
            # 使用双边滤波器平滑修复
            neighbor_data = img[:, neighbor_cols, :]
            mean_val = neighbor_data.mean(axis=1).astype(np.uint8)
            
            # 双边滤波器处理
            filtered_mean = cv2.bilateralFilter(mean_val, 5, 75, 75)
            fixed_img[:, col, :] = filtered_mean
    
    if DEBUG and black_columns:
        print(f"[修复] 检测到 {len(black_columns)} 条黑线，位置: {black_columns[:10]}{'...' if len(black_columns) > 10 else ''}")
    
    return fixed_img, len(black_columns)


def detect_frame_seam(gray):
    """在当前帧内寻找可疑的循环换行位置."""
    _, w = gray.shape
    
    # 增强对比度以应对高亮度场景
    # 使用CLAHE（对比度受限直方图均衡化）增强局部对比度
    clahe = cv2.createCLAHE(clipLimit=0.02, tileGridSize=(8,8))
    enhanced_gray = clahe.apply(gray)
    
    scores = _column_mean_abs_diff(enhanced_gray)
    seam_idx = int(np.argmax(scores))
    peak = float(scores[seam_idx])
    median = float(np.median(scores))
    mad = float(np.median(np.abs(scores - median))) + 1e-6
    second_peak = float(np.max(np.delete(scores, seam_idx))) if w > 1 else 0.0

    # 根据图像亮度动态调整阈值
    avg_brightness = np.mean(gray)
    brightness_factor = 1.0 + (avg_brightness / 255.0) * 0.5  # 亮度越高，阈值越低
    
    if peak < median * SEAM_MEDIAN_FACTOR * brightness_factor:
        return 0, peak, median, mad
    if peak < median + SEAM_MAD_FACTOR * mad * brightness_factor:
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
