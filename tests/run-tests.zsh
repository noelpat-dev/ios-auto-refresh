#!/bin/zsh

set -eu
set -o pipefail
umask 077

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

readonly TEST_DIR="${0:A:h}"
readonly REPO_ROOT="${TEST_DIR:h}"
readonly WORKER="$REPO_ROOT/bin/ios-auto-refresh"
readonly INSTALLER="$REPO_ROOT/bin/install-launch-agent"
readonly UNINSTALLER="$REPO_ROOT/bin/uninstall-launch-agent"

TEMP_ROOT="$(/usr/bin/mktemp -d)"
TEMP_ROOT="$(cd "$TEMP_ROOT" && /bin/pwd -P)"
trap '/bin/chmod -R u+rwX "$TEMP_ROOT" 2>/dev/null || true; /bin/rm -rf "$TEMP_ROOT"' EXIT

pass_count=0
fail() {
    print -u2 "FAIL: $*"
    exit 1
}
pass() {
    pass_count=$(( pass_count + 1 ))
    print "PASS: $*"
}
expect_failure() {
    if "$@" >/dev/null 2>&1; then
        fail "command unexpectedly succeeded: $*"
    fi
    return 0
}

for script in "$WORKER" "$INSTALLER" "$UNINSTALLER" "$0"; do
    /bin/zsh -n "$script" || fail "syntax: $script"
done
pass "zsh syntax"

missing_key_output="$("$WORKER" --app 2>&1 || true)"
[[ "$missing_key_output" == *'--app requires a catalog key.'* ]] || fail "missing --app diagnostic"
expect_failure "$WORKER" --all --app sample
expect_failure "$WORKER" --app sample --status --dry-run
expect_failure "$WORKER" --unknown
pass "CLI argument validation"

/usr/bin/plutil -lint "$REPO_ROOT/apps.d/example.plist.template" >/dev/null || fail "template plist"
pass "template plist"

for script in "$WORKER" "$INSTALLER" "$UNINSTALLER" "$0"; do
    [[ -x "$script" ]] || fail "not executable: $script"
done
pass "executable permissions"

project_root="$TEMP_ROOT/project"
project_file="Sample.xcodeproj"
catalog_dir="$TEMP_ROOT/catalog"
runtime_root="$TEMP_ROOT/runtime"
test_home="$TEMP_ROOT/home"
/bin/mkdir -p "$project_root/$project_file" "$catalog_dir" "$test_home"
/bin/chmod 700 "$project_root" "$project_root/$project_file" "$catalog_dir" "$test_home"

make_catalog() {
    local output="$1" project_value="$2" project_file_value="$3"
    /usr/bin/plutil -create xml1 "$output"
    /usr/bin/plutil -insert displayName -string 'Sample App' "$output"
    /usr/bin/plutil -insert projectRoot -string "$project_value" "$output"
    /usr/bin/plutil -insert projectFile -string "$project_file_value" "$output"
    /usr/bin/plutil -insert scheme -string Sample "$output"
    /usr/bin/plutil -insert configuration -string Debug "$output"
    /usr/bin/plutil -insert bundleIdentifier -string com.example.sample "$output"
    /usr/bin/plutil -insert teamIdentifier -string A1B2C3D4E5 "$output"
    /usr/bin/plutil -insert buildDeviceUDID -string 00000000-0000000000000000 "$output"
    /usr/bin/plutil -insert coreDeviceID -string 00000000-0000-0000-0000-000000000000 "$output"
    /usr/bin/plutil -insert refreshThresholdSeconds -integer 86400 "$output"
    /bin/chmod 600 "$output"
}

make_catalog "$catalog_dir/sample.plist" "$project_root" "$project_file"

HOME="$test_home" IOS_AUTO_REFRESH_ROOT="$runtime_root" IOS_AUTO_REFRESH_CATALOG_DIR="$catalog_dir" \
    "$WORKER" --app sample --validate >/dev/null || fail "valid catalog rejected"
pass "valid catalog"

[[ ! -e "$runtime_root" ]] || fail "validation wrote runtime data"
HOME="$test_home" IOS_AUTO_REFRESH_ROOT="$runtime_root" IOS_AUTO_REFRESH_CATALOG_DIR="$catalog_dir" \
    "$WORKER" --app sample --status >/dev/null || fail "status"
[[ ! -e "$runtime_root" ]] || fail "status wrote runtime data"
HOME="$test_home" IOS_AUTO_REFRESH_ROOT="$runtime_root" IOS_AUTO_REFRESH_CATALOG_DIR="$catalog_dir" \
    "$WORKER" --app sample --dry-run >/dev/null || fail "dry run"
