#!/bin/sh

set -e

function log()
{
  if [ "$QUIET" == true ]; then
    return
  fi
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

#===============================================================================
# Is user accept EULA?
#
# (depend)
#   func log
#
# (Access)
#   $EULA
#   $SERVER_DIR
#===============================================================================
function check_eula()
{
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
}

#===============================================================================
# Resolve released Minecraft Vanilla Server Versions.
#
# (depend)
#   log
#
# (Access)
#   $VERSION
#
# (Update)
#   $VERSION          <- Resolved Minecraft Version
#   $VERSION_INFO_URL
#===============================================================================
function resolve_vanilla_version()
{
  local VERSIONS_JSON=/tmp/vanilla-versions.json
  local VERSIONS_JSON_URL=https://launchermeta.mojang.com/mc/game/version_manifest.json

  log I "Checking the vanilla versions information... "
  wget -q -O $VERSIONS_JSON $VERSIONS_JSON_URL
  if [ $? != 0 ]; then
    log E "Failed to get the version information."
    exit 1
  fi

  local LATEST=$(jq -r '.latest.release' $VERSIONS_JSON)
  log I "The latest version of vanilla is '$LATEST'."

  case "X$VERSION" in
    X[0-9.]*)
      log I "The specified version of vanilla is '$VERSION'."
    ;;
    XLATEST|Xlatest)
      VERSION=$LATEST
      log I "The specified version of vanilla is latest '$VERSION'."
    ;;
    X)
      log I "There is no \$VERSION specification. Use the latest version: $LATEST"
      VERSION=$LATEST
    ;;
  esac
  VERSION_INFO_URL=$(jq -r ".versions[] | select(.id == \"$VERSION\").url" $VERSIONS_JSON)
  if [ -z "$VERSION_INFO_URL" -o "$VERSION_INFO_URL" = null ]; then
    log E "The specified version infomation of vanilla does not exist: \$VERSION=$VERSION"
    exit 1
  fi
}

#===============================================================================
# Installation Minecraft Vanilla Server.
#
# (depend)
#   log, check_vanilla_version
#
# (Access)
#   $INSTALL_MARKER
#   $VERSION
#   $VERSION_INFO_URL
#
# (Update)
#   file "$SERVER_DIR/.installed"
#===============================================================================
function install_vanilla
{
  resolve_vanilla_version
  if [ -e "$INSTALL_MARKER" ]; then
    INSTALLED_VERSION=$(cat "$INSTALL_MARKER" | cut -d'=' -f2)
    if [ "$INSTALLED_VERSION" = "$VERSION" ]; then
      log I "Version $VERSION is already installed."
      return
    fi
  fi
  log I "Installing the vanilla server for '$VERSION'."
  log I "Downloading '$VERSION_INFO_URL' ..."
  local INFO_JSON="/tmp/vanilla-$VERSION.json"
  wget -q -O $INFO_JSON $VERSION_INFO_URL
  local INFO=$(jq -r '.downloads.server.url,.downloads.server.sha1' $INFO_JSON)
  local URL=$(echo "$INFO" | awk 'NR==1')
  local SHA1=$(echo "$INFO" | awk 'NR==2')
  if [ $URL = null -o $SHA1 = null ]; then
    log E "Failed to get version $VERSION information."
    exit 1
  fi

  log I "Downloading '$URL' ..."
  wget -q -O $SERVER_JAR $URL
  local DL_SHA1=$(sha1sum $SERVER_JAR | awk '{ print $1 }')
  if [ "$DL_SHA1" != "$SHA1" ]; then
    log E ""
    log E "The SHA1 checksums do not match."
    log E "Expect: $SHA1"
    log E "Actual: $DL_SHA1"
    exit 1
  fi
  echo "vanilla=$VERSION" > $INSTALL_MARKER
  log I "Installation is completed."
}

