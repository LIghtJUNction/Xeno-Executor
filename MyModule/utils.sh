MODDIR=${0%/*}
LOGS=$MODDIR/logs
CRONDIR=$MODDIR/cron
CRONTABSDIR=$CRONDIR/crontabs
APIDIR=$MODDIR/API
UNICRONDIR=$MODDIR/UniCron
MODULES_DIR="/data/adb/modules"

mkdir -p $LOGS
mkdir -p $CRONDIR
mkdir -p $CRONTABSDIR
mkdir -p $APIDIR
mkdir -p $UNICRONDIR

INIT_SH=$MODDIR/init.sh # 初始化程序
INIT_LOG=$LOGS/init.log # 初始化日志
MODULE_LOG=$LOGS/UniCron.log #模块日志
unknown_process=$LOGS/unknown_process

UniCrond=$MODDIR/UniCrond.sh # 守护程序
UniCrond_cron=$UNICRONDIR/UniCrond.cron # 守护程序cron配置

MODULE_PROP=$MODDIR/module.prop

initialize_files() {
    local file=$1
    local permissions=$2
    if [ ! -f "$file" ]; then
        touch "$file"
    fi
    chmod "$permissions" "$file"
}

initialize_files "$INIT_SH" 755 
initialize_files "$UniCrond" 755 
initialize_files "$UniCrond_cron" 755 

initialize_files "$INIT_LOG" 777 # 确保日志可读
initialize_files "$MODULE_LOG" 777 #确保日志可读

initialize_files "$unknown_process" 644 # 未知crond/crontab进程，可能是其他模块的
initialize_files "$MODULE_PROP" 644 # 确保可读写

# 完成

# 读取 module.prop 文件中的值
get_prop_value() {
    local key=$1
    grep "^$key=" "$MODULE_PROP" | cut -d'=' -f2
}

# 修改 module.prop 文件中的值
set_prop_value() {
    local key=$1
    local value=$2
    if grep -q "^$key=" "$MODULE_PROP"; then
        sed -i "s/^$key=.*/$key=$value/" "$MODULE_PROP"
    else
        echo "$key=$value" >> "$MODULE_PROP"
    fi
}

add_to_list() {
    local list_file=$1
    local data=$2
    # 确保名单文件存在
    if [ ! -f "$list_file" ]; then
        touch "$list_file"
        chmod 644 "$list_file"
    fi

    # 将数据添加到名单文件
    echo "$data" >> "$list_file"
    echo "数据 '$data' 已加入名单文件 '$list_file'" >> "$MODULE_LOG"
}

# 查询函数，检查文件的某一行是否包含指定字符串
is_in_list() {
    local list_file=$1
    local data=$2
    if grep -q "$data" "$list_file"; then
        return 0 # 真
    else
        return 1 # 假
    fi
}
# 解释: 这里的0/1表示退出状态码 正常退出是0 异常是1 

LOG() {
    local log_level=$1
    local log_content=$2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$log_level] $log_content" >> "$MODULE_LOG"
}

crond(){
    local pid_file="$LOGS/crond.pid"

    # 检查 crond 是否已经在运行
    if pgrep -f "busybox crond" >/dev/null; then
        echo "crond 已经在运行" >> "$MODULE_LOG"
        return 0
    fi

    # 启动 crond 并记录 PID
    busybox crond -b -c "$CRONTABSDIR"
    sleep 1  # 等待 crond 启动
    PID=$(pgrep -f "busybox crond")
    if [ -n "$PID" ]; then
        add_to_list "$pid_file" "$PID"
        echo "启动 crond，PID: $PID" >> "$MODULE_LOG"
    else
        echo "crond 启动失败" >> "$MODULE_LOG"
    fi
}

crontab(){
    local file="$1"
    # 安装 crontab 文件，无需记录 PID
    busybox crontab -c "$CRONTABSDIR" "$file"
    echo "安装了新的 crontab 文件: $file" >> "$MODULE_LOG"
}

