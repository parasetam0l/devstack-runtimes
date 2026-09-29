#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
runtime_root="${DEVSTACK_RUNTIME_OUTPUT:-$repository_root/.build/Runtimes}"
mysql_prefix="$runtime_root/mysql-5.7"
mysqld="$mysql_prefix/bin/mysqld"
mysql="$mysql_prefix/bin/mysql"
mysqladmin="$mysql_prefix/bin/mysqladmin"

[[ -x "$mysqld" && -x "$mysql" && -x "$mysqladmin" ]] || { echo "MySQL 5.7 payload is missing." >&2; exit 66; }
/usr/bin/file "$mysqld" | /usr/bin/grep -q 'arm64' || { echo "MySQL 5.7 is not native ARM64." >&2; exit 65; }

temporary="$(mktemp -d -t devstack-mysql57-gate)"
data_directory="$temporary/data"
socket="$temporary/mysql.sock"
port=33307
pid_file="$temporary/mysql.pid"
log_file="$temporary/mysql.log"
server_pid=""

cleanup() {
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then kill "$server_pid" 2>/dev/null || true; fi
    rm -rf "$temporary"
}
trap cleanup EXIT

"$mysqld" --no-defaults --initialize-insecure --basedir="$mysql_prefix" --datadir="$data_directory"

start_server() {
    "$mysqld" --no-defaults --basedir="$mysql_prefix" --datadir="$data_directory" \
        --bind-address=127.0.0.1 --port="$port" --socket="$socket" \
        --pid-file="$pid_file" --log-error="$log_file" --skip-networking=0 &
    server_pid=$!
    for _ in {1..120}; do
        if "$mysqladmin" --no-defaults --protocol=tcp --host=127.0.0.1 --port="$port" --user=root ping >/dev/null 2>&1; then return; fi
        sleep 0.25
    done
    echo "MySQL 5.7 readiness failed" >&2
    /usr/bin/tail -100 "$log_file" >&2 || true
    exit 70
}

stop_server() {
    "$mysqladmin" --no-defaults --protocol=tcp --host=127.0.0.1 --port="$port" --user=root shutdown
    wait "$server_pid"
    server_pid=""
}

start_server
"$mysql" --no-defaults --protocol=tcp --host=127.0.0.1 --port="$port" --user=root <<'SQL'
CREATE DATABASE gate;
USE gate;
CREATE TABLE records (id INT PRIMARY KEY, value VARCHAR(64)) ENGINE=InnoDB;
START TRANSACTION;
INSERT INTO records VALUES (1, 'committed'), (2, 'durable');
COMMIT;
START TRANSACTION;
INSERT INTO records VALUES (3, 'rolled-back');
ROLLBACK;
SQL
before="$("$mysql" --batch --skip-column-names --no-defaults --protocol=tcp --host=127.0.0.1 --port="$port" --user=root --execute="SELECT COUNT(*), SHA2(GROUP_CONCAT(CONCAT(id, ':', value) ORDER BY id), 256) FROM gate.records")"
[[ "$before" == 2$'\t'* ]] || { echo "MySQL CRUD/transaction check failed: $before" >&2; exit 65; }
stop_server
start_server
after="$("$mysql" --batch --skip-column-names --no-defaults --protocol=tcp --host=127.0.0.1 --port="$port" --user=root --execute="SELECT COUNT(*), SHA2(GROUP_CONCAT(CONCAT(id, ':', value) ORDER BY id), 256) FROM gate.records")"
[[ "$after" == "$before" ]] || { echo "MySQL restart integrity mismatch" >&2; exit 65; }
"$mysql" --no-defaults --protocol=tcp --host=127.0.0.1 --port="$port" --user=root --execute="CHECK TABLE gate.records EXTENDED" | /usr/bin/grep -q 'OK'
stop_server
echo "MySQL 5.7 native ARM64 feasibility gate passed."