#===============================================================================
# Installation Minecraft Forge Server.
#
# (depend)
#   log, resolve_vanilla_version
#
# (Access)
#   $INSTALL_MARKER
#   $VERSION
#
# (Update)
#   file "$SERVER_DIR/.installed"
#===============================================================================
function install_forge() {
  resolve_vanilla_version

  local installer=$SERVER_DIR/forge-installer.jar
  local VERSIONS_JSON=/tmp/forge-version.json
  local VERSIONS_JSON_URL=https://files.minecraftforge.net/maven/net/minecraftforge/forge/promotions_slim.json

  log I "Checking the forge versions information... "
  wget -q -O $VERSIONS_JSON $VERSIONS_JSON_URL
  if [ $? != 0 ]; then
    log E "Failed to get the version information."
    exit 1
  fi

  local homepage=$(jq -r '.homepage' $VERSIONS_JSON)
  if [ $homepage = null ]; then
    local homepage=https://files.minecraftforge.net/maven/net/minecraftforge/forge/
  fi
  local homepage=$(echo $homepage | sed 's/http/https/g')
  # Resolve version.
  case $VERSION in
    recommended)
      FORGE_VERSION=$(jq -r '.promos["recommended"]' $VERSIONS_JSON)
    ;;
    latest)
      FORGE_VERSION=$(jq -r '.promos["latest"]' $VERSIONS_JSON)
    ;;
    *)
      local recommended=$(jq -r ".promos[\"$VERSION-recommended\"]" $VERSIONS_JSON)
      local latest=$(jq -r ".promos[\"$VERSION-latest\"]" $VERSIONS_JSON)
      if [ $recommended != null ]; then
        FORGE_VERSION=$recommended
      else
        if [ $latest != null ]; then
          FORGE_VERSION=$latest
        fi
      fi
    ;;
  esac
  if [ "$FORGE_VERSION" = null ]; then
    log E "The specified version of forge does not exist: \$VERSION=$SPECIFIED_VERSION"
    exit 1
  fi
  local version=$VERSION-$FORGE_VERSION
  if [ -e "$INSTALL_MARKER" ]; then
    INSTALLED_VERSION=$(cat "$INSTALL_MARKER" | cut -d'=' -f2)
    if [ "$INSTALLED_VERSION" = "$version" ]; then
      log I "Version $version is already installed."
      return
    fi
  fi
  log I "Installing the forge server for '$version'."
  case $VERSION in
    *.*.*)
      local norm=$VERSION ;;
    *.*)
      local norm=$VERSION.0 ;;
  esac
  local urls="
    $homepage/$version/forge-$version-installer.jar
    $homepage/$version-$norm/forge-$version-$norm-installer.jar
    NOT_FOUND
  "
  for url in $urls
  do
      if [ $url == NOT_FOUND ]; then
        log E "Unable to compute URL for $url"
        exit 1
      fi
      log I "Downloading '$url' ..."
      if wget -q -O $installer $url; then
        break
      fi
  done
  mkdir -p $SERVER_DIR/mods
  java -jar $installer --installServer
  for jar in $SERVER_DIR/forge-*.jar
  do
    case $jar in
      *universal.jar)
        mv $jar $SERVER_JAR
        echo "forge=$version" > $INSTALL_MARKER
        log I "Installation is completed."
        return
      ;;
      *) ;;
    esac
  done
  log E "Unable to derive server jar for Forge"
  exit 1
}

#===============================================================================
# Installation Minecraft Server.
#
# (depend)
#   log, install_vanilla
#
# (Access)
#   $TYPE <- (default 'vanilla')
#   $WHITELIST
#   $OPS
#===============================================================================
function install()
{
  case "$SERVER_TYPE" in
    f|FORGE|forge)
      TYPE=forge
      SERVER_JAR=$SERVER_DIR/minecraft_forge_server.$VERSION.jar
      install_forge
    ;;
    v|VANILLA|vanilla)
      TYPE=vanilla
      SERVER_JAR=$SERVER_DIR/minecraft_server.$VERSION.jar
      install_vanilla
    ;;
    *)
      log E "Invalid type: \$SERVER_TYPE -> '$SERVER_TYPE'"
      log E "\$TYPE must be 'vanilla' or 'forge'."
      exit 1
    ;;
  esac
  if [ ! -e $SERVER_PROPERTIES ]; then
    log I "Creating default server.properties ..."
    cat > $SERVER_PROPERTIES << EOF
# Game
gamemode=0
force-gamemode=true
pvp=true
difficulty=1
hardcore=false

# World
level-name=world
level-type=DEFAULT
level-seed=
max-world-size=29999984
generator-settings=
generate-structures=true
max-build-height=256
spawn-npcs=true
spawn-monsters=true
spawn-animals=true

# Players
allow-flight=false
allow-nether=true
player-idle-timeout=0

# Ops
op-permission-level=4
enable-rcon=false
enable-query=false
enable-command-block=false

# Connections
prevent-proxy-connections=false
network-compression-threshold=256
snooper-enabled=true