[[ ! -e "$runtime_root" ]] || fail "dry run wrote runtime data"
HOME="$test_home" IOS_AUTO_REFRESH_ROOT="$runtime_root" IOS_AUTO_REFRESH_CATALOG_DIR="$catalog_dir" \
    "$WORKER" --all --dry-run >/dev/null || fail "all dry run"
[[ ! -e "$runtime_root" ]] || fail "all dry run wrote runtime data"
pass "read-only modes"

make_catalog "$catalog_dir/traversal.plist" "$project_root" '../Escape.xcodeproj'
expect_failure env HOME="$test_home" IOS_AUTO_REFRESH_ROOT="$runtime_root" \
    IOS_AUTO_REFRESH_CATALOG_DIR="$catalog_dir" "$WORKER" --app traversal --validate
pass "project traversal rejected"

/bin/ln -s "$catalog_dir/sample.plist" "$catalog_dir/linked.plist"
expect_failure env HOME="$test_home" IOS_AUTO_REFRESH_ROOT="$runtime_root" \
    IOS_AUTO_REFRESH_CATALOG_DIR="$catalog_dir" "$WORKER" --app linked --validate
pass "catalog symlink rejected"

make_catalog "$catalog_dir/permissions.plist" "$project_root" "$project_file"
/bin/chmod 666 "$catalog_dir/permissions.plist"
expect_failure env HOME="$test_home" IOS_AUTO_REFRESH_ROOT="$runtime_root" \
    IOS_AUTO_REFRESH_CATALOG_DIR="$catalog_dir" "$WORKER" --app permissions --validate
/bin/chmod 600 "$catalog_dir/permissions.plist"
pass "unsafe catalog permissions rejected"

installer_catalog="$TEMP_ROOT/installer-catalog"
/bin/mkdir "$installer_catalog"
/bin/chmod 700 "$installer_catalog"
/bin/cp "$catalog_dir/sample.plist" "$installer_catalog/sample.plist"
/bin/chmod 600 "$installer_catalog/sample.plist"
HOME="$test_home" IOS_AUTO_REFRESH_SOURCE_CATALOG_DIR="$installer_catalog" \
    "$INSTALLER" --dry-run >/dev/null || fail "installer dry run"
[[ ! -e "$test_home/Library" ]] || fail "installer dry run wrote files"
pass "installer dry run"

HOME="$test_home" IOS_AUTO_REFRESH_SOURCE_CATALOG_DIR="$installer_catalog" \
    "$INSTALLER" --no-load >/dev/null || fail "installer no-load"
generated_plist="$test_home/Library/LaunchAgents/dev.ios-auto-refresh.plist"
[[ -f "$generated_plist" && ! -L "$generated_plist" ]] || fail "generated LaunchAgent missing"
/usr/bin/plutil -lint "$generated_plist" >/dev/null || fail "generated LaunchAgent malformed"
installed_worker="$(/usr/bin/plutil -extract ProgramArguments.0 raw "$generated_plist")"
[[ "$installed_worker" == "$test_home/Library/Application Support/iOSAutoRefresh/runtime/"*/ios-auto-refresh ]] || \
    fail "LaunchAgent does not use a runtime snapshot"
[[ "$(/usr/bin/plutil -extract ProgramArguments.1 raw "$generated_plist")" == '--all' ]] || \
    fail "LaunchAgent does not select all apps"
[[ "$(/usr/bin/plutil -extract Umask raw "$generated_plist")" == '63' ]] || fail "LaunchAgent umask"
snapshot_name="${installed_worker:h:t}"
snapshot_digest="$(/usr/bin/shasum -a 256 "$installed_worker" | /usr/bin/awk '{print $1}')"
[[ "$snapshot_name" == "$snapshot_digest" ]] || fail "runtime snapshot hash"
[[ "$(/usr/bin/stat -f '%Lp' "$generated_plist")" == '600' ]] || fail "LaunchAgent permissions"
pass "generated private runtime and LaunchAgent"

snapshot_backup="$TEMP_ROOT/worker-backup"
/bin/mv "$installed_worker" "$snapshot_backup"
/bin/ln -s "$WORKER" "$installed_worker"
expect_failure env HOME="$test_home" "$installed_worker" --app sample --validate
/bin/unlink "$installed_worker"
/bin/mv "$snapshot_backup" "$installed_worker"
print '# tamper check' >> "$installed_worker"
expect_failure env HOME="$test_home" "$installed_worker" --app sample --validate
/bin/cp "$WORKER" "$installed_worker"
/bin/chmod 700 "$installed_worker"
[[ "$(/usr/bin/shasum -a 256 "$installed_worker" | /usr/bin/awk '{print $1}')" == "$snapshot_name" ]] || \
    fail "runtime snapshot restoration"
