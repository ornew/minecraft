#!/bin/sh

set -e

TAG=${TAG:-"ornew/minecraft"}
function log() {
  case $1 in
    [eE]*) local _level=E; local _color=31 ;;
    [wW]*) local _level=W; local _color=33 ;;
    *)     local _level=I; local _color= ;;
  esac
  printf "\e[${_color}m"
  echo -e "[$(date -u)] ${TAG} ${_level}: ${@:1}"
  printf "\e[m"
}

HOME=/home/minecraft
SERVER_DIR=~/server
SERVER_JAR=$SERVER_DIR/server.jar
mkdir -p $SERVER_DIR

cd $SERVER_DIR
log I "Server directory is '$SERVER_DIR'."

if [ ! -e "$SERVER_DIR/eula.txt" ]; then
  if [ "$EULA" != "" ]; then
    echo "# Generated via Docker on $(date)" > "$SERVER_DIR/eula.txt"
    echo "eula=$EULA" >> "$SERVER_DIR/eula.txt"
  else
    log E ""
    log E "Please accept the Minecraft EULA at"
    log E "  https://account.mojang.com/documents/minecraft_eula"
    log E "by adding the following immediately after 'docker run':"
    log E "  -e EULA=TRUE"
    log E ""
    exit 1
  fi
fi

VANILLA_VERSIONS_JSON=/tmp/vanilla-versions.json
VANILLA_VERSIONS_JSON_URL=https://launchermeta.mojang.com/mc/game/version_manifest.json

log I "Checking the vanilla versions information... "
wget -q -O $VANILLA_VERSIONS_JSON $VANILLA_VERSIONS_JSON_URL
if [ $? != 0 ]; then
  log E "Failed to get the version information."
  exit 1
fi

VANILLA_LATEST=$(jq -r '.latest.release' $VANILLA_VERSIONS_JSON)
log I "The latest version of vanilla is '$VANILLA_LATEST'."

case "X$VERSION" in
  X[0-9.]*)
    log I "The specified version of vanilla is '$VERSION'."
  ;;
  XLATEST|Xlatest)
    VERSION=$VANILLA_LATEST
    log I "The specified version of vanilla is '$VERSION'."
  ;;
  X)
    log I 'There is no $VERSION specification. Use the latest version.'
    VERSION=$VANILLA_LATEST
  ;;
esac
VANILLA_VERSION_INFO_URL=$(jq -r ".versions[] | select(.id == \"$VERSION\").url" $VANILLA_VERSIONS_JSON)
if [ "$VANILLA_VERSION_INFO_URL" = null ]; then
  log E "The specified version infomation of vanilla does not exist: \$VERSION=$VERSION"
  exit 1
fi

function installVanilla {
  log I "Installing the vanilla server for '$VERSION'."
  log I "Downloading '$VANILLA_VERSION_INFO_URL' ..."
  local _info_json="/tmp/vanilla-$VANILLA_VERSION.json"
  wget -q -O $_info_json $VANILLA_VERSION_INFO_URL
  local _info=$(jq -r '.downloads.server.url,.downloads.server.sha1' $_info_json)
  local _url=$(echo "$_info" | awk 'NR==1')
  local _sha1=$(echo "$_info" | awk 'NR==2')
  if [ $_url = null -o $_sha1 = null ]; then
    log E "Failed to get version $VERSION information."
    exit 1
  fi

  log I "Downloading '$_url' ..."
  wget -q -O $SERVER_JAR $_url
  local _check_sha1=$(sha1sum $SERVER_JAR | awk '{ print $1 }')
  if [ "$_check_sha1" != "$_sha1" ]; then
    log E ""
    log E "The SHA1 checksums do not match."
    log E "Expect: $_sha1"
    log E "Actual: $_check_sha1"
    exit 1
  fi
  echo "$VERSION" > '.install_successfully'
  log I "Installation is completed."
}

TYPE=${TYPE:-vanilla}
case "$TYPE" in
  f|FORGE|forge)
    TYPE=forge
    #installForge
    log E "Sorry, we do not yet support Forge installation."
    exit 1
  ;;
  v|VANILLA|vanilla)
    TYPE=vanilla
    installVanilla
  ;;
  *)
    log E "Invalid type: \$TYPE -> '$TYPE'"
    log E "\$TYPE must be 'vanilla' or 'forge'."
    exit 1
  ;;
