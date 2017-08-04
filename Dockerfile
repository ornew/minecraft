FROM openjdk:jre-alpine
LABEL maintainer "Arata Furukawa <info@ornew.net>"

RUN set -vx \
  && apk add -U \
    openssl jq \
  && rm -rf /var/cache/apk/* \
  && addgroup -g 1000 minecraft \
  && adduser -Ss /bin/false -u 1000 -G minecraft -h /home/minecraft minecraft

COPY start.sh "/home/minecraft/start.sh"
COPY server.properties.default "/home/minecraft/server.properties.default"

RUN set -vx \
  && chown -R minecraft:minecraft /home/minecraft \
  && chmod -R u+w /home/minecraft

EXPOSE 25565
USER minecraft

VOLUME [ "/home/minecraft" ]
WORKDIR "/home/minecraft"

ENTRYPOINT [ "/bin/sh", "/home/minecraft/start.sh" ]

ENV UID=1000 \
  GID=1000 \
  MOTD="A Minecraft Server Powered by Docker" \
  JVM_OPTS=auto \
  TYPE=VANILLA \
  VERSION= \
  FORGEVERSION=RECOMMENDED \
  LEVEL=world \
  PVP=true \
  DIFFICULTY=easy \
  LEVEL_TYPE=DEFAULT \
  GENERATOR_SETTINGS= \
  WORLD= \
  ONLINE_MODE=TRUE