pass "runtime symlink and tampering rejected"

HOME="$test_home" IOS_AUTO_REFRESH_SOURCE_CATALOG_DIR="$installer_catalog" \
    "$INSTALLER" --no-load >/dev/null || fail "transactional catalog replacement"
catalog_transaction_artifact="$(/usr/bin/find "$test_home/Library/Application Support/iOSAutoRefresh/catalog" \
    -maxdepth 1 \( -name '.apps.d.staging.*' -o -name '.apps.d.previous.*' \) -print -quit)"
[[ -z "$catalog_transaction_artifact" ]] || fail "catalog transaction left a staging or backup directory"
pass "complete catalog replacement"

log_test_root="$TEMP_ROOT/log-test-runtime"
/bin/mkdir -p "$log_test_root/logs/sample"
/bin/chmod 700 "$log_test_root" "$log_test_root/logs" "$log_test_root/logs/sample"
log_victim="$TEMP_ROOT/log-victim"
print 'must remain unchanged' > "$log_victim"
victim_hash="$(/usr/bin/shasum -a 256 "$log_victim" | /usr/bin/awk '{print $1}')"
/bin/ln -s "$log_victim" "$log_test_root/logs/sample/xcodebuild.log"
expect_failure env HOME="$test_home" IOS_AUTO_REFRESH_ROOT="$log_test_root" \
    IOS_AUTO_REFRESH_CATALOG_DIR="$catalog_dir" "$WORKER" --app sample
[[ "$(/usr/bin/shasum -a 256 "$log_victim" | /usr/bin/awk '{print $1}')" == "$victim_hash" ]] || \
    fail "log symlink target was modified"
pass "log symlink rejected without truncating target"

dangling_test_root="$TEMP_ROOT/dangling-log-runtime"
/bin/mkdir -p "$dangling_test_root/logs/sample"
/bin/chmod 700 "$dangling_test_root" "$dangling_test_root/logs" "$dangling_test_root/logs/sample"
dangling_target="$TEMP_ROOT/dangling-log-target"
/bin/ln -s "$dangling_target" "$dangling_test_root/logs/sample/xcodebuild.log"
expect_failure env HOME="$test_home" IOS_AUTO_REFRESH_ROOT="$dangling_test_root" \
    IOS_AUTO_REFRESH_CATALOG_DIR="$catalog_dir" "$WORKER" --app sample
[[ ! -e "$dangling_target" ]] || fail "dangling log symlink target was created"
pass "dangling log symlink rejected without creating target"

recovery_root="$TEMP_ROOT/recovery-runtime"
stale_recovery_dir="$recovery_root/runs/sample.crashed"
stale_profile_dir="$stale_recovery_dir/profiles/xcode-user-data"
profile_source_dir="$test_home/Library/Developer/Xcode/UserData/Provisioning Profiles"
/bin/mkdir -p "$stale_profile_dir" "$profile_source_dir" "$recovery_root/logs/sample"
/bin/chmod 700 "$recovery_root" "$recovery_root/runs" "$stale_recovery_dir" \
    "$stale_recovery_dir/profiles" "$stale_profile_dir" "$recovery_root/logs" \
    "$recovery_root/logs/sample" "$profile_source_dir"
print 'recovery fixture' > "$stale_profile_dir/RECOVERY.mobileprovision"
recovery_log_target="$TEMP_ROOT/recovery-log-target"
/bin/ln -s "$recovery_log_target" "$recovery_root/logs/sample/xcodebuild.log"
expect_failure env HOME="$test_home" IOS_AUTO_REFRESH_ROOT="$recovery_root" \
    IOS_AUTO_REFRESH_CATALOG_DIR="$catalog_dir" "$WORKER" --app sample
[[ -f "$profile_source_dir/RECOVERY.mobileprovision" ]] || fail "stale profile was not restored"
[[ ! -e "$stale_recovery_dir" ]] || fail "recovered stale run was not removed"
[[ ! -e "$recovery_log_target" ]] || fail "recovery test reached an unsafe log target"
pass "interrupted profile quarantine recovered before device work"

