#!/bin/bash
if [[ $_ != $0 ]]
then
    script="${BASH_SOURCE[0]}"
    unset exec
else
    script="$0"
    if [ -z "$1" ]
    then
        exec="exec bash"
    else
        exec="exec $1"
        shift
    fi
fi

[ -f ~/.bushrc ] &&
    source ~/.bushrc

unset which

export bush_dir=$(dirname $script)
export src="${bush_dir}/src"
export proj_dir=$(readlink -ne "${bush_dir}/..")
export bare_dir="${proj_dir}/mariadb.git"
export log_dir="${bush_dir}/log"
export tarball_dir="/home/ec2-user"

export MYSQL_UNIX_PORT="${bush_dir}/run/mysqld.sock"
export MTR_BINDIR="$build"
export CCACHE_BASEDIR="${bush_dir}"
export CCACHE_DIR="$(realpath ${bush_dir}/../.ccache)"
export CCACHE_NLEVELS=3
# export CCACHE_HARDLINK=true
export CCACHE_MAXSIZE=15G

ulimit -Sc 0

# Detect mysql or mariadb
detection_file="${src}/INSTALL-SOURCE"
detection_file2="${src}/MYSQL_VERSION"
export product=mariadb
export opt_debug_gdb=--debug-gdb
export opt_silent=--silent-startup
mtr_opts="--tail-lines=0"
mtrg_opts="--mysqld=--use-stat-tables=never"
opt_ddl="--mysqld=--debug=d,ddl_log"
opt_vers="--mysqld=--debug=d,sysvers_force --mysqld=--system_versioning_alter_history=keep"
opt_fts="--mysqld=--innodb_ft_sort_pll_degree=1"

if [ -f $detection_file2 ] || [ ! -f $detection_file ] || (
    ! grep -iq mariadb $detection_file &&
    grep -iq mysql $detection_file)
then
    product=mysql
    opt_debug_gdb=--gdb
    opt_silent=
    mtr_opts=
    mtrg_opts=
    opt_ddl=
    opt_vers=
    export PERL5OPT=${PERL5OPT:+$PERL5OPT }-I"${src}/mysql-test"
fi

for_mariadb()
{
    [ $product = mariadb ] &&
        echo "$1" ||
        echo "$2"
}
export -f for_mariadb

is_rhel()
{
    [ -f /etc/redhat-release ] &&
        return 0
    return 1
}
export -f is_rhel

if is_rhel
then
    function which
    {
        /usr/bin/which "$@" 2>/dev/null
    }
    export -f which
    unalias which &> /dev/null || true
fi

add_path()
{
    [[ ":$PATH:" == *":${1}:"* ]] ||
        PATH="${1}:${PATH}"
}

# innodb_ruby setup
add_path "${proj_dir}/innodb_ruby/bin"
export RUBYLIB=${proj_dir}/innodb_ruby/lib
alias ispace=innodb_space
alias ilog=innodb_log

# RQG setup
export RQG_HOME="${proj_dir}/randgen"
add_path "$RQG_HOME"

mtr()
{(
    mkdir -p "$log_dir"
    export MTR_BINDIR="$build"
    if [ -x ./mysql-test-run.pl ]
    then
        mtr_script=$(readlink -f ./mysql-test-run.pl)
    elif [ -x ./mariadb-test-run.pl ]
    then
        mtr_script=$(readlink -f ./mariadb-test-run.pl)
    elif [ -x "$src/mysql-test/mysql-test-run.pl" ]
    then
        cd "$src/mysql-test"
        mtr_script="./mysql-test-run.pl"
    elif [ -x "$src/mysql-test/mariadb-test-run.pl" ]
    then
        cd "$src/mysql-test"
        mtr_script="./mariadb-test-run.pl"
    else
        echo "Cannot find MTR script!" >&2
        exit 1
    fi
    if [ "$1" = "PERLDB" ]
    then
        shift
        mtr_script="perl -d $mtr_script"
    elif [ "$1" = "GDB" ]
    then
        shift
        mtr_script="gdb --args perl -MEnbugger $mtr_script"
    elif [ "$1" = "RR" ]
    then
        shift
        mtr_script="rr record $mtr_script"
    fi
    rm `find "$log_dir" -name '*.log' -type f -ctime +30` &> /dev/null
    unset exclude_opts
    [ -f ~/tests_exclude ] &&
        exclude_opts="--skip-test-list=${HOME}/tests_exclude"
    [ -f "${log_dir}/mtr.log" ] &&
        mv "${log_dir}/mtr.log" "${log_dir}/"$(date '+mtr_%Y%m%d_%H%M%S.log')
    unset opt_mysqld_silent
    [ -n "$opt_silent" ] &&
        opt_mysqld_silent="--mysqld=$opt_silent"
    unset opt_suite
    if [ $product = mariadb ]
    then
        opt_suite=--suite="main-,archive-,binlog-,csv-,funcs_1-,funcs_2-,gcol-,handler-,heap-,innodb-,innodb_fts-,innodb_gis-,json-,maria-,mariabackup-,multi_source-,optimizer_unfixed_bugs-,parts-,perfschema-,plugins-,roles-,rpl-,sys_vars-,unit-,vcol-,versioning-,period-"
    fi
    unset opt_sql_mode
    if [ $product = mysql ]
    then
        opt_sql_mode="--mysqld=--sql_mode= --mysqld=--innodb_use_native_aio="
        # Use --mysqld=--innodb_use_native_aio=0
        false
    fi
    # Using --mem makes var/ path always different!
    exec $mtr_script \
        --force \
        --max-test-fail=0 \
        --suite-timeout=1440 \
        --retry-failure=1 \
        $opt_mysqld_silent \
        $opt_sql_mode \
        $opt_suite \
        ${mtr_opts} \
        ${exclude_opts} \
        "$@" 2>&1 | tee -a "${log_dir}/mtr.log"
    return $PIPESTATUS
#        --mysqld=--loose-innodb-flush-method=fsync \
#        --suite="main-,archive-,binlog-,client-,csv-,federated-,funcs_1-,funcs_2-,gcol-,handler-,heap-,innodb-,innodb_fts-,innodb_gis-,innodb_i_s-,json-,maria-,mariabackup-,multi_source-,optimizer_unfixed_bugs-,parts-,perfschema-,plugins-,roles-,rpl-,sys_vars-,sql_sequence-,unit-,vcol-,versioning-,period-,sysschema-" \
#        --suite="main-,archive-,binlog-,csv-,federated-,funcs_1-,funcs_2-,gcol-,handler-,heap-,innodb-,innodb_fts-,innodb_gis-,json-,maria-,mariabackup-,multi_source-,optimizer_unfixed_bugs-,parts-,perfschema-,plugins-,roles-,rpl-,sys_vars-,unit-,vcol-,versioning-,period-,sysschema-" \
)}

alias mtrh="mtr --help | less"
alias mtrx="mtr --extern socket=${MYSQL_UNIX_PORT}"
alias mtrx1="mtr --extern socket=${build}/mysql-test/var/tmp/mysqld.1.sock"
alias mtrf="mtr --big-test --fast --parallel=$(nproc)"
alias mtrb="mtrf --big-test"
alias mtrz="mtr --fast --reorder --parallel=$(nproc)"
alias mtrz2="mtr --parallel=$(nproc)"
alias mtrzz="mtrz --debug-sync-timeout=2"
alias mtrm="mtrz --suite=main"
alias mtrv="mtrz --suite=versioning"
alias mtrvv="mtrz --suite=period"
alias mtrg="mtr --no-check --manual-gdb $mtrg_opts"
alias mtrr="mtr --no-check --rr --mysqld=--use-stat-tables=never --mysqld=--innodb_use_native_aio=0"
alias mtrvvg="mtrg --suite=period"
alias mtrvg="mtrg --suite=versioning"
alias mtrp="mtrz --suite=parts"
alias mtrpg="mtrp --manual-gdb"
alias mtri="mtrz --suite=innodb"
alias mtrig="mtri --manual-gdb"
alias myh="mysqld --verbose --help | less"
alias makez="make -j$(nproc)"
alias mtrpd="mtr PERLDB"
alias mtrpg="mtr GDB"
alias mtrpr="mtr RR"

for a in $(alias -p|grep "^alias mtr"|while read a b; do b=${b%%=*}; echo $b; done)
do
    eval alias m$a="\"makez && $a\""
done

