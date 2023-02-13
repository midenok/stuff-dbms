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

export bush_dir=$(dirname $script)
export src="${bush_dir}/src"
export proj_dir=$(readlink -ne "${bush_dir}/..")
export log_dir="${bush_dir}/log"

CDPATH=$(echo $CDPATH|sed -Ee 's|'${bush_dir}'[^:]*:?||g')
CDPATH="${CDPATH}:${src}:${src}/mysql-test/suite/versioning:${src}/storage:${src}/storage/innobase:${src}/mysql-test/suite:${src}/mysql-test:${build}/mysql-test"

export MYSQL_UNIX_PORT="${bush_dir}/run/mysqld.sock"
export MTR_BINDIR="$build"
export CCACHE_BASEDIR="${bush_dir}"
export CCACHE_DIR="$(realpath ${bush_dir}/../.ccache)"
export CCACHE_NLEVELS=3
# export CCACHE_HARDLINK=true
export CCACHE_MAXSIZE=15G

ulimit -Sc 0

# innodb_ruby setup
PATH="${proj_dir}/innodb_ruby/bin:${PATH}"
export RUBYLIB=${proj_dir}/innodb_ruby/lib
alias ispace=innodb_space
alias ilog=innodb_log

mtr_opts="--tail-lines=0"
opt_ddl="--mysqld=--debug=d,ddl_log"
opt_vers="--mysqld=--debug=d,sysvers_force --mysqld=--system_versioning_alter_history=keep"
opt_fts="--mysqld=--innodb_ft_sort_pll_degree=1"

mtr()
{(
    mkdir -p "$log_dir"
    if [ -x ./mysql-test-run.pl ]
    then
        mtr_script=./mysql-test-run.pl
    else
        mtr_script=mysql-test-run
        cd "$log_dir"
        rm `find -name '*.log' -type f -ctime +30`
    fi
    unset exclude_opts
    [ -f ~/tests_exclude ] &&
        exclude_opts="--skip-test-list=${HOME}/tests_exclude"
    [ -f mtr.log ] &&
        mv mtr.log $(date '+mtr_%Y%m%d_%H%M%S.log')
    # Using --mem makes var/ path always different!
    exec $mtr_script \
        --force \
        --max-test-fail=0 \
        --debug-sync-timeout=2 \
        --suite-timeout=1440 \
        --mysqld=--silent-startup \
        --mysqld=--loose-innodb-flush-method=fsync \
        ${mtr_opts} \
        ${exclude_opts} \
        "$@" 2>&1 | tee -a mtr.log
    return $PIPESTATUS
#        --suite="main-,archive-,binlog-,client-,csv-,federated-,funcs_1-,funcs_2-,gcol-,handler-,heap-,innodb-,innodb_fts-,innodb_gis-,innodb_i_s-,json-,maria-,mariabackup-,multi_source-,optimizer_unfixed_bugs-,parts-,perfschema-,plugins-,roles-,rpl-,sys_vars-,sql_sequence-,unit-,vcol-,versioning-,period-,sysschema-" \
#        --suite="main-,archive-,binlog-,csv-,federated-,funcs_1-,funcs_2-,gcol-,handler-,heap-,innodb-,innodb_fts-,innodb_gis-,json-,maria-,mariabackup-,multi_source-,optimizer_unfixed_bugs-,parts-,perfschema-,plugins-,roles-,rpl-,sys_vars-,unit-,vcol-,versioning-,period-,sysschema-" \
)}

alias mtrh="mysql-test-run --help | less"
alias mtrx="mtr --extern socket=${MYSQL_UNIX_PORT}"
alias mtrx1="mtr --extern socket=${build}/mysql-test/var/tmp/mysqld.1.sock"
alias mtrf="mtr --big-test --fast --parallel=$(nproc)"
alias mtrb="mtrf --big-test"
alias mtrz="mtr --fast --reorder --parallel=$(nproc)"
alias mtrm="mtrz --suite=main"
alias mtrv="mtrz --suite=versioning"
alias mtrvv="mtrz --suite=period"
alias mtrvvg="mtr --manual-gdb --suite=period"
alias mtrg="mtr --manual-gdb"
alias mtrvg="mtr --manual-gdb --suite=versioning"
alias mtrp="mtrz --suite=parts"
alias mtrpg="mtrp --manual-gdb"
alias mtri="mtrz --suite=innodb"
alias mtrig="mtri --manual-gdb"
alias myh="mysqld --verbose --help | less"
alias makez="make -j$(nproc)"

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


