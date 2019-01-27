#!/usr/bin/env bash

set -eu

function notice {
    >&2 echo -e "\033[32m$1\033[0m"
}
function noticen {
    >&2 echo -n -e "\033[32m$1\033[0m"
}
function go_get {
    go get $1
    noticen "."
}
function warn {
    >&2 echo -e "\033[33m$1\033[0m"
}

# PLZ_ARGS can be set to pass arguments to all plz invocations in this script.
PLZ_ARGS="${PLZ_ARGS:-}"

# Fetch the Go dependencies manually
export GOPATH="${PWD}/.bootstrap:${PWD}"
if [ -z "${PLZ_NO_GO_BOOTSTRAP+bootstrap}" ]; then
    noticen "Installing Go dependencies..."
    mkdir -p "${PWD}/.bootstrap/src/github.com/thought-machine"
    if [ ! -e "${PWD}/.bootstrap/src/github.com/thought-machine/please" ]; then
        ln -s "$PWD" "${PWD}/.bootstrap/src/github.com/thought-machine/please"
    fi
    go_get golang.org/x/crypto/ssh/terminal
    go_get golang.org/x/sync/errgroup
    go_get golang.org/x/tools/cover
    go_get gopkg.in/op/go-logging.v1
    go_get gopkg.in/gcfg.v1
    go_get github.com/kevinburke/go-bindata/...
    go_get github.com/jessevdk/go-flags
    go_get github.com/dustin/go-humanize
    go_get github.com/texttheater/golang-levenshtein/levenshtein
    go_get github.com/Workiva/go-datastructures/queue
    go_get github.com/coreos/go-semver/semver
    go_get github.com/djherbis/atime
    go_get github.com/karrick/godirwalk
    go_get github.com/hashicorp/go-multierror
    go_get github.com/google/shlex
    go_get github.com/pkg/xattr
    go_get github.com/peterebden/go-cli-init
    notice ""
else
    warn "Skipping Go bootstrap"
fi

# Clean out old artifacts.
rm -rf plz-out src/parse/rules/builtin_rules.bindata.go src/parse/rules/builtin_data.bindata.go
# Compile the builtin rules
notice "Compiling built-in rules..."
go run -tags bootstrap src/parse/asp/main/compiler.go -o plz-out/tmp/src/parse/rules src/parse/rules/*.build_defs
# Embed them into Go
.bootstrap/bin/go-bindata -o src/parse/rules/builtin_data.bindata.go -pkg rules -prefix plz-out/tmp/src/parse/rules plz-out/tmp/src/parse/rules

# Now invoke Go to run Please to build itself.
notice "Building Please..."
go run -tags bootstrap src/please.go $PLZ_ARGS build //src:please --log_file plz-out/log/bootstrap_build.log -o display.systemstats:false
# Use it to build the rest of the tools that come with it.
notice "Building the tools..."
plz-out/bin/src/please $PLZ_ARGS build //package:installed_files --log_file plz-out/log/tools_build.log

if [ $# -gt 0 ] && [ "$1" == "--skip_tests" ]; then
    exit 0
fi

# Run the tests to make sure they still work
notice "Running tests..."

# Run the set of tests that will work on this machine. There are a bunch of tests in this
# repo that are optional and exercise specific rules, and require extra dependencies.
EXCLUDES=""

if [ "`uname`" = "Darwin" ]; then
    if ! hash nasm 2>/dev/null ; then
        # OSX comes with an ancient version of nasm that can't target
        # 64-bit Mach-O binaries (?!!). Ensure we've got the Brew one.
        if [ -n "`nasm -v | grep 'version 2'`" ]; then
            warn "nasm 2.x not found, excluding C++ tests"
            EXCLUDES="${EXCLUDES} --exclude=cc"
        fi
    fi
fi
eval `go env`
if [ "$GOOS" != "linux" ] ; then
    warn "Containerised tests disabled due to not being on Linux"
    EXCLUDES="${EXCLUDES} --exclude=container"
    warn "cc_module tests disabled due to not being on Linux"
    EXCLUDES="${EXCLUDES} --exclude=cc_module"
elif ! hash docker 2>/dev/null ; then
    warn "Docker not found, excluding containerised tests"
    EXCLUDES="${EXCLUDES} --exclude=container"
fi
if ! hash python2 2>/dev/null ; then
    warn "python2 not found, excluding python2 tests"
    EXCLUDES="${EXCLUDES} --exclude=py2"
fi
if ! hash python3 2>/dev/null ; then
    warn "python3 not found, excluding python3 tests"
    EXCLUDES="${EXCLUDES} --exclude=py3 --exclude python3"
fi
if ! pkg-config python3 2>/dev/null ; then
    warn "python3 includes not found, excluding py3 API tests"
    EXCLUDES="${EXCLUDES} --exclude=py3_pkg_config"
fi
if ! hash clang++ 2>/dev/null ; then
    warn "Clang not found, excluding Clang tests"
    EXCLUDES="${EXCLUDES} --exclude=clang"
fi
if ! hash gold 2>/dev/null ; then
    warn "Gold not found, excluding Gold tests"
    EXCLUDES="${EXCLUDES} --exclude=gold"
fi
if ! hash java 2>/dev/null ; then
    warn "Java not found, excluding Java tests"
    EXCLUDES="${EXCLUDES} --exclude=java"
fi
# If the proto files are installed in a different location, their tests won't work.
if [ ! -d "/usr/include/google/protobuf" ]; then
    warn "google/protobuf not found, excluding relevant tests"
    EXCLUDES="${EXCLUDES} --exclude=proto"
fi
GCCVER="`cc -dumpversion`"
if [ ! -d "/usr/lib/gcc/x86_64-linux-gnu/${GCCVER%.*.*}/32" ] && [ ! -d "/usr/lib/gcc/x86_64-pc-linux-gnu/$GCCVER/32" ]; then
    warn "32-bit gcc libraries not found, excluding cross-compile tests"
    EXCLUDES="${EXCLUDES} --exclude=x86"
fi

plz-out/bin/src/please $PLZ_ARGS ${PLZ_COVER:-test} $EXCLUDES --exclude=e2e --log_file plz-out/log/test_build.log --log_file_level 4 --trace_file plz-out/log/trace.json $@

# We run the end-to-end tests separately to ensure things don't fight with one another; they are
# finicky about some things due to running plz recursively and disabling the lock.
notice "Running end-to-end tests..."
plz-out/bin/src/please $PLZ_ARGS ${PLZ_COVER:-test} $EXCLUDES --include=e2e --log_file plz-out/log/test_build.log --log_file_level 4 --trace_file plz-out/log/trace.json $@

# Lint needs python3.
if hash python3 2>/dev/null ; then
    # Don't run this in CI or any unusual workflows.
    if [ $# -eq 0 ] ; then
        tools/misc/ci_lint.py
        plz-out/bin/src/please buildify --mode=check `git ls-files | grep BUILD`
        # If the above fails, then the fix is to run:
        # plz-out/bin/src/please buildify --mode=fix `git ls-files | grep BUILD`
    fi
fi
