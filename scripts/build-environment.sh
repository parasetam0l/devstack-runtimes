# Sourced by the build scripts, after they set MACOSX_DEPLOYMENT_TARGET: what
# keeps a build on the runner from depending on the runner.
#
# Runtimes build with the newest SDK for the oldest supported macOS (the
# lock's minimumMacOS, 15.0). Configure scripts probe for functions by
# compiling and linking against the SDK, which also declares functions macOS
# 15 lacks. A probe that finds one makes the build call it, linked weakly, and
# the runtime crashes on older macOS. These probes are answered "no" up front;
# audit-runtime.sh rejects any weak import that still slips through.
#
# The functions the current SDK added after macOS 15.0:
for function in dup3 pipe2 scandirat fdscandir posix_spawn_file_actions_addfchdir; do
    export "ac_cv_func_${function}=no"
done
# APR probes dup3 under its own name.
export apr_cv_dup3=no

# CMake searches package managers' prefixes by default; GitHub's runners have
# Homebrew. Build scripts pass this as CMAKE_IGNORE_PREFIX_PATH.
ignored_prefixes="/opt/homebrew;/usr/local;/opt/local"