esac

if [ -n "$OPS" -a ! -e ops.txt.converted ]; then
  log I "Setting ops"
  log I $OPS | awk -v RS=, '{print}' >> ops.txt
fi

if [ -n "$WHITELIST" -a ! -e white-list.txt.converted ]; then
  log I "Setting whitelist"
  echo $WHITELIST | awk -v RS=, '{print}' >> white-list.txt
fi

_jvm_opts_for_optimized="
  -XX:+UnlockExperimentalVMOptions
  -XX:+UseCGroupMemoryLimitForHeap
  -XX:+DisableExplicitGC
  -XX:+UseParNewGC
  -XX:+UseNUMA
  -XX:+CMSParallelRemarkEnabled
  -XX:+UseAdaptiveGCBoundary
  -XX:+UseBiasedLocking
  -XX:+UseFastAccessorMethods
  -XX:+UseCompressedOops
  -XX:+OptimizeStringConcat
  -XX:+AggressiveOpts
  -XX:+UseCodeCacheFlushing
  -XX:-UseGCOverheadLimit
  -XX:MaxTenuringThreshold=15
  -XX:MaxGCPauseMillis=30
  -XX:GCPauseIntervalMillis=150
  -XX:ReservedCodeCacheSize=2048m
  -XX:SoftRefLRUPolicyMSPerMB=2000
  -XX:ParallelGCThreads=10
  -Dfml.ignorePatchDiscrepancies=true
  -Dfml.ignoreInvalidMinecraftCertificates=true
"

# For Alpine on Docker.
function _metric_alpine_docker() {
  _meminfo_KB=$(cat /proc/meminfo | grep MemTotal | awk '{print $2}')
  _meminfo=$(expr $_meminfo_KB \* 1024)
  _memlimit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
}

JVM_OPTS=${JVM_OPTS:-auto}
if [ "$JVM_OPTS" = auto ]; then
  log I "Automatically configured JVM options ..."
  _metric_alpine_docker
  _meminfo_MB=$(expr $_meminfo / 1024 / 1024)
  _memlimit_MB=$(expr $_memlimit / 1024 / 1024)
  log I "MemTotal $_meminfo_MB MB"
  log I "MemLimit $_memlimit_MB MB"
  # 100TB RAM??? -> no limit
  if [ $_memlimit_MB -ge 100000 ]; then
    _max_memory_size=$_meminfo_MB
  else
    _max_memory_size=$_memlimit_MB
  fi
  _jvm_recommend_memory_size="$(expr $_max_memory_size \* 9 / 10)M"
  if [ $_max_memory_size -ge 3072 ]; then
    _jvm_recommend_gc_type=G1GC
  else
    _jvm_recommend_gc_type=ConcMarkSweepGC
  fi
  log I "Recommended initialization and maximum heap memory size: ${_jvm_recommend_memory_size}B"
  log I "Recommended GC type: ${_jvm_recommend_gc_type}"
  JVM_MEMORY=${JVM_MEMORY:-$_jvm_recommend_memory_size}
  JVM_INIT_MEMORY=${JVM_INIT_MEMORY:-$JVM_MEMORY}
  JVM_MAX_MEMORY=${JVM_MAX_MEMORY:-$JVM_MEMORY}
  case "X$JVM_GC" in
    X               ) JVM_GC=$_jvm_recommend_gc_type ;;
    XG1GC           ) JVM_GC=G1GC ;;
    XConcMarkSweepGC) JVM_GC=ConcMarkSweepGC ;;
    X*)
      log E "Unknown JVM GC type: \$JVM_GC=$JVM_GC"
      exit 1
    ;;
  esac
  JVM_OPTS="
    ${_jvm_opts_for_optimized}
    -XX:+Use${JVM_GC}
    -Xms${JVM_INIT_MEMORY}
    -Xmx${JVM_MAX_MEMORY}"
fi
log I "JVM options: $(echo $JVM_OPTS | tr '\n' ' ')"
log I "Starting server..."

if [ -f "$SERVER_DIR/bootstrap.txt" ]; then
  exec java $JVM_OPTS -jar $SERVER_JAR "$@" nogui < /data/bootstrap.txt
else
  exec java $JVM_OPTS -jar $SERVER_JAR "$@" nogui
fi

