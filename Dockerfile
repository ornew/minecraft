FROM openjdk:jre-alpine
LABEL maintainer "Arata Furukawa <info@ornew.net>"

ENTRYPOINT [ "/bin/sh", "/home/minecraft/start.sh" ]

EXPOSE 25565

RUN set -vx \
  && apk add -U \
    openssl jq \
  && rm -rf /var/cache/apk/* \
  && addgroup -g 1000 minecraft \
  && adduser -Ss /bin/false -u 1000 -G minecraft -h /home/minecraft minecraft

COPY start.sh "/home/minecraft/start.sh"

RUN set -vx \
  && chown -R minecraft:minecraft /home/minecraft \
  && chmod -R u+w /home/minecraft

VOLUME [ "/home/minecraft" ]
WORKDIR "/home/minecraft"

USER minecraft