mysql_client=$(which mysql)

mysql()
{(
    db=${1:-test}
    shift
    [ -x "`which most`" ] &&
        export PAGER=most
    "$mysql_client" -S "${bush_dir}/run/mysqld.sock" -u root "$db" "$@"
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

mysqlt()
{(
    db=${1:-mtr}
    shift
    [ -x "`which most`" ] &&
        export PAGER=most
    "$mysql_client" -S "${build}/mysql-test/var/tmp/mysqld.1.sock" -u root "$db" "$@"
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
    exec "${opt}/bin/mysqld" "--defaults-file=$defaults" --debug-gdb --silent-startup "$@"
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
        "${opt}/bin/mysqld" "--defaults-file=$defaults" --debug-gdb "$@"
)}
export -f run

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
    exec gdb -q $opt_run --args "${opt}/bin/mysqld" "--defaults-file=$defaults" --plugin-maturity=experimental --plugin-load=test_versioning --debug-gdb "$@"
)}
export -f rund

runt()
{(
    cd "${src}/mysql-test"
    suffix=${1:-1}
    shift
    exec gdb -q --args "${opt}/bin/mysqld" --defaults-group-suffix=.$suffix --defaults-file=${build}/mysql-test/var/my.cnf --log-output=file --gdb --core-file --loose-debug-sync-timeout=300 --debug --debug-gdb "$@"
)}
export -f runt

runrr()
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
    exec rr record "${opt}/bin/mysqld" "--defaults-file=$defaults" --plugin-maturity=experimental --plugin-load=test_versioning --debug-gdb --silent-startup "$@"
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

    exec $run_gdb "${opt}/bin/mysqlbinlog" "--defaults-file=${defaults}" \
        --local-load="${build}/var/tmp" -v "$@"
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
    exec $run_gdb "$(which mysqldump)" "--defaults-file=${defaults}" "$db" "$@"
)}
export -f dump

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
    fi
    data=$(readlink -f "${data}")
    if [ -e "${data}" ]
    then
        echo "${data} already exists!" >&2
        exit 100
    fi
    mkdir -p "${data}"
    ln -s "${bush_dir}/run" "${data}/run"
    mysql_install_db --basedir="${opt}" --datadir="${data}" --defaults-file="${defaults}" --auth-root-authentication-method=normal
)}
export -f initdb