commit-tests()
{
    local t=${1:-HEAD}
    shift
    git stat $t| fgrep .result |
    while read a b
    do
        t=${a%%.result}
        t=${t##*/}
        echo $t
    done
}

br()
{(
    a=$1
    shift
    git branch --all --list "*${a}*" "$@" | head -n1
)}

gs()
{(
    cd "$src"
    rgrep "$@" sql storage/innobase
)}

gsl() { gs "$@" | less; }

mtrval()
{
    local supp=~/mtr.supp
    local supp_opt=''
    [ -f "$supp" ] &&
        supp_opt=--valgrind=--suppressions=$supp
    mtr --valgrind=--leak-check=no \
        --valgrind=--track-origins=yes \
        --valgrind=--num-callers=50 \
        --valgrind=--log-file=${log_dir}/badmem.log \
        --mysqld=--debug-assert-on-not-freed-memory=0 \
        $supp_opt \
        "$@"
}


mtrvgdb()
{
    echo 'Use target remote | vgdb'
    local supp=~/mtr.supp
    local supp_opt=''
    [ -f "$supp" ] &&
        supp_opt=--valgrind=--suppressions=$supp
    mtr --valgrind=--vgdb=yes \
        --valgrind=--vgdb-error=0 \
        $supp_opt \
        "$@"
}

mtrleak()
{
    local supp=~/mtr.supp
    local supp_opt=''
    [ -f "$supp" ] &&
        supp_opt=--valgrind=--suppressions=$supp
    mtr --valgrind=--leak-check=full \
        --valgrind=--track-origins=yes \
        --valgrind=--num-callers=50 \
        --valgrind=--log-file=${log_dir}/leak.log \
        $supp_opt \
        "$@"
}


mysql()
{(
    mysql_client=${mysql_client:-$(which mysql)}
    db=${1:-test}
    shift
    [ -x "`which most`" ] &&
        export PAGER=most
    sock=${MYSQL_UNIX_PORT:-"${bush_dir}/run/mysqld.sock"}
    "$mysql_client" -S "$MYSQL_UNIX_PORT" -u root "$db" "$@"
)}


backup()
{(
    mysql_client=$(which mariabackup)
    "$mysql_client" -S "${bush_dir}/run/mysqld.sock" -u root \
        --target-dir=~/tmp/backup "$@"
)}

backupd()
{(
    mysql_client=$(which mariabackup)
    gdb --args "$mysql_client" -S "${bush_dir}/run/mysqld.sock" -u root \
        --target-dir=~/tmp/backup "$@"
)}

# TODO: check on multi-server test (f.ex. spider.versioning)
# Auto-find correct sock if it is only one
mysqlt()
{(
    mysql_client=${mysql_client:-$(which mysql)}
    db=${1:-mtr}
    shift
    [ -x "`which most`" ] &&
        export PAGER=most
    "$mysql_client" -S "${build}/mysql-test/var/tmp/mysqld.1.1.sock" -u root "$db" "$@"
)}


run()
{(
    if [ -n "$1" -a -f "$1" ]
    then
        defaults="$1"
        shift
    else
        cd "${bush_dir}"
        defaults=./mysqld.cnf
    fi
    exec "${opt}/bin/mysqld" "--defaults-file=$defaults" $opt_debug_gdb $opt_silent "$@"
)}
export -f run

runval()
{(
    if [ -n "$1" -a -f "$1" ]
    then
        defaults="$1"
        shift
    else
        cd "${bush_dir}"
        defaults=./mysqld.cnf
    fi
    exec valgrind \
        --leak-check=no \
        --track-origins=yes \
        --log-file=valgrind-badmem.log \
        "${opt}/bin/mysqld" "--defaults-file=$defaults" $opt_debug_gdb $opt_silent "$@"
)}
export -f runval


runht()
{(
    if [ -n "$1" -a -f "$1" ]
    then
        defaults="$1"
        shift
    else
        cd "${bush_dir}"
        defaults=./mysqld.cnf
    fi
    exec heaptrack \
        "${opt}/bin/mysqld" "--defaults-file=$defaults" $opt_debug_gdb $opt_silent "$@"
)}
export -f runht

rund()
{(
    if [ "$1" = -start ]
    then
        opt_run="-ex start"
        shift
    else
        opt_run="-ex run"
    fi
    if [ -n "$1" -a -f "$1" ]
    then
        defaults="$1"
        shift
    else
        cd "${bush_dir}"
        defaults=./mysqld.cnf
    fi
    unset opt_plugins
    if [ $product = mariadb ]
    then
        opt_plugins="--plugin-maturity=experimental --plugin-load=test_versioning"
    fi
    exec gdb -q $opt_run --args "${opt}/bin/mysqld" "--defaults-file=$defaults" $opt_plugins $opt_debug_gdb "$@"
)}
export -f rund

runt()
{(
    cd "${src}/mysql-test"
    suffix=${1:-1}
    shift
    exec gdb -q --args "${opt}/bin/mysqld" --defaults-group-suffix=.$suffix --defaults-file=${build}/mysql-test/var/my.cnf --log-output=file --gdb --core-file --loose-debug-sync-timeout=300 --debug $opt_debug_gdb "$@"
)}
export -f runt

runrr()
{(
    if [ -n "$1" -a -f "$1" ]
    then
        defaults="$1"
        shift
    else
        cd "${bush_dir}"
        defaults=./mysqld.cnf
    fi
    unset opt_plugins
    if [ $product = mariadb ]
    then
        opt_plugins="--plugin-maturity=experimental --plugin-load=test_versioning"
    fi
    exec rr record "${opt}/bin/mysqld" "--defaults-file=$defaults" $opt_plugins $opt_debug_gdb $opt_silent "$@"
)}
export -f runrr


binlog()
{(
    local run_gdb=""
    if [ "$1" = "-gdb" ]
    then
        run_gdb="gdb -q -ex run --args"
        shift
    fi

    local log_file=""
    [[ "$1" ]] ||
      log_file="${build}/mysql-test/var/mysqld.1/data/master-bin.000001"

    exec $run_gdb "${opt}/bin/mysqlbinlog" "--defaults-file=${defaults}" \
        --local-load="${build}/var/tmp" -v --base64-output=DECODE-ROWS "$@" $log_file
)}
export -f binlog

dump()
{(
    local run_gdb=""
    if [ "$1" = "-gdb" ]
    then
        run_gdb="gdb -q -ex run --args"
        shift
    fi
    db=${1:-test}
    shift
    exec $run_gdb "$(which mysqldump)" "--defaults-file=${defaults}" -u root "$db" "$@"
)}
export -f dump

admin()
{(
    local run_gdb=""
    if [ "$1" = "-gdb" ]
    then
        run_gdb="gdb -q -ex run --args"
        shift
    fi
    cmd=${1:-status}
    shift
    exec $run_gdb "$(which mysqladmin)" "--defaults-file=${defaults}" -u root "$cmd" "$@"
)}
export -f admin

bench()
{(
    if [ "$1" = "drop" ]; then
        mysql <<< "drop database sbtest"
        exit
    elif [ "$1" = "create" ]; then
        mysql <<< "create or replace database sbtest"
        exit
    elif [ "$1" = ls ]; then
        find /usr/share/sysbench/ -type f
        exit
    fi
    if [[ "$1" == /usr/share/sysbench/* ]]; then
        plan="$1"
        shift
    else
        plan=/usr/share/sysbench/oltp_insert.lua
    fi
    cmd=${1:-run}
    shift
    if [ "$cmd" = "fullest" ]; then
        bench create
        bench "$plan" full
        exit
    elif [ "$cmd" = "full" ]; then
        bench "$plan" prepare
        bench "$plan" run
        exit
    fi
    "$(which sysbench)" --mysql-socket=$MYSQL_UNIX_PORT --mysql-user=root --time=3 "$plan" "$cmd" "$@"
)}
export -f bench

gdbt()
{(
    suffix=${1:-1}
    exec gdb -q -cd "${src}/mysql-test" -x "${build}/mysql-test/var/tmp/gdbinit.mysqld.${suffix}" -ex run "${build}/sql/mysqld"
)}
export -f gdbt

initdb()
{(
    data=${1:-./data}
    if [ -z "$1" ]
    then
        cd "${bush_dir}"
        mkdir -p run
        defaults=./mysqld.cnf
    fi
    data=$(readlink -f "${data}")
    if [ -e "${data}" ]
    then
        echo "${data} already exists!" >&2
        exit 100
    fi
    if [ $product = mariadb ]
    then
        mkdir -p "${data}"
        ln -s "${bush_dir}/run" "${data}/run"
        mysql_install_db --basedir="${opt}" --datadir="${data}" --defaults-file="${defaults}" --auth-root-authentication-method=normal
    else
        mysqld --initialize-insecure --basedir="${opt}" --datadir="${data}"
        ln -s "${bush_dir}/run" "${data}/run"
    fi
)}
export -f initdb

alias rmdb='rm -rf "$bush_dir/data"'

attach()
{
    gdb-attach ${build}/mariadbd
}

breaks()
{
    while read place text
    do
        place=$(basename "${place%:}")
        echo "# ${text}"
        echo "b $place"
        if [ "$1" ]
        then
            echo "commands"
            echo "    $1"
            echo "end"
        fi
    done
}

# Use like: master rund [args]
# Then master_setup (once)
master()
{
    local cmd=$1
    shift
    $cmd --log_bin=binlog --binlog_format=ROW --max_connections=10000 --server_id=1 "$@"
}

master_setup()
{
mysql <<-EOF
	DELETE FROM mysql.user WHERE user='';
	GRANT REPLICATION SLAVE ON *.* TO 'repl_user'@'%' IDENTIFIED BY 'repl_pass';
	FLUSH PRIVILEGES;
EOF
}

# Use like: slave rund [args]
# Then slave_setup port_number (once)
slave()
{
    local cmd=$1
    shift
    $cmd --max_connections=10000 --server_id=2 "$@"
}

slave_setup()
{
mysql<<-EOF
	CHANGE MASTER TO MASTER_HOST='127.0.0.1', MASTER_PORT=$1, MASTER_USER='repl_user', MASTER_PASSWORD='repl_pass', MASTER_USE_GTID=slave_pos;
	START SLAVE;
EOF
}


asan_opts=-DWITH_ASAN:BOOL=ON
msan_opts=-DWITH_MSAN:BOOL=ON
export debug_opts="-g -O0 -DEXTRA_DEBUG -Werror=return-type -Wno-error=unused-variable -Wno-error=unused-function -Wno-unused-but-set-variable -Wno-deprecated-declarations -Wno-frame-larger-than"
export debug_opts_clang="-gdwarf-4 -fno-limit-debug-info -Wno-error=macro-redefined -Werror=overloaded-virtual -Wno-deprecated-register -Wno-inconsistent-missing-override -Wno-deprecated-literal-operator -Wno-nontrivial-memcall -Wno-deprecated-non-prototype"
export debug_opts_linker=""
# FIXME: detect lld version for -Wl,--threads
export linker_opts_clang="-fuse-ld=lld -Wl,--image-base=0x140000000 -Wl,--threads=24"
# FIXME: implement common_opts and common_opts_gcc
export common_opts="-Wno-deprecated-declarations -Wno-deprecated-literal-operator -Wno-nontrivial-memcall"
export common_opts_gcc="-Wa,-mbranches-within-32B-boundaries"
export common_opts_clang="-mbranches-within-32B-boundaries -Wno-unused-command-line-argument -Wno-deprecated-non-prototype"

conf()
{(
    mkdir -p "${build}"
    cd "${build}"
    ccmake "$@" "${src}"
)}

cmake()
{(
    mkdir -p "${build}"
    cd "${build}"
    local opts=""
    if [[ "$CMAKE_LDFLAGS" ]]; then
        local ldflags="${profile_flags}${profile_flags:+ }$CMAKE_LDFLAGS"
        opts=$(echo \
          -DCMAKE_EXE_LINKER_FLAGS:STRING=\"$ldflags\" \
          -DCMAKE_MODULE_LINKER_FLAGS:STRING=\"$ldflags\" \
          -DCMAKE_SHARED_LINKER_FLAGS:STRING=\"$ldflags\")
    fi
    eval $(which cmake-ln) $opts \"\$@\" \"${src}\"
)}

### New prepare development BEGIN

die()
{
    [ -n "$1" ] && echo "$1" >&2;
    if [[ $_ != $0 ]]
    then
        while true; do kill -SIGINT -$$; sleep 700d; done
    else
        exit 1
    fi
}

die2()
{
    [ -n "$1" ] && echo "$1" >&2;
    exit 1
}
export -f die2

opt_matches()
{
    # From -DSECURITY_HARDENED:BOOL=FALSE get SECURITY_HARDENED
    local match_D_opt='^[[:space:]]*-D[[:space:]]*([^:=]+)'
    if [[ "$1" =~ $match_D_opt ]]
    then
        local rematch=("${BASH_REMATCH[@]}")
        if [[ "$2" =~ $match_D_opt ]]
        then
            [ "${rematch[1]}" = "${BASH_REMATCH[1]}" ]
            return
        fi
    fi
    [ "$1" = "$2" ]
}

prepare_add()
{
    local name=$1
    local opt=$2
    [ -z "$name" ] &&
        die "Config name required!"
    [ -z "$opt" ] &&
        die "CMake option required!"
    declare -gA cmake_config
    local conf
    for f in ${cmake_config[$name]}
    do
        if [ -n "$opt" ] && opt_matches $f $opt
        then
            conf="${conf:+$conf }$opt"
            unset opt
        else
            conf="${conf:+$conf }$f"
        fi
    done
    cmake_config[$name]="${conf:+$conf }$opt"
}

show_config()
{
    local name=$1
    [ -z "$name" ] &&
        die "Config name required!"
    for f in ${cmake_config[$name]}
    do
        echo "$f "
    done
}

prepare_config()
{
    local name=$1
    [ -z "$name" ] &&
        die "Config name required!"
    unset cmake_config[$name]
    while read -r
    do
        local s=${REPLY% \\}
        s=${s%${s##*[![:space:]]}} # trim trailing space
        s=${s#${s%%[![:space:]]*}} # trim beginning space
        prepare_add $name $s
    done
}

test_prepare_config()
{
    prepare_config debug <<"EOF"
        -DSECURITY_HARDENED:BOOL=FALSE \
        -DMYSQL_MAINTAINER_MODE:STRING=OFF \
        -DUPDATE_SUBMODULES:BOOL=OFF \
        -DPLUGIN_METADATA_LOCK_INFO:STRING=STATIC \
        -DWITH_UNIT_TESTS:BOOL=OFF \
        -DWITH_CSV_STORAGE_ENGINE:BOOL=OFF \
        -DWITH_WSREP:BOOL=OFF \
        -DWITH_MARIABACKUP:BOOL=OFF \
        -DWITH_SAFEMALLOC:BOOL=OFF \
        -DWITHOUT_ABI_CHECK:BOOL=OFF
EOF
    show_config debug
    return
    prepare_config sn <<"EOF"
        -DSECURITY_HARDENED:BOOL=OFF \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
        -DDISABLE_SHARED:BOOL=OFF \
        -DMYSQL_MAINTAINER_MODE:STRING=NO \
        -DCONC_WITH_DYNCOL=NO \
        -DCONC_WITH_EXTERNAL_ZLIB=NO \
        -DCONC_WITH_MYSQLCOMPAT=NO \
        -DCONC_WITH_UNIT_TESTS=NO \
        -DENABLED_PROFILING=NO \
        -DENABLE_DTRACE=NO \
        -DGSSAPI_FOUND=FALSE \
        -DMAX_INDEXES=128 \
        -DMUTEXTYPE=futex \
        -DPLUGIN_ARCHIVE=NO \
        -DPLUGIN_AUDIT_NULL=NO \
        -DPLUGIN_AUTH_0X0100=NO \
        -DPLUGIN_AUTH_ED25519=NO \
        -DPLUGIN_AUTH_GSSAPI=NO \
        -DPLUGIN_AUTH_PAM_V1=NO \
        -DPLUGIN_AUTH_SOCKET=NO \
        -DPLUGIN_AUTH_TEST_PLUGIN=NO \
        -DPLUGIN_BLACKHOLE=NO \
        -DPLUGIN_CRACKLIB_PASSWORD_CHECK=NO \
        -DPLUGIN_DAEMON_EXAMPLE=NO \
        -DPLUGIN_DEBUG_KEY_MANAGEMENT=NO \
        -DPLUGIN_DIALOG_EXAMPLES=NO \
        -DPLUGIN_DISKS=NO \
        -DPLUGIN_EXAMPLE=NO \
        -DPLUGIN_EXAMPLE_KEY_MANAGEMENT=NO \
        -DPLUGIN_FEDERATED=NO \
        -DPLUGIN_FEDERATEDX=NO \
        -DPLUGIN_FEEDBACK=NO \
        -DPLUGIN_FILE_KEY_MANAGEMENT=NO \
        -DPLUGIN_FTEXAMPLE=NO \
        -DPLUGIN_HANDLERSOCKET=NO \
        -DPLUGIN_LOCALES=NO \
        -DPLUGIN_METADATA_LOCK_INFO=NO \
        -DPLUGIN_OQGRAPH=NO \
        -DPLUGIN_PERFSCHEMA=NO \
        -DPLUGIN_QA_AUTH_CLIENT=NO \
        -DPLUGIN_QA_AUTH_INTERFACE=NO \
        -DPLUGIN_QA_AUTH_SERVER=NO \
        -DPLUGIN_QUERY_CACHE_INFO=NO \
        -DPLUGIN_QUERY_RESPONSE_TIME=NO \
        -DPLUGIN_SEMISYNC_MASTER=NO \
        -DPLUGIN_SEMISYNC_SLAVE=NO \
        -DPLUGIN_SEQUENCE=NO \
        -DPLUGIN_SERVER_AUDIT=NO \
        -DPLUGIN_SIMPLE_PASSWORD_CHECK=NO \
        -DPLUGIN_SQL_ERRLOG=NO \
        -DPLUGIN_TEST_SQL_DISCOVERY=NO \
        -DPLUGIN_TEST_VERSIONING=NO \
        -DPLUGIN_USER_VARIABLES=NO \
        -DUPDATE_SUBMODULES=OFF \
        -DUSE_ARIA_FOR_TMP_TABLES=OFF \
        -DWITH_CSV_STORAGE_ENGINE=OFF \
        -DWITH_DBUG_TRACE=OFF \
        -DWITH_EXTRA_CHARSETS=none \
        -DWITH_INNODB_AHI=OFF \
        -DWITH_INNODB_BZIP2=OFF \
        -DWITH_INNODB_LZ4=OFF \
        -DWITH_INNODB_LZMA=OFF \
        -DWITH_INNODB_LZO=OFF \
        -DWITH_INNODB_ROOT_GUESS=OFF \
        -DWITH_INNODB_SNAPPY=OFF \
        -DWITH_MARIABACKUP=ON \
        -DWITH_NUMA=OFF \
        -DWITH_PCRE=bundled \
        -DWITH_SAFEMALLOC=OFF \
        -DWITH_SYSTEMD=no \
        -DWITH_UNIT_TESTS=OFF \
        -DWITH_WSREP:BOOL=OFF \
        -DWITH_ZLIB=bundled \
EOF
}

### New prepare development END

# Usage:
# your_array=()
# push_back your_array value1 [value2] ...
# echo "${your_array[@]}"
push_back()
{
    arr=$1; shift
    for val in "$@"
    do
        eval $arr[\${#$arr[@]}]=\$val
    done
}
export -f push_back

get_linker_flags()
{
    local suffix=${1:+_${1}}
    shift
    local opts=${1:+="$*"}
    [ -z "$opts" ] &&
        return
    for f in CMAKE_EXE_LINKER_FLAGS \
             CMAKE_SHARED_LINKER_FLAGS \
             CMAKE_MODULE_LINKER_FLAGS
    do
        push_back cmake_flags "-D${f}${suffix^^}:STRING${opts}"
    done
}
export -f get_linker_flags

prepare()
{(
    mkdir -p "${build}"
    cd "${build}"
    unset plugins
    if [ -f ~/plugin_exclude ]
    then
        while read a b
        do
            [ -n "$a" ] &&
                plugins="$plugins -D$a=NO"
        done < ~/plugin_exclude
    fi
    unset compiler_flags
    cmake_flags=()
    [ -f ~/compiler_flags ] &&
        compiler_flags="$(cat ~/compiler_flags)"
    [ -f $build/compiler_flags ] &&
        compiler_flags="${compiler_flags} $(cat $build/compiler_flags)"
    if [ $product = mysql ]; then
        # FIXME: only clang flags
        # -Wno-enum-constexpr-conversion
        # -Wno-deprecated-copy-with-user-provided-copy
        # -Wno-reserved-user-defined-literal
        # -Wno-c++11-narrowing
        # -Wno-enum-constexpr-conversion
        # -Wno-deprecated-copy-with-user-provided-copy
        # -Wno-reserved-user-defined-literal
        # -Wno-c++11-narrowing
        #
        # FIXME:
        # command-line option ‘-Wno-register’ is valid for C++/ObjC++ but not for C
        # compiler_flags="${compiler_flags} -w -Wno-c++11-narrowing -Wno-reserved-user-defined-literal -Wno-deprecated-copy-with-user-provided-copy -Wno-register -Wno-enum-constexpr-conversion"
        # WITH_BOOST is relative to build dir, make it common for all builds
        push_back cmake_flags -DDOWNLOAD_BOOST=1 -DWITH_BOOST=..
    fi
    compiler_flags="$(echo $compiler_flags)"
    unset profile_flags
    if [ -f ~/profile_flags ]
    then
        profile_flags="$(cat ~/profile_flags)"
        profile_flags="$(echo $profile_flags)"
    fi
    # TODO: merge cclauncher into cmake_flags?
    cclauncher="-DCMAKE_CXX_COMPILER_LAUNCHER= -DCMAKE_C_COMPILER_LAUNCHER="
    [ -x $(which ccache) ] &&
        cclauncher="-DCMAKE_CXX_COMPILER_LAUNCHER=ccache -DCMAKE_C_COMPILER_LAUNCHER=ccache"
    [ $product = mysql ] &&
        cclauncher="${cclauncher} -DWITH_SASL=no -DWITH_FIDO=none -DWITH_BUNDLED_LIBEVENT:BOOL=OFF -D WITH_BUNDLED_MEMCACHED:BOOL=OFF -DWITH_EMBEDDED_SERVER:BOOL=OFF -DWITH_EMBEDDED_SHARED_LIBRARY:BOOL=OFF -DWITH_HYPERGRAPH_OPTIMIZER:BOOL=OFF -DWITH_NDBAPI_EXAMPLES:BOOL=OFF -DWITH_NDBCLUSTER_STORAGE_ENGINE:BOOL=OFF -DWITH_NDBMTD:BOOL=OFF -DWITH_NDB_BINLOG:BOOL=OFF -DWITH_NDB_NODEJS:BOOL=OFF -DWITH_NDB_TEST:BOOL=OFF -DWITH_ROUTER:BOOL=OFF"
    # TODO: add DISABLE_PSI_FILE
    flavor_safe=${flavor//[^a-zA-Z0-9_]/_}
    eval flavor_opts=\$${flavor_safe}_opts
    get_linker_flags debug $debug_opts_linker

    cmake-ln -Wno-dev \
        -DCMAKE_INSTALL_PREFIX:STRING=${opt} \
        -DCMAKE_BUILD_TYPE:STRING=Debug \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
        -DCMAKE_CXX_FLAGS_DEBUG:STRING="$debug_opts $compiler_flags $profile_flags" \
        -DCMAKE_C_FLAGS_DEBUG:STRING="$debug_opts $compiler_flags $profile_flags" \
        -DCMAKE_ASM_FLAGS_DEBUG:STRING="$debug_opts $compiler_flags $profile_flags" \
        -DCMAKE_CXX_FLAGS:STRING="$compiler_flags $profile_flags $CMAKE_C_FLAGS $CMAKE_CXX_FLAGS" \
        -DCMAKE_C_FLAGS:STRING="$compiler_flags $profile_flags $CMAKE_C_FLAGS" \
        -DCMAKE_ASM_FLAGS:STRING="$compiler_flags $profile_flags" \
        -DCMAKE_EXE_LINKER_FLAGS:STRING="$profile_flags $CMAKE_LDFLAGS" \
        -DCMAKE_MODULE_LINKER_FLAGS:STRING="$profile_flags $CMAKE_LDFLAGS" \
        -DCMAKE_SHARED_LINKER_FLAGS:STRING="$profile_flags $CMAKE_LDFLAGS" \
        -DSTACK_DIRECTION=-1 \
        -DWITHOUT_ABI_CHECK=YES \
        -DENABLED_PROFILING=NO \
        -DENABLE_DTRACE=NO \
        -DSECURITY_HARDENED:BOOL=FALSE \
        -DMYSQL_MAINTAINER_MODE:STRING=OFF \
        -DUPDATE_SUBMODULES:BOOL=OFF \
        -DPLUGIN_METADATA_LOCK_INFO:STRING=STATIC \
        -DWITH_UNIT_TESTS:BOOL=OFF \
        -DWITH_CSV_STORAGE_ENGINE:BOOL=OFF \
        -DWITH_WSREP:BOOL=OFF \
        -DWITH_MARIABACKUP:BOOL=OFF \
        -DWITH_READLINE:BOOL=ON \
        -DWITH_SAFEMALLOC:BOOL=OFF \
        -DWITHOUT_ABI_CHECK:BOOL=ON \
        `# some older versions fail bootstrap on MD5 without SSL bundled` \
        -DWITH_SSL=$(for_mariadb bundled system) \
        "${cmake_flags[@]}" \
        $flavor_opts \
        $cclauncher \
        $plugins \
        "$@" \
        "${src}"
)}
export -f prepare

prepare_sn()
{(
    mkdir -p "${build}"
    cd "${build}"
    unset plugins
    if [ -f ~/plugin_exclude ]
    then
        while read a b
        do
            [ -n "$a" ] &&
                plugins="$plugins -D$a=NO"
        done < ~/plugin_exclude
    fi
    unset compiler_flags
    if [ -f ~/compiler_flags ]
    then
        compiler_flags="$(cat ~/compiler_flags)"
        compiler_flags="$(echo $compiler_flags)"
    fi
    unset profile_flags
    if [ -f ~/profile_flags ]
    then
        profile_flags="$(cat ~/profile_flags)"
        profile_flags="$(echo $profile_flags)"
    fi
    cclauncher="-DCMAKE_CXX_COMPILER_LAUNCHER= -DCMAKE_C_COMPILER_LAUNCHER="
    if [ -x $(which ccache) ]
    then
       cclauncher="-DCMAKE_CXX_COMPILER_LAUNCHER=ccache -DCMAKE_C_COMPILER_LAUNCHER=ccache"
    fi
    # TODO: add DISABLE_PSI_FILE
    #
    # Note: SECURITY_HARDENED or MYSQL_MAINTAINER_MODE?
    # profile_flags="$profile_flags"
    compiler_flags="-Wa,-mbranches-within-32B-boundaries $compiler_flags"
    eval flavor_opts=\$${flavor}_opts
    # Disables ccache
    #    -DCMAKE_C_COMPILER:FILEPATH=/usr/bin/gcc \
    #    -DCMAKE_CXX_COMPILER:FILEPATH=/usr/bin/g++ \

    # This influences the build
    #    -DSECURITY_HARDENED:BOOL=ON \

    cmake-ln -Wno-dev \
        -DBUILD_CONFIG:STRING=mysql_release \
        -DCMAKE_INSTALL_PREFIX:STRING=${opt} \
        -DCMAKE_BUILD_TYPE:STRING=Release \
        -DCMAKE_CXX_FLAGS:STRING="-g -O3 $compiler_flags $profile_flags $CMAKE_C_FLAGS $CMAKE_CXX_FLAGS" \
        -DCMAKE_C_FLAGS:STRING="-g -O3 $compiler_flags $profile_flags $CMAKE_C_FLAGS" \
        -DCMAKE_ASM_FLAGS:STRING="-g -O3 $compiler_flags $profile_flags" \
        -DCMAKE_EXE_LINKER_FLAGS:STRING="-z relro -z now $profile_flags $CMAKE_LDFLAGS" \
        -DCMAKE_MODULE_LINKER_FLAGS:STRING="-z relro -z now $profile_flags $CMAKE_LDFLAGS" \
        -DCMAKE_SHARED_LINKER_FLAGS:STRING="-z relro -z now $profile_flags $CMAKE_LDFLAGS" \
        -DSECURITY_HARDENED:BOOL=OFF \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
        -DDISABLE_SHARED:BOOL=OFF \
        -DMYSQL_MAINTAINER_MODE:STRING=NO \
        -DCONC_WITH_DYNCOL=NO \
        -DCONC_WITH_EXTERNAL_ZLIB=NO \
        -DCONC_WITH_MYSQLCOMPAT=NO \
        -DCONC_WITH_UNIT_TESTS=NO \
        -DENABLED_PROFILING=NO \
        -DENABLE_DTRACE=NO \
        -DGSSAPI_FOUND=FALSE \
        -DMAX_INDEXES=128 \
        -DMUTEXTYPE=futex \
        -DPLUGIN_ARCHIVE=NO \
        -DPLUGIN_AUDIT_NULL=NO \
        -DPLUGIN_AUTH_0X0100=NO \
        -DPLUGIN_AUTH_ED25519=NO \
        -DPLUGIN_AUTH_GSSAPI=NO \
        -DPLUGIN_AUTH_PAM_V1=NO \
        -DPLUGIN_AUTH_SOCKET=NO \
        -DPLUGIN_AUTH_TEST_PLUGIN=NO \
        -DPLUGIN_BLACKHOLE=NO \
        -DPLUGIN_CRACKLIB_PASSWORD_CHECK=NO \
        -DPLUGIN_DAEMON_EXAMPLE=NO \
        -DPLUGIN_DEBUG_KEY_MANAGEMENT=NO \
        -DPLUGIN_DIALOG_EXAMPLES=NO \
        -DPLUGIN_DISKS=NO \
        -DPLUGIN_EXAMPLE=NO \
        -DPLUGIN_EXAMPLE_KEY_MANAGEMENT=NO \
        -DPLUGIN_FEDERATED=NO \
        -DPLUGIN_FEDERATEDX=NO \
        -DPLUGIN_FEEDBACK=NO \
        -DPLUGIN_FILE_KEY_MANAGEMENT=NO \
        -DPLUGIN_FTEXAMPLE=NO \
        -DPLUGIN_HANDLERSOCKET=NO \
        -DPLUGIN_LOCALES=NO \
        -DPLUGIN_METADATA_LOCK_INFO=NO \
        -DPLUGIN_OQGRAPH=NO \
        -DPLUGIN_PERFSCHEMA=NO \
        -DPLUGIN_QA_AUTH_CLIENT=NO \
        -DPLUGIN_QA_AUTH_INTERFACE=NO \
        -DPLUGIN_QA_AUTH_SERVER=NO \
        -DPLUGIN_QUERY_CACHE_INFO=NO \
        -DPLUGIN_QUERY_RESPONSE_TIME=NO \
        -DPLUGIN_SEMISYNC_MASTER=NO \
        -DPLUGIN_SEMISYNC_SLAVE=NO \
        -DPLUGIN_SEQUENCE=NO \
        -DPLUGIN_SERVER_AUDIT=NO \
        -DPLUGIN_SIMPLE_PASSWORD_CHECK=NO \
        -DPLUGIN_SQL_ERRLOG=NO \
        -DPLUGIN_TEST_SQL_DISCOVERY=NO \
        -DPLUGIN_TEST_VERSIONING=NO \
        -DPLUGIN_USER_VARIABLES=NO \
        -DUPDATE_SUBMODULES=OFF \
        -DUSE_ARIA_FOR_TMP_TABLES=OFF \
        -DWITH_CSV_STORAGE_ENGINE=OFF \
        -DWITH_DBUG_TRACE=OFF \
        -DWITH_EXTRA_CHARSETS=none \
        -DWITH_INNODB_AHI=OFF \
        -DWITH_INNODB_BZIP2=OFF \
        -DWITH_INNODB_LZ4=OFF \
        -DWITH_INNODB_LZMA=OFF \
        -DWITH_INNODB_LZO=OFF \
        -DWITH_INNODB_ROOT_GUESS=OFF \
        -DWITH_INNODB_SNAPPY=OFF \
        -DWITH_MARIABACKUP=ON \
        -DWITH_NUMA=OFF \
        -DWITH_PCRE=bundled \
        -DWITH_SAFEMALLOC=OFF \
        -DWITH_SYSTEMD=no \
        -DWITH_UNIT_TESTS=OFF \
        -DWITH_WSREP:BOOL=OFF \
        -DWITH_ZLIB=bundled \
        -DWITHOUT_ABI_CHECK=ON \
        $flavor_opts \
        $cclauncher \
        $plugins \
        "$@" \
        "${src}"
)}
export -f prepare_sn

prepare_snow()
{(
    mkdir -p "${build}"
    cd "${build}"
    unset plugins
    if [ -f ~/plugin_exclude ]
    then
        while read a b
        do
            [ -n "$a" ] &&
                plugins="$plugins -D$a=NO"
        done < ~/plugin_exclude
    fi
    unset compiler_flags
    if [ -f ~/compiler_flags ]
    then
        compiler_flags="$(cat ~/compiler_flags)"
        compiler_flags="$(echo $compiler_flags)"
    fi
    unset profile_flags
    if [ -f ~/profile_flags ]
    then
        profile_flags="$(cat ~/profile_flags)"
        profile_flags="$(echo $profile_flags)"
    fi
    cclauncher="-DCMAKE_CXX_COMPILER_LAUNCHER= -DCMAKE_C_COMPILER_LAUNCHER="
    if [ -x $(which ccache) ]
    then
       cclauncher="-DCMAKE_CXX_COMPILER_LAUNCHER=ccache -DCMAKE_C_COMPILER_LAUNCHER=ccache"
    fi
    # TODO: add DISABLE_PSI_FILE
    #
    # Note: SECURITY_HARDENED or MYSQL_MAINTAINER_MODE?
    # profile_flags="$profile_flags"
    eval flavor_opts=\$${flavor}_opts
    # Disables ccache
    #    -DCMAKE_C_COMPILER:FILEPATH=/usr/bin/gcc \
    #    -DCMAKE_CXX_COMPILER:FILEPATH=/usr/bin/g++ \

    # This influences the build
    #    -DSECURITY_HARDENED:BOOL=ON \

    if [ -z "$build_config" ]
    then
        if [ -f "${src}/cmake/build_configurations/shogun.cmake" ]
        then
            build_config=shogun
        else
            build_config=mysql_release
        fi
    fi

    echo "Build config: $build_config"

    cmake-ln -Wno-dev \
        -DCMAKE_INSTALL_PREFIX:STRING=${opt} \
        -DBUILD_CONFIG=$build_config \
        -DCMAKE_CXX_FLAGS:STRING="$compiler_flags $profile_flags $CMAKE_C_FLAGS $CMAKE_CXX_FLAGS" \
        -DCMAKE_C_FLAGS:STRING="$compiler_flags $profile_flags $CMAKE_C_FLAGS" \
        -DCMAKE_ASM_FLAGS_DEBUG:STRING="$compiler_flags $profile_flags" \
        -DCMAKE_EXE_LINKER_FLAGS:STRING="$profile_flags $CMAKE_LDFLAGS" \
        -DCMAKE_MODULE_LINKER_FLAGS:STRING="$profile_flags $CMAKE_LDFLAGS" \
        -DCMAKE_SHARED_LINKER_FLAGS:STRING="$profile_flags $CMAKE_LDFLAGS" \
        $flavor_opts \
        $cclauncher \
        $plugins \
        "$@" \
        "${src}"
)}
export -f prepare_snow

prepare_strict()
{(
    mkdir -p "${build}"
    cd "${build}"
    unset cclauncher
    if [ -x $(which ccache) ]
    then
        cclauncher="-DCMAKE_CXX_COMPILER_LAUNCHER=ccache -DCMAKE_C_COMPILER_LAUNCHER=ccache"
    fi
    cmake-ln -Wno-dev \
        -DCMAKE_INSTALL_PREFIX:STRING=${opt} \
        -DCMAKE_BUILD_TYPE:STRING=Debug \
        -DCMAKE_CXX_FLAGS_DEBUG:STRING="-g -O0 -Werror=overloaded-virtual -Werror=return-type" \
        -DCMAKE_C_FLAGS_DEBUG:STRING="-g -O0 -Werror=return-type" \
        -DSECURITY_HARDENED:BOOL=FALSE \
        -DWITH_UNIT_TESTS:BOOL=OFF \
        -DWITH_CSV_STORAGE_ENGINE:BOOL=OFF \
        -DWITH_WSREP:BOOL=OFF \
        -DWITH_MARIABACKUP:BOOL=OFF \
        -DWITH_SAFEMALLOC:BOOL=OFF \
        -DMYSQL_MAINTAINER_MODE:STRING=ON \
        $cclauncher \
        "$@" \
        "${src}"
)}
export -f prepare_strict

rel_opts()
{
    [ "$(flavor)" = default ] &&
        flavor rel
(
    export CMAKE_C_FLAGS="${CMAKE_C_FLAGS:+$CMAKE_C_FLAGS }-fomit-frame-pointer"
    export CMAKE_CXX_FLAGS="${CMAKE_CXX_FLAGS:+$CMAKE_CXX_FLAGS }-fomit-frame-pointer"

    cmd="$1"
    shift
    "$cmd" \
        "$@" \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DBUILD_CONFIG:STRING=mysql_release \
        -DWITH_JEMALLOC:BOOL=OFF \
        -DCOMMON_C_FLAGS:STRING="${CMAKE_C_FLAGS}" \
        -DCOMMON_CXX_FLAGS:STRING="${CMAKE_CXX_FLAGS}" \
        -DSECURITY_HARDENED:BOOL=FALSE
)}
export -f rel_opts

### TODO: split Ninja and Clang, build Debug/Release with GCC/Clang with Ninja/Make
clang_opts()
{(
    cmd="$1"
    # FIXME: detect clang version and add -fdebug-macro
    export CMAKE_C_FLAGS="${CMAKE_C_FLAGS:+$CMAKE_C_FLAGS }${debug_opts_clang:+$debug_opts_clang }${common_opts_clang:+$common_opts_clang }"
    export CMAKE_CXX_FLAGS="${CMAKE_CXX_FLAGS:+$CMAKE_CXX_FLAGS }${debug_opts_clang:+$debug_opts_clang }${common_opts_clang:+$common_opts_clang }"
    export CMAKE_LDFLAGS="${CMAKE_LDFLAGS:+$CMAKE_LDFLAGS }${linker_opts_clang:+$linker_opts_clang }${debug_opts_clang:+$debug_opts_clang }"
    #libc_home=/usr/lib/llvm-14
    #export CFLAGS="${CFLAGS:+ $CFLAGS}-fdebug-macro -stdlib=libc++ -I${libc_home}/include/c++/v1 -L${libc_home}/lib -Wl,-rpath,${libc_home}/lib"
    shift
    "$cmd" \
        "$@" \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DCOMMON_C_FLAGS:STRING="${CMAKE_C_FLAGS}" \
        -DCOMMON_CXX_FLAGS:STRING="${CMAKE_CXX_FLAGS}" \
        -D_CMAKE_TOOLCHAIN_PREFIX=llvm-
        # TODO: for GCC
        # -Wa,-mbranches-within-32B-boundaries
)}
export -f clang_opts

ninja_opts()
{(
    cmd="$1"
    shift
    "$cmd" \
        "$@" \
        -GNinja
)}
export -f ninja_opts

alias ninja_clang_opts="ninja_opts clang_opts"

emb_opts()
{
    cmd="$1"
    shift
    "$cmd" \
        "$@" \
        -DWITH_UNIT_TESTS:BOOL=ON \
        -DWITH_CSV_STORAGE_ENGINE:BOOL=ON \
        -DWITH_WSREP:BOOL=OFF \
        -DWITH_EMBEDDED_SERVER:BOOL=ON
}
export -f emb_opts

o1_opts()
{(
    build="${build}"
    cmd="$1"
    shift
    "$cmd" \
        "$@" \
        -DCMAKE_CXX_FLAGS_DEBUG:STRING="-g -O1" \
        -DCMAKE_C_FLAGS_DEBUG:STRING="-g -O1"
)}
export -f o1_opts


alias nprepare="ninja_opts prepare"
alias nprepare2="ninja_opts prepare_sn"
alias nprepare3="ninja_opts prepare_snow"
alias clprepare="ninja_clang_opts prepare"
alias o1prepare="ninja_opts o1_opts prepare"
alias embprepare="emb_opts prepare"
# rel_opts musts be first as it updates $build and $opt
alias relprepare="rel_opts prepare_strict"
alias nrelprepare="rel_opts ninja_opts prepare"
alias clrelprepare="rel_opts ninja_opts clang_opts prepare"

relcheck()
{(
    set -e
    echo "*** Checking release build..."
    relprepare
    cd "${build}-rel"
    /usr/bin/make -j4
    echo "*** Checking minimal build..."
    sed -ie '/^PLUGIN_/ s/^\(.*\)=.*/\1=NO/' CMakeCache.txt
    cmake "$src"
    /usr/bin/make -j4
    echo "*** All checks are successful!"
    rm -rf "${build}-rel"
)}

cmakemin()
{
    cmake-ln \
        -D CMAKE_INSTALL_PREFIX:STRING=${opt} \
        "$@"
}


git()
{
    if [ "$1" = clone ] || $(which git) rev-parse &> /dev/null
    then
        $(which git) "$@"
    else (
        cd "$src"
        $(which git) "$@"
    )
    fi
}
export -f git

_run_exe()
{
    exe=$(which "$1")
    if [ -z "$exe" ]
    then
        echo "'$1' is not installed!" >&2
        return 1
    fi
    shift
    "$exe" "$@"
}
export -f _run_exe

make()
{
    recurse="$1"
    if [ "$recurse" = norecurse ]
    then
        shift
    fi
    if [ -f Makefile ]
    then
        # TODO: BUILD_TYPE, MSAN, UBSAN, SECURITY_HARDENED, WSREP, SSL, PCRE
        echo "ASAN: $(asan); emb: $(emb)"
        _run_exe make "$@"
    elif [ -f build.ninja ]
    then
        echo "ASAN: $(asan); emb: $(emb)"
        _run_exe ninja "$@"
    elif [ -d "$build" -a "$recurse" != norecurse ]
    then (
        cd "$build"
        make norecurse "$@"
    )
    else
        echo "ASAN: $(asan); emb: $(emb)"
        _run_exe make "$@"
    fi
}
export -f make

gdb()
{
    unset gdb_opts
    [ -f ".gdb" ] &&
        gdb_opts="-x .gdb"
    $(which gdb) -q $gdb_opts "$@"
}

port()
{
    port=$1
    if [ "$port" ]
    then
        if ! ((port > 0))
        then
            echo "Positive number expected!" >&2
            return 1;
        fi
        sed -i -Ee '/^\s*port\s*=\s*[[:digit:]]+/ { s/^(.+=\s*)[[:digit:]]+\s*$/\1'${port}'/; }' ~/mysqld.cnf
    else
        sed -nEe '/^\s*port\s*=\s*[[:digit:]]+/ { s/.+=\s*([[:digit:]]+)\s*$/\1/; p; }' ~/mysqld.cnf
    fi
}

flavor()
{
    if [ "$1" ]
    then
        if [ -f ~/.bushrc ]
        then
            sed -i -Ee '/^\s*flavor=/ d;' ~/.bushrc
            [ ! -s ~/.bushrc ] &&
                rm ~/.bushrc
        fi
        if [ "$1" = default ]
        then
            unset -v flavor
        else
            if [ -f ~/.bushrc ]
            then
                sed -i -Ee '1i flavor='${1} ~/.bushrc
            else
                echo "flavor=${1}" > ~/.bushrc
            fi
            flavor="$1"
        fi
    else
        if [ "$flavor" ]
        then
            echo $flavor
        else
            echo default
        fi
    fi
    [ -d "$build" ] &&
        rmdir --ignore-fail "$build"
    export build="${bush_dir}/build"${flavor+.${flavor}}
    export opt="${build}/opt"
    export var="${build}/mysql-test/var"
    PATH=$(echo $PATH|sed -Ee 's|'${bush_dir}'[^:]*:?||g')
    PATH="${opt}/bin:${opt}/scripts:${opt}/mysql-test:${opt}/sql-bench:${bush_dir}:${bush_dir}/bin:${bush_dir}/issues:${PATH}"
    add_path ${proj_dir}/test
    CDPATH=$(echo $CDPATH|sed -Ee 's|'${bush_dir}'[^:]*:?||g')
    CDPATH="${CDPATH}:${src}:${src}/mysql-test/suite/versioning:${src}/storage:${src}/storage/innobase:${src}/mysql-test/suite:${src}/mysql-test:${src}/extra:${var}:${HOME}:${HOME}/tmp"
    mkdir -p "$build"
}

flavor > /dev/null

alias default="flavor default"
alias cdb='cd "$build"'
alias cds='cd "$src"'
alias cdt='cd "~/tmp"'
alias cdl='cd "$build/mysql-test/var/log"'

upatch()
{
    arg=${1:-"-p0"}
    shift
    patch "$arg" "$@" < /tmp/u.diff
}

cmgrep()
{
    grep -i "$@" "${build}/CMakeCache.txt"
}

option_check()
{
    sed -Ene '/^'"$1"'/ { s/^.*=(.+)$/\1/; p; }' "$2"
}
export -f option_check

option_set()
{
    sed -Eie '/^'"$1"'/ { s/^(.*)=.+$/\1='"$2"'/; }' "$3"
}

cm_option_check()
{
    option_check "$1" "${build}/CMakeCache.txt"
}
export -f cm_option_check

cm_option_set()
{
    option_set "$1" "$2" "${build}/CMakeCache.txt"
}

bush_cm_onoff_option()
{
    local _opt="$1"
    local _val=$(cm_option_check "$_opt")
    if [[ -n "$3" ]]
    then
        local help="$2"
        local nval=${3^^}
        shift 3
        if [[ $nval != ON && $nval != OFF ]]
        then
            echo "$help" >&2
            return 1;
        fi
        if [[ "$_val" != $nval ]]
        then
            #cm_option_set "$1" "$nval" "${build}/CMakeCache.txt"
            ninja_opts prepare -D$_opt=$nval "$@"
        fi
        cm_option_check "$_opt"
    else
        echo $_val
    fi
}
export -f bush_cm_onoff_option

asan()
{
    bush_cm_onoff_option WITH_ASAN:BOOL 'Usage: asan [off|on]' "$@"
}
export -f asan

msan()
{(
    local nval=${1^^}
    shift
    if [ "$nval" = ON ]
    then
        # local msan_libs="/home/midenok/src/mariadb/msan-libs"
        # local msan_include="${msan_libs}/include"
        #local msan_include2="${msan_libs}/build/llvm-toolchain-14-14.0.6/libcxxabi/include"
        # export CMAKE_C_FLAGS="-O2 ${CMAKE_C_FLAGS:+$CMAKE_C_FLAGS }-Wno-unused-command-line-argument -L${msan_libs} -I${msan_include} -stdlib=libc++ -lc++abi -Wl,-rpath,${msan_libs}"
        # export CMAKE_CXX_FLAGS="${CMAKE_CXX_FLAGS:+$CMAKE_CXX_FLAGS }-std=c++11 -fsanitize-blacklist=/tmp/msan.supp"
        export CMAKE_C_FLAGS="${CMAKE_C_FLAGS:+$CMAKE_C_FLAGS } -fsanitize-blacklist=/tmp/msan.supp"
        export CMAKE_CXX_FLAGS="${CMAKE_CXX_FLAGS:+$CMAKE_CXX_FLAGS } -fsanitize-blacklist=/tmp/msan.supp"
        bush_cm_onoff_option WITH_MSAN:BOOL 'Usage: msan [off|on]' ON \
            -DWITH_EMBEDDED_SERVER=OFF -DWITH_UNIT_TESTS=OFF \
            -DWITH_INNODB_{BZIP2,LZ4,LZMA,LZO,SNAPPY}=OFF \
            -DPLUGIN_{ARCHIVE,TOKUDB,MROONGA,OQGRAPH,ROCKSDB,CONNECT,SPIDER}=NO \
            -DWITH_SAFEMALLOC=OFF \
            -DWITH_{ZLIB,SSL,PCRE}=bundled \
            -DHAVE_LIBAIO_H=0 -DCMAKE_DISABLE_FIND_PACKAGE_{URING,LIBAIO}=1 \
            "$@"
    else
        bush_cm_onoff_option WITH_MSAN:BOOL 'Usage: msan [off|on]' "$nval" "$@"
    fi
)}

maint()
{
    bush_cm_onoff_option MYSQL_MAINTAINER_MODE:STRING 'Usage: maint [off|on]' "$@"
}

emb()
{
    bush_cm_onoff_option WITH_EMBEDDED_SERVER:BOOL 'Usage: emb [off|on]' "$@"
}
export -f emb

wsrep()
{
    bush_cm_onoff_option WITH_WSREP:BOOL 'Usage: wsrep [off|on]' "$@"
}

error()
{
    local err_h="${build}/include/mysqld_error.h"
    grep '^#define' "$err_h" |
    if [ "$1" ]
    then
        grep "$@" "$err_h"
    else
        cat
    fi |
    while read a b c; do echo "$b"; done
}

update_cmake()
{
    local cache=$build/CMakeCache.txt
    if [ ! -f "$cache" ]
    then
        echo "$cache not found!" >&2
        return 1
    fi
    local cmake_build=$(sed -ne '/^# For build in directory: / { s/^# For build in directory: //; p; }' $cache)
    if [ "$build" = "$cmake_build" ]
    then
        echo "Nothing to be done for $build"
        return 0
    fi
    sed -i -e "s|${cmake_build}|${build}|" $cache ||
        return $?
    local cmake_home=$(dirname "$cmake_build")
    if [ "$cmake_home" != "$bush_dir" ]
    then
        sed -i -e "s|${cmake_home}|${bush_dir}|" $cache ||
            return $?
    fi
    echo "Updated ${cmake_build} -> ${build}"
}

exe()
{
    local f="$build/sql/mysqld"
    if [ ! -e "$f" ]
    then
        echo Not exists $f! >&2
        return 1
    fi
    if [ ! -x "$f" ]
    then
        echo Not executable $f! >&2
        return 2
    fi
    echo "$f"
}
export -f exe

args()
{
    alias set=
    alias args=echo
    source $build/mysql-test/var/tmp/gdbinit.mysqld.${1:-1}
    unalias set args
}
export -f args

cmd()
{(
    set -e
    local exe args
    exe="$(exe)"
    args="$(args $@)"
    echo "$exe $args"
)}
export -f cmd

record()
{
    if [[ $(asan) != OFF ]]
    then
        echo 'Run "asan off", compile and try again!' >&2
        return 1
    fi
    rr record `cmd $@`
}

record_kills()
{
    local i=137
    while ((i == 137))
    do
        record
        i=$?
    done
}

reverse()
{
    echo "$@" > ~/reverse.gdb
}

replay()
{
    local revcmd=()
    if [ -f ~/reverse.gdb ]
    then
        revcmd=(-ex "source ~/reverse.gdb")
    else
        revcmd=(-ex "tb open64")
    fi
    rr replay "$@" -- -q -ex "b dlclose" -ex continue "${revcmd[@]}" -ex reverse-continue
}

dmp()
{
    objdump -xC "$@"|less
}
export -f dmp

tarball()
{
    local out="${tarball_dir}/mariadb-$(date +%y%m%d_%H%M).txz"
    cp "${build}/CMakeCache.txt" "$opt"
    git log -n 10 > ${opt}/revision.txt
    tar -cJvhf "$out" -C "$opt" "$@" .
    echo "Written ${out}"
}
export -f tarball

# Print JIRA links of commits

cb()
{
    if [ -n "$DISPLAY" -a -n "$(which xclip)" ]
    then
        xclip -i -f -selection clipboard
    else
        cat
    fi
}
export -f cb

jira()
{
    local arg
    [[ $# -eq 0 ]] &&
        arg=HEAD~..HEAD
    git log --first-parent --pretty=short $arg "$@" |
        grep -P "^\s*MDEV-\d\d\d\d\d " |
        (while read a b; do echo https://jira.mariadb.org/browse/$a; done) |
        cb
}
export -f jira

# Cut timestamp from log files (compatible with mydumper logs)
cut_ts()
{
    perl -pe 's/\d{4}-\d\d-\d\d \d\d:\d\d:\d\d \[\w+\] - //'
}
export -f cut_ts

# Cut thread from log files (compatible with mydumper logs)
cut_thr()
{
    perl -pe 's/Thread \d+: //'
}
export -f cut_thr

git_check_wt()
{
    git "$@" rev-parse --is-inside-work-tree > /dev/null 2>&1
}
export -f git_check_wt

git_copy_remotes()
{
    local src_repo=$1
    local dst_repo=$2
    local copied=0
    local skipped=0
    local ignored=0

    local -A url_to_name
    local -A name_to_url

    # 1. Read existing remotes in dst_repo"
    # format of git remote -v: "name url (type)"
    while read -r name url type
    do
        [[ "$type" != "(fetch)" ]] &&
            continue
        if [[ -z "${url_to_name["$url"]}" ]]
        then
            url_to_name["$url"]="$name"
        else
            url_to_name["$url"]+=" $name"
        fi
        name_to_url["$name"]="$url"
    done < <(git -C "$dst_repo" remote -v)

    # 2. Copy remotes from src_repo to dst_repo
    while read -r name url type
    do
        [[ "$type" != "(fetch)" ]] &&
            continue

        local existing_name="${url_to_name["$url"]}"

        # If url already exists in dst_repo skip adding the remote
        if [[ -n "$existing_name" ]]
        then
            local last_name="${existing_names##* }"
            local count=$(wc -w <<< "$existing_name")
            ((skipped+=count)) || true
        else
            # Check if the name is already taken using the memory hash
            local existing_url="${name_to_url["$name"]}"

            if [[ -n "$existing_url" ]]; then
                local err="Cannot add '$name' ($url), the name is already taken by a different url ($existing_url)!"
                echo ":: Warning: ${err}" >&2
                ((ignored++)) || true
            else
                echo ":: Adding remote '$name' ($url)"
                git -C "$dst_repo" remote add "$name" "$url"

                # Update both hashes to prevent internal duplicates within src_repo
                url_to_name["$url"]="$name"
                name_to_url["$name"]="$url"
                ((copied++)) || true
            fi
        fi
    done < <(git -C "$src_repo" remote -v)
    echo ":: Remotes copied: ${copied}; skipped: ${skipped}; ignored: ${ignored}"
}
export -f git_copy_remotes

git_list_branches()
{
    local repo=$1
    shift
    git -C "$repo" for-each-ref "$@" --format='%(refname:short)' refs/heads
}
export -f git_list_branches

git_merge_repos()
{
    local src_repo=$1
    local dst_repo=$2
    local cur_src_branch=$3
    local prefix=$(basename "$bush_dir")
    local max_branches=10

    # Out variable
    new_branch=""

    echo ":: Migrating last ${max_branches} local branches"

    local src_branch

    while read -r src_branch
    do
        [[ -z "$src_branch" ]] &&
            continue

        local dst_branch="$src_branch"

        # If dst_branch already exists make it unique by prefixing
        local i=0
        while git -C "$dst_repo" show-ref --verify --quiet "refs/heads/$dst_branch"
        do
            dst_branch="${prefix}_${i}/${src_branch}"
            ((i++)) || true
        done

        local cur=""
        local suff=""
        if [[ "$src_branch" == "$cur_src_branch" ]]
        then
            new_branch="$dst_branch"
            cur="* "
        fi

        [[ "$src_branch" != "$dst_branch" ]] &&
            suff="-> ${dst_branch}"

        echo "${cur}${src_branch}${suff}"

        # Now the main magic happens, import src_branch to dst_repo
        git -C "$dst_repo" fetch "$src_repo" "+refs/heads/$src_branch:refs/heads/$dst_branch" --quiet

        # Reattach the tracking data
        local remote=$(git -C "$src_repo" config "branch.$src_branch.remote" || true)
        local merge=$(git -C "$src_repo" config "branch.$src_branch.merge" || true)

        if [[ -n "$remote" && -n "$merge" ]]
        then
            git -C "$dst_repo" config "branch.$dst_branch.remote" "$remote"
            git -C "$dst_repo" config "branch.$dst_branch.merge" "$merge"
        elif [[ -n "$remote" || -n "$merge" ]]
        then
            echo ":: Warning: source branch '$src_branch' broken tracking remote='$remote' merge='$merge'; skipped tracking restore"
        fi
        # FIXME: there can be no current branch in last branches vvv, add cur branch explicitly
    done < <(git_list_branches "$src_repo" --sort=-committerdate --count=$max_branches)

    [[ -z "$new_branch" ]] &&
        die2 ":: Failed to map current src branch '$cur_src_branch' into dst_repo!"

    true
}
export -f git_merge_repos

### Conversion to v2, the below commands are adapted for help system of v2
### The above commands work too, but without help
### FIXME: make help system compatible with Doxygen

## @brief Convert standalone bush to multi-worktree
##
## @details
## Convert src/ to global $proj_dir/mariadb.git
## Current branch and remote tracking (if any) is saved src/
##
## @note: v1 cannot work with existing $proj_dir/mariadb.git
##
## TODO: v2 should be able to merge remotes from src/ into $proj_dir/mariadb.git,
##       excluding the duplicates. v3 should merge remote objects as well.
##
## Version: v1

bareize()
{(
    # Avoid need git() wrapper
    unset git
    cd "$src"
    git_check_wt ||
        die2 "Not a git repository!"
    git update-index -q --refresh
    if [ -x "$bare_dir" ]
    then
        git_check_wt -C "$bare_dir" ||
            die2 "Existing ${bare_dir} is not git repo!"
        [ $(git -C "$bare_dir" config --get core.bare) != true ] &&
            die2 "Existing repo ${bare_dir} is not bare!"
    fi
    old_git="${src}/.git"
    [ -x "$old_git" ] ||
        die2 "${old_git} doesn't exist!"
    [[ $(git config --get core.bare) == "true" ]] &&
        die2 "Old repo ${src} is bare!"
    set -e
    # How it works on detached HEAD? Maybe do git branch --show-current instead?
    branch=$(git rev-parse --abbrev-ref HEAD)
    id_file=$(mktemp /tmp/bareize.XXXXXX)
    id=$(basename "$id_file")
    echo ":: Stashing your stuff by ${id}"
    set > "$id_file"
    git stash push --all -m "bareize stuff for ${id} (bush)"

    if [ -x "$bare_dir" ]
    then
        echo ":: Attaching to bare repo at ${bare_dir}"
        git_copy_remotes "$src" "$bare_dir"
        git_merge_repos "$src" "$bare_dir" "$branch"

        cd "$bare_dir"
        # Get stashed files
        # Note: we cannot just fetch into refs/stash, on restore it fails:
        # git update-ref refs/tmp/local-stash refs/stash
        # git update-ref -d refs/stash
        # git fetch "$src" "refs/stash:refs/stash"
        # git stash pop
        # error: refs/stash@{0} is not a valid reference
        # So, work this out via tmp branch:
        git fetch "$src" "refs/stash:refs/tmp/${id}"

        # FIXME: replace by rm
        src_dir=$(basename "$src")
        nogit=$(mktemp -up $bush_dir "${src_dir}_XXXXXX")
        mv "$src" "$nogit"

        git worktree add --force "$src" "$new_branch"

        cd "$src"
        echo ":: Restoring your stuff"
        # Skip first two stash-internal commits: metadata, index; the third one is untracked files
        git restore --recurse-submodules=no --overlay -s "refs/tmp/${id}^3" -W -- .
        # git update-ref -d "refs/tmp/${id}"
        # FIXME: submodule update --init? something broken with them?
    else
        echo ":: Creating new bare repo at ${bare_dir}"
        mv "$old_git" "$bare_dir"
        cd "$bare_dir"
        git config core.bare true
        # Old $src is not needed since the stuff is stashed
        rm -rf "$src"

        # Or instead of rm do this:
        # src_dir=$(basename "$src")
        # nogit=$(mktemp -up $bush_dir "${src_dir}.XXXXXX")
        # mv "$src" "$nogit"

        # --force proceeds on already checked out branches
        git worktree add --force "$src" "$branch"
        cd "$src"
        echo ":: Restoring your stuff"
        git stash pop --index
    fi

    rm "$id_file"
)}
export -f bareize

[[ -f ~/work.sh ]] &&
  source ~/work.sh

# kate: space-indent on; indent-width 4; mixedindent off; indent-mode cstyle;