not_due_stale_dir="$recovery_root/runs/sample.not-due"
not_due_profile_dir="$not_due_stale_dir/profiles/xcode-user-data"
/bin/mkdir -p "$not_due_profile_dir" "$recovery_root/state/sample"
/bin/chmod 700 "$not_due_stale_dir" "$not_due_stale_dir/profiles" "$not_due_profile_dir" \
    "$recovery_root/state" "$recovery_root/state/sample"
print 'not-due recovery fixture' > "$not_due_profile_dir/NOT-DUE.mobileprovision"
/usr/bin/plutil -create xml1 "$recovery_root/state/sample/state.plist"
/usr/bin/plutil -insert profileExpirationUTC -string '2099-01-01T00:00:00Z' \
    "$recovery_root/state/sample/state.plist"
/bin/chmod 600 "$recovery_root/state/sample/state.plist"
HOME="$test_home" IOS_AUTO_REFRESH_ROOT="$recovery_root" IOS_AUTO_REFRESH_CATALOG_DIR="$catalog_dir" \
    "$WORKER" --app sample >/dev/null || fail "not-due stale recovery"
[[ -f "$profile_source_dir/NOT-DUE.mobileprovision" ]] || fail "not-due stale profile was not restored"
[[ ! -e "$not_due_stale_dir" ]] || fail "not-due stale run was not removed"
[[ ! -e "$recovery_log_target" ]] || fail "not-due recovery reached the device/log phase"
pass "interrupted profile quarantine recovered even when refresh is not due"

mock_launchctl="$TEMP_ROOT/mock-launchctl"
{
    print '#!/bin/zsh'
    print '[[ "$1" == "print" ]] && exit 0'
    print '[[ "$1" == "bootout" ]] && exit 1'
    print 'exit 1'
} > "$mock_launchctl"
/bin/chmod 700 "$mock_launchctl"
before_uninstall_hash="$(/usr/bin/shasum -a 256 "$generated_plist" | /usr/bin/awk '{print $1}')"
expect_failure env HOME="$test_home" IOS_AUTO_REFRESH_LAUNCHCTL="$mock_launchctl" "$UNINSTALLER"
after_uninstall_hash="$(/usr/bin/shasum -a 256 "$generated_plist" | /usr/bin/awk '{print $1}')"
[[ "$before_uninstall_hash" == "$after_uninstall_hash" ]] || fail "failed bootout changed LaunchAgent plist"
pass "uninstaller fails closed when bootout fails"

installed_catalog="$test_home/Library/Application Support/iOSAutoRefresh/catalog/apps.d"
/bin/cp "$installer_catalog/sample.plist" "$installed_catalog/stale.plist"
plist_hash_before_stale_check="$(/usr/bin/shasum -a 256 "$generated_plist" | /usr/bin/awk '{print $1}')"
expect_failure env HOME="$test_home" IOS_AUTO_REFRESH_SOURCE_CATALOG_DIR="$installer_catalog" \
    "$INSTALLER" --no-load
plist_hash_after_stale_check="$(/usr/bin/shasum -a 256 "$generated_plist" | /usr/bin/awk '{print $1}')"
[[ "$plist_hash_before_stale_check" == "$plist_hash_after_stale_check" ]] || \
    fail "stale catalog failure changed LaunchAgent plist"
/bin/unlink "$installed_catalog/stale.plist"
pass "stale installed catalog rejected before LaunchAgent change"

fragment_one='No'
fragment_two='el'
forbidden_name="$fragment_one$fragment_two"
old_app_one='Peak'
old_app_two='line'
old_app="$old_app_one$old_app_two"
users_directory='Users'
absolute_user_prefix="/$users_directory/"
if /usr/bin/grep -R -I -n -E "$forbidden_name|$old_app|$absolute_user_prefix" "$REPO_ROOT" >/dev/null; then
    fail "public hygiene scan found personal metadata"
fi
if /usr/bin/find "$REPO_ROOT/apps.d" -maxdepth 1 -type f -name '*.plist' | /usr/bin/grep -q .; then
    fail "real catalog file is present"
fi
pass "public hygiene"

mutation_command='devicectl device uninstall'
if /usr/bin/grep -R -I -n -F "$mutation_command" "$REPO_ROOT/bin" >/dev/null; then
    fail "app uninstall command found"
fi
if /usr/bin/grep -R -I -n -E 'rm[[:space:]]+-rf|^[[:space:]]*(eval|source)[[:space:]]' "$REPO_ROOT/bin" >/dev/null; then
    fail "unsafe shell primitive found"
fi
pass "no destructive app or shell primitive"

print "All $pass_count tests passed."