attach()
{
    gdb-attach ${opt}/bin/mysqld
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

asan_opts=-DWITH_ASAN:BOOL=ON
msan_opts=-DWITH_MSAN:BOOL=ON
export debug_opts="-g -O0 -DEXTRA_DEBUG -Werror=return-type -Wno-error=unused-variable -Wno-error=unused-function"
export debug_opts_clang="-fno-limit-debug-info -Wno-error=macro-redefined -Werror=overloaded-virtual -Wno-deprecated-register"
# FIXME: detect lld version and add -Wl,--threads=24
export linker_opts_clang="-fuse-ld=lld"

conf()
{(
    cd "${build}"
    ccmake "$@" "${src}"
)}

cmake()
{(
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
    eval flavor_opts=\$${flavor}_opts
    cmake-ln -Wno-dev \
        -DCMAKE_INSTALL_PREFIX:STRING=${opt} \
        -DCMAKE_BUILD_TYPE:STRING=Debug \
        -DCMAKE_CXX_FLAGS_DEBUG:STRING="$debug_opts $compiler_flags $profile_flags $CMAKE_C_FLAGS $CMAKE_CXX_FLAGS" \
        -DCMAKE_C_FLAGS_DEBUG:STRING="$debug_opts $compiler_flags $profile_flags $CMAKE_C_FLAGS" \
        -DCMAKE_EXE_LINKER_FLAGS:STRING="$profile_flags $CMAKE_LDFLAGS" \
        -DCMAKE_MODULE_LINKER_FLAGS:STRING="$profile_flags $CMAKE_LDFLAGS" \
        -DCMAKE_SHARED_LINKER_FLAGS:STRING="$profile_flags $CMAKE_LDFLAGS" \
        -DSECURITY_HARDENED:BOOL=FALSE \
        -DMYSQL_MAINTAINER_MODE:STRING=OFF \
        -DUPDATE_SUBMODULES:BOOL=OFF \
        -DPLUGIN_METADATA_LOCK_INFO:STRING=STATIC \
        -DWITH_UNIT_TESTS:BOOL=OFF \
        -DWITH_CSV_STORAGE_ENGINE:BOOL=OFF \
        -DWITH_WSREP:BOOL=OFF \
        -DWITH_MARIABACKUP:BOOL=OFF \
        -DWITH_SAFEMALLOC:BOOL=OFF \
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
    # if [ -x $(which ccache) ]
    # then
    #    cclauncher="-DCMAKE_CXX_COMPILER_LAUNCHER=ccache -DCMAKE_C_COMPILER_LAUNCHER=ccache"
    # fi
    # TODO: add DISABLE_PSI_FILE
    #
    # Note: SECURITY_HARDENED or MYSQL_MAINTAINER_MODE?
    eval flavor_opts=\$${flavor}_opts
    cmake-ln -Wno-dev \
        -DCMAKE_INSTALL_PREFIX:STRING=${opt} \
        -DCMAKE_BUILD_TYPE:STRING=Release \
        -DCMAKE_CXX_FLAGS:STRING="-g -O3 $compiler_flags $profile_flags $CMAKE_C_FLAGS $CMAKE_CXX_FLAGS" \
        -DCMAKE_C_FLAGS:STRING="-g -O3 $compiler_flags $profile_flags $CMAKE_C_FLAGS" \
        -DCMAKE_EXE_LINKER_FLAGS:STRING="-z relro -z now $profile_flags $CMAKE_LDFLAGS" \
        -DCMAKE_MODULE_LINKER_FLAGS:STRING="-z relro -z now $profile_flags $CMAKE_LDFLAGS" \
        -DCMAKE_SHARED_LINKER_FLAGS:STRING="-z relro -z now $profile_flags $CMAKE_LDFLAGS" \
        -DCMAKE_C_COMPILER:FILEPATH=/usr/bin/gcc \
        -DCMAKE_CXX_COMPILER:FILEPATH=/usr/bin/g++ \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
        -DCONC_WITH_DYNCOL=NO \
        -DCONC_WITH_EXTERNAL_ZLIB=NO \
        -DCONC_WITH_MYSQLCOMPAT=NO \
        -DCONC_WITH_UNIT_TESTS=NO \
        -DENABLED_PROFILING=NO \
        -DENABLE_DTRACE=NO \
        -DGSSAPI_FOUND=FALSE \
        -DMAX_INDEXES=128 \
        -DMUTEXTYPE=futex \
        -DMYSQL_MAINTAINER_MODE=NO \
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
        -DSECURITY_HARDENED=OFF \
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
        -DWITH_MARIABACKUP=OFF \
        -DWITH_NUMA=OFF \
        -DWITH_PCRE=bundled \
        -DWITH_SAFEMALLOC=OFF \
        -DWITH_SYSTEMD=no \
        -DWITH_UNIT_TESTS=OFF \
        -DWITH_WSREP:BOOL=OFF \
        -DWITH_ZLIB=bundled \
        $flavor_opts \
        $cclauncher \
        $plugins \
        "$@" \
        "${src}"
)}
export -f prepare_sn

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
{(
    build="${build}-rel"
    cmd="$1"
    shift
    "$cmd" \
        "$@" \
        -DBUILD_CONFIG:STRING=mysql_release \
        -DWITH_JEMALLOC:BOOL=ON \
        -DCMAKE_CXX_FLAGS_RELEASE:STRING="-g" \
        -DCMAKE_C_FLAGS_RELEASE:STRING="-g" \
        -DSECURITY_HARDENED:BOOL=FALSE
)}
export -f rel_opts

### TODO: split Ninja and Clang, build Debug/Release with GCC/Clang with Ninja/Make
ninja_clang_opts()
{(
    cmd="$1"
    # FIXME: detect clang version and add -fdebug-macro
    export CMAKE_C_FLAGS="${CMAKE_C_FLAGS:+$CMAKE_C_FLAGS }"
    export CMAKE_CXX_FLAGS="${CMAKE_CXX_FLAGS:+$CMAKE_CXX_FLAGS }${debug_opts_clang}"
    export CMAKE_LDFLAGS="${CMAKE_LDFLAGS:+$CMAKE_LDFLAGS }${linker_opts_clang}"
    #libc_home=/usr/lib/llvm-14
    #export CFLAGS="${CFLAGS:+ $CFLAGS}-fdebug-macro -stdlib=libc++ -I${libc_home}/include/c++/v1 -L${libc_home}/lib -Wl,-rpath,${libc_home}/lib"
    shift
    "$cmd" \
        "$@" \
        -GNinja \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -D_CMAKE_TOOLCHAIN_PREFIX=llvm-
)}
export -f ninja_clang_opts

ninja_opts()
{(
    cmd="$1"
    shift
    "$cmd" \
        -GNinja \
        "$@"
)}
export -f ninja_opts

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


alias relprepare="rel_opts prepare_strict"
alias nprepare="ninja_opts prepare"
alias clprepare="ninja_clang_opts prepare"
alias nrelprepare="ninja_opts rel_opts prepare"
alias o1prepare="ninja_opts o1_opts prepare"
alias embprepare="emb_opts prepare"

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
        _run_exe make "$@"
    elif [ -f build.ninja ]
    then
        _run_exe ninja "$@"
    elif [ -d "$build" -a "$recurse" != norecurse ]
    then (
        cd "$build"
        make norecurse "$@"
    )
    else
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
        sed -i -Ee '/^\s*flavor=/ d;' ~/.bashrc
        if [ "$1" = default ]
        then
            unset flavor
        else
            sed -i -Ee '/^\s*source ~\/env.sh\s*$/i flavor='${1} ~/.bashrc
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
    export build="${bush_dir}/build"${flavor+.${flavor}}
    export opt="${build}/opt"
    PATH=$(echo $PATH|sed -Ee 's|'${bush_dir}'[^:]*:?||g')
    PATH="${opt}/bin:${proj_dir}/test:${opt}/scripts:${opt}/mysql-test:${opt}/sql-bench:${bush_dir}:${bush_dir}/bin:${bush_dir}/issues:${PATH}"
}

