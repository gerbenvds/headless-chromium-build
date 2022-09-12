set -e

BUILD_BASE=$(pwd)
CHANNEL=${1:-stable}

VERSION=$(curl -s https://omahaproxy.appspot.com/all.json | \
  jq -r ".[] | select(.os == \"linux\") | .versions[] | select(.channel == \"$CHANNEL\") | .current_version" \
)

printf "LANG=en_US.utf-8\nLC_ALL=en_US.utf-8" >> /etc/environment


mkdir -p build/chromium
cp .gclient build/chromium/

cd build

# install dept_tools
if [ ! -d depot_tools ]; then
	git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
fi

export PATH="/opt/gtk/bin:$PATH:$BUILD_BASE/build/depot_tools"

cd chromium

# fetch chromium source code
# ref: https://www.chromium.org/developers/how-tos/get-the-code/working-with-release-branches

# git shallow clone, much quicker than a full git clone; see https://stackoverflow.com/a/39067940/3145038 for more details

if [ -d src ]; then
	cd src
	git fetch origin "$VERSION" --depth 1
	git checkout FETCH_HEAD
	cd ..
else
	git clone --branch "$VERSION" --depth 1 https://chromium.googlesource.com/chromium/src.git
fi

# Checkout all the submodules at their branch DEPS revisions
gclient sync --with_branch_heads --jobs 16

cd src

gclient runhooks

# the following is no longer necessary since. left here for nostalgia or something.
# ref: https://chromium.googlesource.com/chromium/src/+/1824e5752148268c926f1109ed7e5ef1d937609a%5E%21
# tweak to disable use of the tmpfs mounted at /dev/shm
# sed -e '/if (use_dev_shm) {/i use_dev_shm = false;\n' -i base/files/file_util_posix.cc

#
# tweak to keep Chrome from crashing after 4-5 Lambda invocations
# see https://github.com/adieuadieu/serverless-chrome/issues/41#issuecomment-340859918
# Thank you, Geert-Jan Brits (@gebrits)!
#
SANDBOX_IPC_SOURCE_PATH="content/browser/sandbox_ipc_linux.cc"

sed -e 's/PLOG(WARNING) << "poll";/PLOG(WARNING) << "poll"; failed_polls = 0;/g' -i "$SANDBOX_IPC_SOURCE_PATH"


# specify build flags
mkdir -p out/Headless && \
  echo 'import("//build/args/headless.gn")' > out/Headless/args.gn && \
  echo 'is_debug = false' >> out/Headless/args.gn && \
  echo 'symbol_level = 0' >> out/Headless/args.gn && \
  echo 'is_component_build = false' >> out/Headless/args.gn && \
  echo 'remove_webcore_debug_symbols = true' >> out/Headless/args.gn && \
  echo 'enable_nacl = false' >> out/Headless/args.gn && \
  gn gen out/Headless

# build chromium headless shell
ninja -C out/Headless headless_shell

cp out/Headless/headless_shell "$BUILD_BASE/bin/headless-chromium-unstripped"

cd "$BUILD_BASE"

# strip symbols
strip -o "$BUILD_BASE/bin/headless-chromium" build/chromium/src/out/Headless/headless_shell
echo $VERSION >> "$BUILD_BASE/bin/version.txt"
