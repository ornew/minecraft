#!/bin/sh

set -e

TAG=${TAG:-"ornew/minecraft"}
function log() {
  case $1 in
    [eE]*) local _level=E; local _color=31 ;;
    [wW]*) local _level=W; local _color=33 ;;
    *)     local _level=I; local _color= ;;
  esac
  echo -e "\e[${_color}m[$(date -u)] ${TAG} ${_level}: ${@:1}\e[m"
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
  printf "Downloading '$VANILLA_VERSION_INFO_URL' ..."
  local _info_json="/tmp/vanilla-$VANILLA_VERSION.json"
  wget -q -O $_info_json $VANILLA_VERSION_INFO_URL
  local _info=$(jq -r '.downloads.server.url,.downloads.server.sha1' $_info_json)
  local _url=$(echo "$_info" | awk 'NR==1')
  local _sha1=$(echo "$_info" | awk 'NR==2')
  if [ $_url = null -o $_sha1 = null ]; then
    log E "Failed to get version $VERSION information."
    exit 1
  fi
  log I "done"

  printf "Downloading '$_url' ..."
  wget -q -O $SERVER_JAR $_url
  local _check_sha1=$(sha1sum $SERVER_JAR | awk '{ print $1 }')
  if [ "$_check_sha1" != "$_sha1" ]; then
    log E ""
    log E "The SHA1 checksums do not match."
    log E "Expect: $_sha1"
    log E "Actual: $_check_sha1"
    exit 1
  fi
  log I "done"
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

log I "Setting initial memory to ${INIT_MEMORY:-${MEMORY}} and max to ${MAX_MEMORY:-${MEMORY}}"
JVM_OPTS="-Xms${INIT_MEMORY:-${MEMORY}} -Xmx${MAX_MEMORY:-${MEMORY}} ${JVM_OPTS}"

if [ -f "$SERVER_DIR/bootstrap.txt" ]; then
  exec java $JVM_XX_OPTS $JVM_OPTS -jar $SERVER_JAR "$@" nogui < /data/bootstrap.txt
else
  exec java $JVM_XX_OPTS $JVM_OPTS -jar $SERVER_JAR "$@" nogui
fi