flavor > /dev/null

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

option_set()
{
    sed -Eie '/^'"$1"'/ { s/^(.*)=.+$/\1='"$2"'/; }' "$3"
}

cm_option_check()
{
    option_check "$1" "${build}/CMakeCache.txt"
}

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

asan()
{
    bush_cm_onoff_option WITH_ASAN:BOOL 'Usage: asan [off|on]' "$@"
}

msan()
{(
    local nval=${1^^}
    shift
    if [ "$nval" = ON ]
    then
        local msan_libs="/home/midenok/src/mariadb/msan-libs"
        local msan_include="${msan_libs}/build/llvm-toolchain-14-14.0.0/libc++msan/include/c++/v1"
        local msan_include2="${msan_libs}/build/llvm-toolchain-14-14.0.0/libcxxabi/include"
        export CMAKE_C_FLAGS="-O2 ${CMAKE_C_FLAGS:+$CMAKE_C_FLAGS }-Wno-unused-command-line-argument -L${msan_libs} -I${msan_include} -I${msan_include2} -stdlib=libc++ -lc++abi -Wl,-rpath,${msan_libs}"
        export CMAKE_CXX_FLAGS="${CMAKE_CXX_FLAGS:+$CMAKE_CXX_FLAGS }-std=c++11"
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

replay()
{
    rr replay "$@" -- -q -ex continue -ex reverse-continue
}

dmp()
{
  objdump -xC "$@"|less
}
export -f dmp

[[ -f ~/work.sh ]] &&
  source ~/work.sh