stop_crond(){
    local pid_file="$LOGS/crond.pid"

    # 检查 pid 文件是否存在
    if [ ! -f "$pid_file" ]; then
        echo "crond pid 文件不存在" >> "$MODULE_LOG"
        return 1
    fi

    # 读取 pid 文件中的 PID
    local pid=$(cat "$pid_file")

    # 检查进程是否存在并终止
    if [ -n "$pid" ] && kill -0 "$pid" ; then
        kill "$pid"
        if [ $? -eq 0 ]; then
            echo "成功终止 crond 进程，PID: $pid" >> "$MODULE_LOG"
            rm -f "$pid_file"
        else
            echo "无法终止 crond 进程，PID: $pid" >> "$MODULE_LOG"
            return 1
        fi
    else
        echo "crond 进程不存在或已终止，PID: $pid" >> "$MODULE_LOG"
        rm -f "$pid_file"
        return 1
    fi
}

format_cron_output() {
    local input="$1"
    local output=""
    while IFS= read -r line; do
        # 分割 cron 表达式和脚本路径
        cron_expr=$(echo "$line" | awk '{print $1" "$2" "$3" "$4" "$5}')
        script_path=$(echo "$line" | awk '{print $6}')
        # 提取模块和脚本名
        script="${script_path#/data/adb/modules/}"
        output="${output}${script} ：${cron_expr}；"
    done <<EOF
$input
EOF
    # 去除最后的分号
    output="${output%;}"
    echo "$output"
}

check(){
    local input=$(busybox crontab -c $CRONTABSDIR -l)
    local output=$(format_cron_output $input)
    set_prop_value "description" "$output"
}

merge_cron() {
    local output_file="$CRONDIR/Unicron_merged.cron"
    local merged_content=""
    # 检查是否有 .cron 文件
    if ls "$APIDIR"/*.cron >/dev/null 2>&1; then
        # 遍历 $APIDIR 目录下所有 .cron 文件并合并到变量中
        for cron_file in "$APIDIR"/*.cron; do
            merged_content="${merged_content}$(cat "$cron_file")"
            merged_content="${merged_content}
"  # 添加实际的换行符以确保文件之间有分隔
        done
    else
        LOG INFO "未找到任何 .cron 文件"
        return 1
    fi

    # 获取现有内容
    if [ -f "$output_file" ]; then
        existing_content="$(cat "$output_file")"
    else
        existing_content=""
    fi

    # 检查是否有变化
    if [ "$merged_content" != "$existing_content" ]; then
        # 有变化，写入目标文件
        echo "$merged_content" > "$output_file"
        return 0
    else
        # 无变化，返回 1
        return 1
    fi
}

RUN() {
    local init=$1
    if [ "$init" = "init" ];then
        crontab "$UniCrond_cron"
        crond # 初始化的时候运行一次
    else
        merge_cron
        if [ $? -eq 0 ]; then
            crontab "$CRONDIR/Unicron_merged.cron"
        else
            LOG INFO "无需更新"
        fi
    fi
}

remove_symlinks() {
    if [ -d "$1" ]; then
        local moduledir="$1"
        if [ -d "$APIDIR/$(basename "$moduledir")" ]; then
            for link in "$APIDIR/$(basename "$moduledir")"/*; do
                if [ ! -e "$link" ]; then
                    if [ -f "$link" ]; then
                        rm -f "$link"
                        rm -f "$APIDIR/$(basename "$moduledir")_$(basename "$link")"
                        LOG INFO "移除无效符号链接: $(basename "$moduledir")_$(basename "$link")"
                    else
                        LOG ERROR "尝试删除目录: $link，但此函数仅删除文件。"
                    fi
                fi
            done
        else
            LOG ERROR "$APIDIR/$(basename "$moduledir") 不存在"
        fi
    else
        local moduleid="$1"
        local cron_file_name="$2"
        local module_cron_link="$APIDIR/$moduleid/$cron_file_name"
        local cron_link="$APIDIR/$cron_file_name"
        if [ -f "$module_cron_link" ]; then
            rm -f "$module_cron_link"
        else
            LOG ERROR "尝试删除文件 $module_cron_link，但文件不存在(空文件不创建对应的符号链接)或不是普通文件"
        fi
        if [ -f "$cron_link" ]; then
            rm -f "$cron_link"
        else
            LOG ERROR "尝试删除文件 $cron_link，但文件不存在(空文件不创建对应的符号链接)或不是普通文件。"
        fi
    fi
}


