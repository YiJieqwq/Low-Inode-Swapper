#!/system/bin/sh
# ============================================================
#  Low Inode Swapper — 降低 /data/local/tmp 的 inode 号
#  适用：已 root 的 Android 设备 (ext4/f2fs /data 分区)
#  原理：批量 mkdir/rmdir 推动 inode 分配器转子回绕
#  作者：YiJieqwq异界
# ============================================================

set -e

# ======================== 配置 ========================
TARGET="/data/local/tmp"
WORK_DIR="/data/local"
TEMP_PREFIX="${WORK_DIR}/.inode_race_"
BATCH_SIZE=200          # 每批创建的目录数（实测200最稳）
TARGET_MAX_INODE=10000  # 目标 inode 上限

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ======================== 工具函数 ========================
get_inode() { stat -c '%i' "$1" 2>/dev/null; }

now_ts() { date +%s; }

fmt_time() {
    local s="$1"
    if [ "$s" -lt 60 ]; then
        echo "${s}s"
    elif [ "$s" -lt 3600 ]; then
        echo "$((s/60))m$((s%60))s"
    else
        echo "$((s/3600))h$(((s%3600)/60))m$((s%60))s"
    fi
}

draw_bar() {
    local pct="${1:-0}" width="${2:-30}"
    local filled=$((pct * width / 100))
    local empty=$((width - filled))
    local bar=""
    local i=0
    while [ "$i" -lt "$filled" ]; do bar="${bar}█"; i=$((i + 1)); done
    i=0
    while [ "$i" -lt "$empty"  ]; do bar="${bar}░"; i=$((i + 1)); done
    printf "[%s]" "$bar"
}

# ======================== 环境检查 ========================
echo ""
echo -e "${BOLD}${CYAN}  ╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}  ║     Low Inode Swapper v2.1          ║${NC}"
echo -e "${BOLD}${CYAN}  ║  降低 /data/local/tmp 的 inode 号   ║${NC}"
echo -e "${BOLD}${CYAN}  ╚══════════════════════════════════════╝${NC}"
echo ""

# 检查 root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[✗] 需要 root 权限，请以 root 运行${NC}"
    exit 1
fi
echo -e "${GREEN}[✓]${NC} root 权限"

# 检查目标
if [ ! -d "$TARGET" ]; then
    echo -e "${RED}[✗] $TARGET 不存在${NC}"
    exit 1
fi
echo -e "${GREEN}[✓]${NC} $TARGET 存在"

# 检查工作目录可写
if [ ! -w "$WORK_DIR" ]; then
    echo -e "${RED}[✗] $WORK_DIR 不可写${NC}"
    exit 1
fi

# ======================== 获取 inode 信息 ========================
CURRENT_INODE=$(get_inode "$TARGET")
echo -e "${BLUE}[i]${NC} 当前 /data/local/tmp inode: ${YELLOW}$CURRENT_INODE${NC}"

if [ "$CURRENT_INODE" -le "$TARGET_MAX_INODE" ]; then
    echo -e "${GREEN}[✓]${NC} inode 已经 ≤ $TARGET_MAX_INODE，无需操作"
    exit 0
fi

