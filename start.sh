#!/bin/bash

set -e
#sed -i "/^minecraft/s/:1000:1000:/:${UID}:${GID}:/g" /etc/passwd
#sed -i "/^minecraft/s/:1000:/:${GID}:/g" /etc/group

echo $HOME
HOME=/home/minecraft
SERVER_DIR=~/server
SERVER_JAR=$SERVER_DIR/server.jar
mkdir -p $SERVER_DIR
cd $SERVER_DIR

if [ ! -e "$SERVER_DIR/eula.txt" ]; then
  if [ "$EULA" != "" ]; then
    echo "# Generated via Docker on $(date)" > "$SERVER_DIR/eula.txt"
    echo "eula=$EULA" >> "$SERVER_DIR/eula.txt"
  else
    echo ""
    echo "Please accept the Minecraft EULA at"
    echo "  https://account.mojang.com/documents/minecraft_eula"
    echo "by adding the following immediately after 'docker run':"
    echo "  -e EULA=TRUE"
    echo ""
    exit 1
  fi
fi

VANILLA_VERSIONS_JSON=/tmp/vanilla-versions.json
VANILLA_VERSIONS_JSON_URL=https://launchermeta.mojang.com/mc/game/version_manifest.json

echo "Checking the vanilla versions information... "
wget -q -O $VANILLA_VERSIONS_JSON $VANILLA_VERSIONS_JSON_URL
if [ $? != 0 ]; then
  echo "Failed to get the version information."
  exit 1
fi

VANILLA_LATEST=$(jq -r '.latest.release' $VANILLA_VERSIONS_JSON)
echo "The latest version of vanilla is '$VANILLA_LATEST'."

case "X$VERSION" in
  X[0-9.]*)
    echo "The specified version of vanilla is '$VERSION'."
  ;;
  XLATEST|Xlatest)
    VERSION=$VANILLA_LATEST
    echo "The specified version of vanilla is '$VERSION'."
  ;;
  X)
    echo 'There is no $VERSION specification. Use the latest version.'
    VERSION=$VANILLA_LATEST
  ;;
esac
VANILLA_VERSION_INFO_URL=$(jq -r ".versions[] | select(.id == \"$VERSION\").url" $VANILLA_VERSIONS_JSON)
if [ -z "$VANILLA_VERSION_INFO_URL" ]; then
  echo "The specified version infomation of vanilla does not exist: \$VERSION=$VERSION"
  exit 1
fi

function installVanilla {
  echo "Installing the vanilla server for '$VERSION'."
  printf "Downloading '$VANILLA_VERSION_INFO_URL' ..."
  local _info="/tmp/vanilla-$VANILLA_VERSION.json"
  wget -q -O $_info $VANILLA_VERSION_INFO_URL
  local _url=$(jq -r '.downloads.server.url' $_info)
  local _sha1=$(jq -r '.downloads.server.sha1' $_info)
  if [ -z $_url -o -z $_sha1 ]; then
    echo "Failed to get version $VERSION information."
    exit 1
  fi
  echo "done"

  printf "Downloading '$_url' ..."
  wget -q -O $SERVER_JAR $_url
  local _check_sha1=($(sha1sum $SERVER_JAR))
  if [ "$_check_sha1" != "$_sha1" ]; then
    echo ""
    echo "The SHA1 checksums do not match."
    echo "Expected: $_sha1"
    echo "Actual: $_check_sha1"
    exit 1
  fi
  echo "done"
  echo "Installation is completed."
}

TYPE=${TYPE:-vanilla}
case "$TYPE" in
  f|FORGE|forge)
    TYPE=forge
    installForge
  ;;
  v|VANILLA|vanilla)
    TYPE=vanilla
    installVanilla
  ;;
  *)
    echo "Invalid type: \$TYPE -> '$TYPE'"
    echo "\$TYPE must be 'vanilla' or 'forge'."
    exit 1
  ;;
esac

if [ -n "$OPS" -a ! -e ops.txt.converted ]; then
  echo "Setting ops"
  echo $OPS | awk -v RS=, '{print}' >> ops.txt
fi

if [ -n "$WHITELIST" -a ! -e white-list.txt.converted ]; then
  echo "Setting whitelist"
  echo $WHITELIST | awk -v RS=, '{print}' >> white-list.txt
fi

echo "Setting initial memory to ${INIT_MEMORY:-${MEMORY}} and max to ${MAX_MEMORY:-${MEMORY}}"
JVM_OPTS="-Xms${INIT_MEMORY:-${MEMORY}} -Xmx${MAX_MEMORY:-${MEMORY}} ${JVM_OPTS}"

if [ -f "$SERVER_DIR/bootstrap.txt" ]; then
  exec java $JVM_XX_OPTS $JVM_OPTS -jar $SERVER_JAR "$@" nogui < /data/bootstrap.txt
else
  exec java $JVM_XX_OPTS $JVM_OPTS -jar $SERVER_JAR "$@" nogui
fi

