#!/system/bin/sh
# ============================================================
#  Low Inode Swapper v2.1 — 双缓冲区 · 彻底解决 inode 倒退
#  原理：Hold & Release 双缓冲区迫使 ext4 分配器单调前行
#  用法：
#    ./low_inode_swapper.sh                       # 默认 /data/local/tmp
#    ./low_inode_swapper.sh /path/to/target       # 自定义目标
#    adb shell touch /data/local/.stop_swapper    # 中途安全退出
# ============================================================

set -e

# ======================== 配置 ========================
TARGET="${1:-/data/local/tmp}"
WORK_DIR="$(dirname "$TARGET")"
PREFIX_A="${WORK_DIR}/.ira_"     # 缓冲区 A
PREFIX_B="${WORK_DIR}/.irb_"     # 缓冲区 B
BATCH_SIZE=200
TARGET_MAX_INODE=10000
STOP_FILE="${WORK_DIR}/.stop_swapper"

RED='\033[0;31m';    GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m';   CYAN='\033[0;36m';   BOLD='\033[1m'
NC='\033[0m'

# ======================== 工具函数 ========================
get_inode() { stat -c '%i' "$1" 2>/dev/null; }
now_ts()    { date +%s; }

fmt_time() {
    local s="$1"
    if   [ "$s" -lt 60   ]; then echo "${s}s"
    elif [ "$s" -lt 3600 ]; then echo "$((s/60))m$((s%60))s"
    else echo "$((s/3600))h$(((s%3600)/60))m$((s%60))s"; fi
}

draw_bar() {
    local pct="${1:-0}" w="${2:-25}"
    local f=$((pct * w / 100)) e=$((w - f))
    local bar="" i=0
    while [ "$i" -lt "$f" ]; do bar="${bar}█"; i=$((i+1)); done
    i=0
    while [ "$i" -lt "$e" ]; do bar="${bar}░"; i=$((i+1)); done
    printf "[%s]" "$bar"
}

# ======================== 退出钩子 ========================
EXIT_REASON=""
cleanup() {
    rm -rf "${PREFIX_A}"* "${PREFIX_B}"* 2>/dev/null
    rm -f "$STOP_FILE" 2>/dev/null

    local elapsed=$(($(now_ts) - START_TS))
    case "$EXIT_REASON" in
        stop)
            echo -e "\n\n${YELLOW}[⏸] 安全退出 — 目标目录未修改${NC}"
            echo -e "${BLUE}[i]${NC} 运行 $(fmt_time $elapsed)，${GREEN}$TOTAL_BATCHES${NC} 批 / ${GREEN}$TOTAL_ITERATIONS${NC} 次创建"
            ;;
        int)
            echo -e "\n\n${YELLOW}[⏸] Ctrl+C 中断 — 目标目录未修改${NC}"
            ;;
    esac
}
trap 'EXIT_REASON="int"; cleanup; exit 130' INT TERM HUP

check_stop() {
    if [ -f "$STOP_FILE" ]; then
        EXIT_REASON="stop"; cleanup; exit 0
    fi
}

