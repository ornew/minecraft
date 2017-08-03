FROM openjdk:8u131-jre-alpine
LABEL maintainer "Arata Furukawa <info@ornew.net>"
CMD /bin/bash

RUN set -vx \
  && apk add -U \
    bash openssl jq \
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

ENTRYPOINT [ "/home/minecraft/start.sh" ]

ENV UID=1000 \
  GID=1000 \
  MOTD="A Minecraft Server Powered by Docker" \
  JVM_XX_OPTS="-XX:+UseG1GC" \
  MEMORY="1G" \
  TYPE=VANILLA \
  VERSION= \
  FORGEVERSION=RECOMMENDED \
  LEVEL=world \
  PVP=true \
  DIFFICULTY=easy \
  ENABLE_RCON=true \
  LEVEL_TYPE=DEFAULT \
  GENERATOR_SETTINGS= \
  WORLD= \
  MODPACK= \
  ONLINE_MODE=TRUE \
  CONSOLE=true
