#!/bin/sh

set -e

function log() {
  TAG=${TAG:-"ornew/minecraft"}
  case $1 in
    [eE]*) local LEVEL=E; local COLOR=31 ;;
    [wW]*) local LEVEL=W; local COLOR=33 ;;
    *)     local LEVEL=I; local COLOR= ;;
  esac
  printf "\e[${COLOR}m"
  echo -e "[$(date -u)] ${TAG} ${LEVEL}: ${@:1}"
  printf "\e[m"
}

HOME=/home/minecraft
SERVER_DIR=$HOME/server
SERVER_JAR=$SERVER_DIR/server.jar
INSTALL_MARKER=$SERVER_DIR/.installed
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
  if [ -e "$INSTALL_MARKER" ]; then
    local INSTALLED_VERSION=$(cat "$INSTALL_MARKER")
    if [ "$INSTALLED_VERSION" = "$VERSION" ]; then
      log I "Version $VERSION is already installed."
      return
    fi
  fi
  log I "Installing the vanilla server for '$VERSION'."
  log I "Downloading '$VANILLA_VERSION_INFO_URL' ..."
  local INFO_JSON="/tmp/vanilla-$VANILLA_VERSION.json"
  wget -q -O $INFO_JSON $VANILLA_VERSION_INFO_URL
  local INFO=$(jq -r '.downloads.server.url,.downloads.server.sha1' $INFO_JSON)
  local URL=$(echo "$INFO" | awk 'NR==1')
  local SHA1=$(echo "$INFO" | awk 'NR==2')
  if [ $URL = null -o $SHA1 = null ]; then
    log E "Failed to get version $VERSION information."
    exit 1
  fi

  log I "Downloading '$URL' ..."
  wget -q -O $SERVER_JAR $URL
  local CHECK_SHA1=$(sha1sum $SERVER_JAR | awk '{ print $1 }')
  if [ "$CHECK_SHA1" != "$SHA1" ]; then
    log E ""
    log E "The SHA1 checksums do not match."
    log E "Expect: $SHA1"
    log E "Actual: $CHECK_SHA1"
    exit 1
  fi
  echo "$VERSION" > $INSTALL_MARKER
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

JVM_OPTS_FOR_OPTIMIZED="
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
function metric_alpine_docker() {
  MEMINFO_KB=$(cat /proc/meminfo | grep MemTotal | awk '{print $2}')
  MEMINFO=$(expr $MEMINFO_KB \* 1024)
  MEMLIMIT=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
}

JVM_OPTS=${JVM_OPTS:-auto}
if [ "$JVM_OPTS" = auto ]; then
  log I "Automatically configured JVM options ..."
  metric_alpine_docker
  MEMINFO_MB=$(expr $MEMINFO / 1024 / 1024)
  memlimit_MB=$(expr $MEMLIMIT / 1024 / 1024)
  log I "MemTotal $MEMINFO_MB MB"
  log I "MemLimit $MEMLIMIT_MB MB"
  # 100TB RAM??? -> no limit
  if [ $MEMLIMIT_MB -ge 100000 ]; then
    MAX_MEMORY_SIZE=$MEMINFO_MB
  else
    MAX_MEMORY_SIZE=$MEMLIMIT_MB
  fi
  JVM_RECOMMEND_MEMORY_SIZE="$(expr $MAX_MEMORY_SIZE \* 9 / 10)M"
  if [ $MAX_MEMORY_SIZE -ge 3072 ]; then
    JVM_RECOMMEND_GC_TYPE=G1GC
  else
    JVM_RECOMMEND_GC_TYPE=ConcMarkSweepGC
  fi
  log I "Recommended initialization and maximum heap memory size: ${JVM_RECOMMEND_MEMORY_SIZE}B"
  log I "Recommended GC type: ${JVM_RECOMMEND_GC_TYPE}"
  JVM_MEMORY=${JVM_MEMORY:-$JVM_RECOMMEND_MEMORY_SIZE}
  JVM_INIT_MEMORY=${JVM_INIT_MEMORY:-$JVM_MEMORY}
  JVM_MAX_MEMORY=${JVM_MAX_MEMORY:-$JVM_MEMORY}
  case "X$JVM_GC" in
    X               ) JVM_GC=$JVM_RECOMMEND_GC_TYPE ;;
    XG1GC           ) JVM_GC=G1GC ;;
    XConcMarkSweepGC) JVM_GC=ConcMarkSweepGC ;;
    X*)
      log E "Unknown JVM GC type: \$JVM_GC=$JVM_GC"
      exit 1
    ;;
  esac
  JVM_OPTS="
    ${JVM_OPTS_FOR_OPTIMIZED}
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