# ======================== 创建一批目录 ========================
# 参数: $1=前缀, $2=起始编号(默认1)
# 输出: 这批目录中最大 inode（通过全局变量 LAST_MAX_INODE）
create_batch() {
    local prefix="$1" start="${2:-1}" i="$start" end=$((start + BATCH_SIZE - 1))

    while [ "$i" -le "$end" ]; do
        mkdir "$(printf '%s%04d' "$prefix" "$i")" 2>/dev/null || true
        i=$((i + 1))
    done

    # stat 整批，追踪 max inode
    local result
    result=$(stat -c "%i" "${prefix}"* 2>/dev/null | awk '
        { if ($1 > max) max = $1; count++ }
        END { printf "%d,%d", max+0, count+0 }
    ')
    LAST_MAX_INODE="${result%%,*}"
    local cnt="${result##*,}"
    TOTAL_ITERATIONS=$((TOTAL_ITERATIONS + cnt))
    TOTAL_BATCHES=$((TOTAL_BATCHES + 1))
}

# ======================== 检查两批中有无命中 ========================
# 参数: $1=前缀A, $2=前缀B
# 返回: 命中路径通过 HIT_PATH 全局变量返回（空=未命中）
check_double_batch() {
    local p1="$1" p2="$2"
    HIT_PATH=""

    local result
    result=$(stat -c "%n %i" "${p1}"* "${p2}"* 2>/dev/null | awk \
        -v max="$TARGET_MAX_INODE" '
        { if ($2 <= max) { print $1; exit } }
    ')
    HIT_PATH="$result"
}

# ======================== 启动 ========================
echo -e "\n${BOLD}${CYAN}  ╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}  ║    Low Inode Swapper v2.3 双缓冲版      ║${NC}"
echo -e "${BOLD}${CYAN}  ║  Hold & Release · inode 严格单调递增    ║${NC}"
echo -e "${BOLD}${CYAN}  ╚══════════════════════════════════════════╝${NC}"
echo -e "  ${BLUE}中途退出:${NC} adb shell touch ${STOP_FILE}"
echo -e "  ${BLUE}强制中断:${NC} Ctrl+C（终端内）\n"

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[✗] 需要 root 权限${NC}"; exit 1
fi
echo -e "${GREEN}[✓]${NC} root 权限"

if [ ! -d "$TARGET" ]; then
    echo -e "${RED}[✗] $TARGET 不存在${NC}"; exit 1
fi
echo -e "${GREEN}[✓]${NC} 目标: ${TARGET}"

CURRENT_INODE=$(get_inode "$TARGET")
echo -e "${BLUE}[i]${NC} 当前 inode: ${YELLOW}$CURRENT_INODE${NC}"

if [ "$CURRENT_INODE" -le "$TARGET_MAX_INODE" ]; then
    echo -e "${GREEN}[✓]${NC} inode ≤ $TARGET_MAX_INODE，无需操作"; exit 0
fi

# ======================== 获取总 inode ========================
get_total_inodes() {
    local t
    t=$(stat -f -c '%c' "$WORK_DIR" 2>/dev/null) && [ "$t" -gt 0 ] && { echo "$t"; return 0; }
    t=$(stat -f "$WORK_DIR" 2>/dev/null | awk '/[Ii]nodes:/{gsub(/[^0-9]/,"",$NF); print $NF}') && [ "$t" -gt 0 ] && { echo "$t"; return 0; }
    echo "0"
}

TOTAL_INODES=$(get_total_inodes)
if [ "$TOTAL_INODES" -gt 0 ]; then
    echo -e "${BLUE}[i]${NC} 总 inode: ${YELLOW}$TOTAL_INODES${NC}"
    DISTANCE_TO_GO=$((TOTAL_INODES - CURRENT_INODE + TARGET_MAX_INODE))
    echo -e "${BLUE}[i]${NC} 预估推进: ${YELLOW}$(printf "%'d" $DISTANCE_TO_GO 2>/dev/null || echo $DISTANCE_TO_GO)${NC} 位"
    HAS_TOTAL=1
else
    echo -e "${YELLOW}[!]${NC} 无法获取总 inode 数"
    HAS_TOTAL=0
fi

# 检查可用 inode
FREE_INODES=$(stat -f -c '%d' "$WORK_DIR" 2>/dev/null)
[ -n "$FREE_INODES" ] && [ "$FREE_INODES" -lt 500 ] && {
    echo -e "${RED}[✗] 可用 inode 不足 ($FREE_INODES)，操作风险较大，已中止${NC}"
    exit 1
}

echo -e "${YELLOW}[▶]${NC} 双缓冲区模式启动（交替 Hold & Release）\n"

# ======================== 主循环 ========================
START_TS=$(now_ts)
TOTAL_BATCHES=0
TOTAL_ITERATIONS=0
LAST_MAX_INODE=$CURRENT_INODE
LAST_DISPLAY_TS=0
WRAPPED=0
PRE_WRAP_TRAVELED=0
HIT_PATH=""

# 谁是"存活"的缓冲区
ALIVE_PREFIX=""
ACTIVE_PREFIX=""

# 清理 + 初始化
rm -rf "${PREFIX_A}"* "${PREFIX_B}"* "$STOP_FILE" 2>/dev/null

# 阶段 0：先创建第一批（A），作为初始"存活"缓冲区
check_stop
create_batch "$PREFIX_A" 1
ALIVE_PREFIX="$PREFIX_A"
ACTIVE_PREFIX="$PREFIX_B"

echo -e "${BLUE}[i]${NC} 初始缓冲区建立，开始交替推进..."

while true; do
    check_stop

    # ———— 创建新批次（在"存活"缓冲区之外分配 inode）————
    create_batch "$ACTIVE_PREFIX" 1

    # ———— 检查两个缓冲区中是否有命中 ————
    check_double_batch "$ALIVE_PREFIX" "$ACTIVE_PREFIX"

    if [ -n "$HIT_PATH" ]; then
        HIT_INODE=$(get_inode "$HIT_PATH")
        echo -e "\n${GREEN}[✓] 命中！${NC} inode = ${YELLOW}$HIT_INODE${NC}  (路径: ${HIT_PATH})"

        # 删除非命中的缓存
        [ "$(dirname "$HIT_PATH")" != "$ALIVE_PREFIX" ] && rm -rf "${ALIVE_PREFIX}"*
        rm -rf "${ACTIVE_PREFIX}"*
        # 确保命中目录还在
        break
    fi

    # ———— 释放旧的"存活"缓冲区（转子已越过它，不会再分配）————
    rm -rf "${ALIVE_PREFIX}"* 2>/dev/null

    # ———— 角色交换 ————
    local tmp="$ALIVE_PREFIX"
    ALIVE_PREFIX="$ACTIVE_PREFIX"
    ACTIVE_PREFIX="$tmp"

    # ———— 进度显示 ————
    NOW_TS=$(now_ts)
    if [ $((NOW_TS - LAST_DISPLAY_TS)) -ge 1 ]; then
        ELAPSED=$((NOW_TS - START_TS))

        if [ "$HAS_TOTAL" -eq 1 ]; then
            if [ "$WRAPPED" -eq 0 ]; then
                traveled=$((LAST_MAX_INODE - CURRENT_INODE))
                # 回绕检测
                if [ "$LAST_MAX_INODE" -lt "$((TOTAL_INODES / 10))" ] \
                    && [ "$traveled" -gt "$((TOTAL_INODES / 2))" ]; then
                    WRAPPED=1
                    PRE_WRAP_TRAVELED=$((TOTAL_INODES - CURRENT_INODE))
                    echo -e "\n${CYAN}[↻]${NC} inode 转子已回绕！即将进入低区\n"
                fi
            else
                traveled=$((PRE_WRAP_TRAVELED + LAST_MAX_INODE))
            fi
            [ "$traveled" -lt 0 ] && traveled=0

            pct=$(awk -v t="$traveled" -v d="$DISTANCE_TO_GO" \
                'BEGIN { printf "%.1f", (t/d*100 > 99.9 ? 99.9 : t/d*100) }')
            rate=$(awk -v t="$traveled" -v e="$ELAPSED" \
                'BEGIN { printf "%.0f", (e > 0 ? t/e : 0) }')
            remaining=$((DISTANCE_TO_GO - traveled))
            [ "$remaining" -lt 0 ] && remaining=0
            eta_sec=$(awk -v r="$remaining" -v rt="$rate" \
                'BEGIN { printf "%.0f", (rt > 0 ? r/rt : 0) }')
        else
            pct="?"; eta_sec="?"
        fi

        pct_int=$(echo "$pct" | cut -d'.' -f1)
        [ -z "$pct_int" ] || [ "$pct_int" = "?" ] && pct_int=0
        BAR=$(draw_bar "$pct_int")

        printf "\r\033[K  %b" \
            "${BAR} ${CYAN}${pct}%${NC}  ${YELLOW}#${LAST_MAX_INODE}${NC}  ${GREEN}×${TOTAL_BATCHES}批${NC}  $(fmt_time $ELAPSED)"
        if [ "$eta_sec" != "?" ] && [ "$eta_sec" -gt 0 ] 2>/dev/null; then
            printf "  ⏳$(fmt_time $eta_sec)"
        fi
        printf "  ${BLUE}[touch退出]${NC}"

        LAST_DISPLAY_TS=$NOW_TS
    fi
done

# ======================== 替换 ========================
echo -e "\n${YELLOW}[▶]${NC} 替换目标目录..."

OLD_PERM=$(stat -c '%a' "$TARGET" 2>/dev/null || echo "771")
OLD_OWNER=$(stat -c '%U' "$TARGET" 2>/dev/null || echo "shell")
OLD_GROUP=$(stat -c '%G' "$TARGET" 2>/dev/null || echo "shell")

TMP_OLD="${WORK_DIR}/.inode_old_target"
rm -rf "$TMP_OLD" 2>/dev/null

mv "$TARGET" "$TMP_OLD"
if ! mv "$HIT_PATH" "$TARGET"; then
    echo -e "${RED}[✗] 替换失败，回滚中…${NC}"
    mv "$TMP_OLD" "$TARGET" 2>/dev/null; exit 1
fi
rm -rf "$TMP_OLD" 2>/dev/null

chmod "$OLD_PERM" "$TARGET" 2>/dev/null
chown "${OLD_OWNER}:${OLD_GROUP}" "$TARGET" 2>/dev/null
restorecon -R "$TARGET" 2>/dev/null || true

# ======================== 结果 ========================
FINAL_INODE=$(get_inode "$TARGET")
TOTAL_TIME=$(($(now_ts) - START_TS))

echo -e "\n${BOLD}${GREEN}  ╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}  ║            操作完成 ✓               ║${NC}"
echo -e "${BOLD}${GREEN}  ╚══════════════════════════════════════╝${NC}\n"
echo -e "  ${RED}初始 inode:${NC} ${YELLOW}$CURRENT_INODE${NC}"
echo -e "  ${GREEN}最终 inode:${NC} ${YELLOW}$FINAL_INODE${NC}"
echo -e "  ${GREEN}总耗时:${NC}    $(fmt_time $TOTAL_TIME)"
echo -e "  ${GREEN}总批次数:${NC}  $TOTAL_BATCHES 批 / $TOTAL_ITERATIONS 次创建"
echo ""