# 获取文件系统总 inode 数（多种方法兜底）
get_total_inodes() {
    local total

    # 方法1: toybox stat -f
    total=$(stat -f -c '%c' "$WORK_DIR" 2>/dev/null) && [ "$total" -gt 0 ] && { echo "$total"; return 0; }

    # 方法2: 解析 stat -f 输出
    total=$(stat -f "$WORK_DIR" 2>/dev/null | awk '/[Ii]nodes:/{gsub(/[^0-9]/,"",$NF); print $NF}') && [ "$total" -gt 0 ] && { echo "$total"; return 0; }

    # 方法3: tune2fs（需要知道块设备）
    local dev
    dev=$(mount | grep " $WORK_DIR " | head -1 | awk '{print $1}')
    if [ -n "$dev" ]; then
        total=$(tune2fs -l "$dev" 2>/dev/null | awk '/Inode count/{print $NF}') && [ "$total" -gt 0 ] && { echo "$total"; return 0; }
    fi

    # 方法4: 常见 Android 路径
    for dev_path in /dev/block/by-name/userdata /dev/block/platform/*/by-name/userdata; do
        total=$(tune2fs -l "$dev_path" 2>/dev/null | awk '/Inode count/{print $NF}') && [ "$total" -gt 0 ] && { echo "$total"; return 0; }
    done

    echo "0"
}

TOTAL_INODES=$(get_total_inodes)

if [ "$TOTAL_INODES" -gt 0 ]; then
    echo -e "${BLUE}[i]${NC} 文件系统总 inode: ${YELLOW}$TOTAL_INODES${NC}"
    DISTANCE_TO_GO=$((TOTAL_INODES - CURRENT_INODE + TARGET_MAX_INODE))
    echo -e "${BLUE}[i]${NC} 预估需推进: ${YELLOW}$(printf "%'d" $DISTANCE_TO_GO 2>/dev/null || echo $DISTANCE_TO_GO)${NC} 个 inode 位"
    HAS_TOTAL=1
else
    echo -e "${YELLOW}[!]${NC} 无法获取总 inode 数，将不显示百分比进度"
    HAS_TOTAL=0
    # 用一个足够大的阈值来检测回绕（绝大多数 ext4/f2fs 远超此值）
    FAKE_WRAP_THRESHOLD=100000
fi

echo -e "${YELLOW}[▶]${NC} 开始搜索低 inode 目录（批量模式，每批 ${BATCH_SIZE} 个）"
echo ""

# ======================== 主循环 ========================
START_TS=$(now_ts)
BATCH_COUNT=0
ITERATIONS=0
MIN_INODE_SEEN=$CURRENT_INODE
MAX_INODE_SEEN=$CURRENT_INODE
LAST_INODE=$CURRENT_INODE
LAST_DISPLAY_TS=$START_TS
WRAPPED=0
PRE_WRAP_TRAVELED=0
KEEPER_PATH=""          # ★ 找到的低 inode 目录路径，留着不删

# 中断处理
interrupted=0
trap 'interrupted=1' INT TERM HUP

# 预清理可能残余的临时目录
rm -rf "${TEMP_PREFIX}"* 2>/dev/null

while [ "$interrupted" -eq 0 ]; do

    # ---- 第1步：批量创建 ----
    i=1
    while [ "$i" -le "$BATCH_SIZE" ]; do
        mkdir "${TEMP_PREFIX}${i}" 2>/dev/null || true
        i=$((i + 1))
    done

    # ---- 第2步：逐个检查 inode ----
    found_index=0
    i=1
    while [ "$i" -le "$BATCH_SIZE" ]; do
        dir="${TEMP_PREFIX}${i}"
        inode=$(get_inode "$dir")

        if [ -n "$inode" ]; then
            ITERATIONS=$((ITERATIONS + 1))

            # 更新观察范围
            [ "$inode" -lt "$MIN_INODE_SEEN" ] && MIN_INODE_SEEN=$inode
            [ "$inode" -gt "$MAX_INODE_SEEN" ] && MAX_INODE_SEEN=$inode

            # 检测回绕
            if [ "$WRAPPED" -eq 0 ]; then
                if [ "$HAS_TOTAL" -eq 1 ]; then
                    # 有精确总数：跨过半程判定
                    if [ "$LAST_INODE" -gt "$((TOTAL_INODES / 2))" ] && [ "$inode" -lt "$((TOTAL_INODES / 10))" ]; then
                        WRAPPED=1
                        PRE_WRAP_TRAVELED=$((TOTAL_INODES - CURRENT_INODE))
                        echo ""
                        echo -e "${CYAN}[↻]${NC} 检测到 inode 回绕！转子已回到低区"
                        echo ""
                    fi
                else
                    # 无精确总数：用绝对阈值判定
                    if [ "$LAST_INODE" -gt "$FAKE_WRAP_THRESHOLD" ] && [ "$inode" -lt "$((FAKE_WRAP_THRESHOLD / 20))" ]; then
                        WRAPPED=1
                        echo ""
                        echo -e "${CYAN}[↻]${NC} 检测到 inode 回绕！（基于启发式阈值）"
                        echo ""
                    fi
                fi
            fi

            LAST_INODE=$inode

            # 命中目标？
            if [ "$inode" -le "$TARGET_MAX_INODE" ]; then
                found_index=$i
                break
            fi
        fi
        i=$((i + 1))
    done

    # ---- 第3步：命中则保留低 inode 目录并退出 ----
    if [ "$found_index" -gt 0 ]; then
        KEEPER_PATH="${TEMP_PREFIX}${found_index}"
        KEEPER_INODE=$(get_inode "$KEEPER_PATH")
        echo ""
        echo -e "${GREEN}[✓] 命中！${NC} 目录 ${KEEPER_PATH} 的 inode = ${YELLOW}$KEEPER_INODE${NC}"

        # ★ 删除同批中除 keeper 外的所有目录
        i=1
        while [ "$i" -le "$BATCH_SIZE" ]; do
            if [ "$i" -ne "$found_index" ]; then
                rm -rf "${TEMP_PREFIX}${i}" 2>/dev/null
            fi
            i=$((i + 1))
        done
        break
    fi

    # ---- 第4步：整批删除，再来一轮 ----
    rm -rf "${TEMP_PREFIX}"* 2>/dev/null

    BATCH_COUNT=$((BATCH_COUNT + 1))

    # ---- 进度显示（每 10 批 或 每秒刷新）----
    NOW_TS=$(now_ts)
    if [ $((BATCH_COUNT % 10)) -eq 0 ] || [ $((NOW_TS - LAST_DISPLAY_TS)) -ge 1 ]; then
        ELAPSED=$((NOW_TS - START_TS))

        # 计算进度百分比
        if [ "$HAS_TOTAL" -eq 1 ]; then
            if [ "$WRAPPED" -eq 0 ]; then
                if [ "$LAST_INODE" -gt "$CURRENT_INODE" ]; then
                    traveled=$((LAST_INODE - CURRENT_INODE))
                else
                    traveled=0
                fi
            else
                traveled=$((PRE_WRAP_TRAVELED + LAST_INODE))
            fi

            if [ "$DISTANCE_TO_GO" -gt 0 ]; then
                pct=$(awk -v t="$traveled" -v d="$DISTANCE_TO_GO" 'BEGIN {p=(t/d)*100; if(p>99.9) p=99.9; printf "%.1f", p}')
            else
                pct="0.0"
            fi

            if [ "$traveled" -gt 0 ] && [ "$ELAPSED" -gt 0 ]; then
                rate=$(awk -v t="$traveled" -v e="$ELAPSED" 'BEGIN {printf "%.0f", t/e}')
                remaining=$((DISTANCE_TO_GO - traveled))
                [ "$remaining" -lt 0 ] && remaining=0
                eta_sec=$(awk -v r="$remaining" -v rt="$rate" 'BEGIN {printf "%.0f", (rt>0?r/rt:0)}')
            else
                rate="0"
                eta_sec="?"
            fi
        else
            pct="?"
            rate="?"
            eta_sec="?"
        fi

        pct_int=$(echo "$pct" | awk -F. '{print $1}')
        [ -z "$pct_int" ] && pct_int=0

        BAR=$(draw_bar "$pct_int" 25)
        STATUS_LINE="  ${BAR} ${CYAN}${pct}%${NC}  "
        STATUS_LINE="${STATUS_LINE}inode:${YELLOW}$LAST_INODE${NC}  "
        STATUS_LINE="${STATUS_LINE}批:${GREEN}$BATCH_COUNT${NC}  "
        STATUS_LINE="${STATUS_LINE}耗时:$(fmt_time $ELAPSED)"

        if [ "$eta_sec" != "?" ] && [ "$eta_sec" -gt 0 ] 2>/dev/null; then
            STATUS_LINE="${STATUS_LINE}  ETA:$(fmt_time $eta_sec)"
        fi

        printf "\r\033[K%s" "$STATUS_LINE"
        LAST_DISPLAY_TS=$NOW_TS
    fi
done

# 清理可能的中断残留
echo ""
if [ "$interrupted" -eq 1 ]; then
    echo -e "${YELLOW}[!]${NC} 用户中断，清理临时文件..."
    rm -rf "${TEMP_PREFIX}"* 2>/dev/null
    exit 130
fi

# ======================== 替换操作 ========================
echo ""
echo -e "${YELLOW}[▶]${NC} 正在替换 /data/local/tmp..."

OLD_PERM=$(stat -c '%a' "$TARGET" 2>/dev/null || echo "771")
OLD_OWNER=$(stat -c '%U' "$TARGET" 2>/dev/null || echo "shell")
OLD_GROUP=$(stat -c '%G' "$TARGET" 2>/dev/null || echo "shell")
OLD_CONTEXT=$(stat -c '%C' "$TARGET" 2>/dev/null)

# ★ 确保 keeper 目录仍在（可能被前面延迟的 rm 误伤）
if [ ! -d "$KEEPER_PATH" ]; then
    echo -e "${RED}[✗]${NC} 致命错误：keeper 目录丢失！请重新运行脚本"
    rm -rf "${TEMP_PREFIX}"* 2>/dev/null
    exit 1
fi

FINAL_TEMP_INODE=$(get_inode "$KEEPER_PATH")
echo -e "${BLUE}[i]${NC} 保留的低 inode 目录: ${KEEPER_PATH} (inode = ${YELLOW}$FINAL_TEMP_INODE${NC})"

# 二次确认
if [ "$FINAL_TEMP_INODE" -gt "$TARGET_MAX_INODE" ]; then
    echo -e "${RED}[✗]${NC} 异常：keeper 的 inode ($FINAL_TEMP_INODE) 不再 ≤ $TARGET_MAX_INODE"
    echo -e "${YELLOW}  可能发生了竞态，请重新运行脚本${NC}"
    rm -rf "${TEMP_PREFIX}"* 2>/dev/null
    exit 1
fi

# ★ 原子替换：旧 tmp 改名 → keeper 改名 → 删旧 tmp
#    避免 /data/local/tmp 在替换窗口不存在
TMP_OLD="${WORK_DIR}/.inode_tmp_old"
rm -rf "$TMP_OLD" 2>/dev/null

echo -e "${YELLOW}[▶]${NC} mv $TARGET → $TMP_OLD"
mv "$TARGET" "$TMP_OLD"

echo -e "${YELLOW}[▶]${NC} mv ${KEEPER_PATH} → $TARGET"
if ! mv "$KEEPER_PATH" "$TARGET"; then
    # 回滚！
    echo -e "${RED}[✗]${NC} 替换失败！正在回滚..."
    mv "$TMP_OLD" "$TARGET" 2>/dev/null
    rm -rf "$TMP_OLD" 2>/dev/null
    rm -rf "${TEMP_PREFIX}"* 2>/dev/null
    exit 1
fi

echo -e "${YELLOW}[▶]${NC} rm -rf $TMP_OLD"
rm -rf "$TMP_OLD"

# 恢复权限
chmod "$OLD_PERM" "$TARGET" 2>/dev/null
chown "${OLD_OWNER}:${OLD_GROUP}" "$TARGET" 2>/dev/null

# 恢复 SELinux 安全上下文
echo -e "${YELLOW}[▶]${NC} 正在恢复 SELinux 上下文..."
if ! restorecon "$TARGET" 2>/dev/null; then
    if [ -n "$OLD_CONTEXT" ]; then
        chcon "$OLD_CONTEXT" "$TARGET" 2>/dev/null
    else
        chcon u:object_r:shell_data_file:s0 "$TARGET" 2>/dev/null
    fi
fi


# ======================== 验证结果 ========================
FINAL_INODE=$(get_inode "$TARGET")
TOTAL_TIME=$(($(now_ts) - START_TS))

echo ""
echo -e "${BOLD}${CYAN}  ╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}  ║          操作完成                    ║${NC}"
echo -e "${BOLD}${CYAN}  ╚══════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${GREEN}初始 inode:${NC} ${YELLOW}$CURRENT_INODE${NC}"
echo -e "  ${GREEN}最终 inode:${NC} ${YELLOW}$FINAL_INODE${NC}"
echo -e "  ${GREEN}总耗时:${NC}    $(fmt_time $TOTAL_TIME)"
echo -e "  ${GREEN}总迭代:${NC}    $ITERATIONS 次"
echo -e "  ${GREEN}总批次:${NC}    $BATCH_COUNT 批"
echo -e "  ${GREEN}观察范围:${NC}  $MIN_INODE_SEEN ~ $MAX_INODE_SEEN"
echo ""

# ======================== 重启询问 ========================
echo -e "${YELLOW}建议重启设备以确保变更完全生效。${NC}"
while true; do
    printf "是否立即重启？[y/n] "
    read -r choice
    case "$choice" in
        y|Y)
            echo -e "${YELLOW}正在重启...${NC}"
            reboot
            exit 0
            ;;
        n|N|"")
            echo -e "${GREEN}已取消重启，请稍后手动重启${NC}"
            break
            ;;
        *)
            echo -e "${RED}无效输入，请输入 y 或 n${NC}"
            ;;
    esac
done