# Server
server-ip=
server-port=25565
online-mode=true
resource-pack=
resource-pack-sha1=
max-players=20
max-tick-time=60000
view-distance=10
white-list=false
motd=A Minecraft Server
EOF
  fi
}

#===============================================================================
# Metric memory infomations (For Alpine on Docker)
#
# (Update)
#   $MEMINFO  <- Total memory size.
#   $MEMLIMIT <- Limited memory size by cgroup.
#===============================================================================
function metric_alpine_docker()
{
  local MEMINFO_KB=$(cat /proc/meminfo | grep MemTotal | awk '{print $2}')
  MEMINFO=$(expr $MEMINFO_KB \* 1024)
  MEMLIMIT=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
}

#===============================================================================
# Automatically configure JVM options.
#
# (depend)
#   log, metric_alpine_docker
#
# (access)
#   $JVM_MEMORY
#   $JVM_GC
#
# (update)
#   $MAX_MEMORY_SIZE            <- Maximum allocate memory size.
#   $JVM_RECOMMEND_MEMORY_SIZE  <- 90% of max size.
#   $JVM_RECOMMEND_GC_TYPE
#   $JVM_MEMORY
#   $JVM_GC
#   $JVM_OPTS
#===============================================================================
function autoconf_jvm()
{
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
  log I "Automatically configuration JVM options ..."
  metric_alpine_docker
  local MEMINFO_MB=$(expr $MEMINFO / 1024 / 1024)
  local MEMLIMIT_MB=$(expr $MEMLIMIT / 1024 / 1024)
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
  if [ "$JVM_MEMORY" = auto ]; then JVM_MEMORY=$JVM_RECOMMEND_MEMORY_SIZE; fi
  local JVM_INIT_MEMORY=${JVM_INIT_MEMORY:-$JVM_MEMORY}
  local JVM_MAX_MEMORY=${JVM_MAX_MEMORY:-$JVM_MEMORY}
  case "X$JVM_GC" in
    X | Xauto        ) JVM_GC=$JVM_RECOMMEND_GC_TYPE ;;
    XG1GC            ) JVM_GC=G1GC                   ;;
    XConcMarkSweepGC ) JVM_GC=ConcMarkSweepGC        ;;
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
  JVM_OPTS=$(echo $JVM_OPTS | tr '\n' ' ')
}

#===============================================================================
# Server Starting
#
# (depend)
#   log, autoconf_jvm
#
# (access)
#   $JVM_OPTS   <- (default 'auto')
#   $SERVER_DIR
#   $SERVER_JAR
#   $INSTALL_MARKER
#===============================================================================
function start()
{
  if [ "$JVM_OPTS" = auto ]; then
    autoconf_jvm
  fi
  log I "JVM options: $JVM_OPTS"
  log I "Starting server..."

  exec java $JVM_OPTS -jar $SERVER_JAR "$@" nogui
}

function main()
{
  for OPT in "$@"
  do
    case $OPT in
      -q|--quiet          ) QUIET=true          ; shift 1 ;;
      -d|--server-dir     ) SERVER_DIR=${2}     ; shift 2 ;;
      -t|--server-type    ) SERVER_TYPE=${2}    ; shift 2 ;;
      -v|--server-version ) SERVER_VERSION=${2} ; shift 2 ;;
      --jvm-opts          ) JVM_OPTS=${2}       ; shift 2 ;;
      --jvm-memory        ) JVM_MEMORY=${2}     ; shift 2 ;;
      --jvm-gc            ) JVM_GC=${2}         ; shift 2 ;;
      *)
        if [ -n $1 ]; then
          log W "Unknown option: $1"
          shift
        fi
      ;;
    esac
  done
  QUIET=${QUIET:-false}
  SERVER_DIR=${SERVER_DIR:-$HOME/server}
  SERVER_TYPE=${SERVER_TYPE:-vanilla}
  SERVER_VERSION=${SERVER_VERSION:-latest}
  JVM_OPTS=${JVM_OPTS:-auto}
  JVM_MEMORY=${JVM_MEMORY:-auto}
  JVM_GC=${JVM_GC:-auto}

  SERVER_PROPERTIES=$SERVER_DIR/server.properties
  INSTALL_MARKER=$SERVER_DIR/.installed
  mkdir -p $SERVER_DIR

  cd $SERVER_DIR
  log I "Server directory is '$SERVER_DIR'."

  check_eula && install && start
}

main $@

