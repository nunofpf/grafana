# syntax=docker/dockerfile:1.7-labs

# to maintain formatting of multiline commands in vscode, add the following to settings.json:
# "docker.languageserver.formatter.ignoreMultilineInstructions": true

ARG GO_IMAGE=go-builder-base
ARG JS_IMAGE=js-builder-base
ARG JS_PLATFORM=linux/amd64

# Default to building locally
ARG GO_SRC=go-builder
ARG JS_SRC=js-builder

# Dependabot cannot update dependencies listed in ARGs
# By using FROM instructions we can delegate dependency updates to dependabot
FROM alpine:3.24.1 AS alpine-base
FROM ubuntu:24.04 AS ubuntu-base
FROM golang:1.26.5-alpine AS go-builder-base
FROM --platform=${JS_PLATFORM} node:24-alpine AS js-builder-base
FROM gcr.io/distroless/static-debian13 AS distroless-base


################### PLUGINS COMPILATION - Start ###################
FROM proxy.criticalmanufacturing.io/golang:alpine3.21 AS im_go
USER root
RUN apk add --no-cache git
RUN git clone https://github.com/criticalmanufacturing/grafana-odata-datasource.git /go/src/odata -b feature-odata-query-string --depth 1
WORKDIR /go/src/odata
### Compiling backend
RUN go "build" "-o" "dist/cmf_backend_odata_plugin_linux_amd64" "-ldflags" "-w -s -extldflags \"-static\" -X 'github.com/grafana/grafana-plugin-sdk-go/build.buildInfoJSON={\"time\":1677258377824,\"version\":\"1.0.0\",\"repo\":\"CMF\",\"branch\":\"Deploy\",\"hash\":\"83d7fe05b465008972bea160643473286f89af9e6\"}' -X 'main.version=1.0.0' -X 'main.branch=Deploy' -X 'main.commit=abcd'" "./pkg"
### Compiling frontend odata
FROM proxy.criticalmanufacturing.io/ubuntu:22.04 AS im_node
USER root
COPY ./public.gpg.key /opt/public.gpg.key
RUN apt-get update \
    && apt-get install -y curl gnupg \
    && apt-key add /opt/public.gpg.key \
    && rm -rf /var/lib/apt/lists/*
RUN apt update
RUN apt install curl -y
RUN curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add -
RUN echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list
RUN apt-get update
RUN apt-get install yarn -y
RUN apt install git -y
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y nodejs
RUN git clone https://github.com/criticalmanufacturing/grafana-odata-datasource.git /usr/src/odata -b feature-odata-query-string --depth 1
WORKDIR /usr/src/odata
RUN yarn install
RUN yarn build
################### PLUGINS COMPILATION - End ###################

# Javascript build stage
FROM --platform=${JS_PLATFORM} ${JS_IMAGE} AS js-builder
ARG JS_NODE_ENV=production
ARG JS_YARN_INSTALL_FLAG=--immutable
ARG JS_YARN_BUILD_FLAG=build

ENV NODE_OPTIONS=--max_old_space_size=8000

WORKDIR /tmp/grafana

RUN apk add --no-cache make build-base python3

COPY package.json project.json nx.json yarn.lock .yarnrc.yml ./
COPY .yarn .yarn
COPY packages packages
COPY e2e-playwright e2e-playwright
COPY public public
COPY LICENSE ./
COPY conf/defaults.ini ./conf/defaults.ini

#
# Set the node env according to defaults or argument passed
#
ENV NODE_ENV=${JS_NODE_ENV}
#
RUN if [ "$JS_YARN_INSTALL_FLAG" = "" ]; then \
    yarn install; \
  else \
    yarn install --immutable; \
  fi

COPY tsconfig.json eslint.config.js .editorconfig .browserslistrc .prettierrc.js ./
COPY scripts scripts
COPY emails emails

# Set the build argument according to default or argument passed
RUN yarn ${JS_YARN_BUILD_FLAG}

# Golang build stage
FROM ${GO_IMAGE} AS go-builder

ARG COMMIT_SHA=""
ARG BUILD_BRANCH=""
ARG SOURCE_DATE_EPOCH=""
ARG GO_BUILD_TAGS="oss"
ARG WIRE_TAGS="oss"

RUN if grep -i -q alpine /etc/issue; then \
  apk add --no-cache \
  bash \
  # Install build dependencies
  make git; \
  fi

WORKDIR /tmp/grafana

COPY go.mod go.sum go.work go.work.sum ./
COPY .citools .citools

# Copy go.mod/go.sum from each workspace module for dependency caching.
# Only dependency file changes invalidate the go mod download cache layer.
# Uses --parents to preserve directory structure with fewer COPY directives.
COPY --parents **/go.mod **/go.sum ./

RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

# Copy full source
COPY embed.go Makefile package.json ./
COPY cue.mod cue.mod
COPY kinds kinds
COPY local local
COPY packages/grafana-schema packages/grafana-schema
COPY packages/grafana-data/src/themes/themeDefinitions packages/grafana-data/src/themes/themeDefinitions
COPY public/app/plugins public/app/plugins
COPY public/api-merged.json public/api-merged.json
COPY pkg pkg
COPY apps apps
COPY scripts scripts
COPY conf conf
COPY .github .github

ENV COMMIT_SHA=${COMMIT_SHA}
ENV BUILD_BRANCH=${BUILD_BRANCH}
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    make build-go GO_BUILD_TAGS=${GO_BUILD_TAGS} WIRE_TAGS=${WIRE_TAGS}

RUN mkdir -p data/plugins-bundled

# From-tarball build stage
FROM alpine-base AS tgz-builder

WORKDIR /tmp/grafana

ARG GRAFANA_TGZ="grafana-latest.linux-x64-musl.tar.gz"

COPY ${GRAFANA_TGZ} /tmp/grafana.tar.gz

# add -v to make tar print every file it extracts
RUN tar x -z -f /tmp/grafana.tar.gz --strip-components=1

RUN mkdir -p data/plugins-bundled

# helpers for COPY --from
FROM ${GO_SRC} AS go-src
FROM ${JS_SRC} AS js-src

# Binaries and frontend assets — shared by all 6 variants (full and slim) via COPY --link.
# No plugins here; keeping this stage SLIM-agnostic ensures the layer hash is identical
# across every build regardless of the SLIM flag.
FROM alpine-base AS grafana-assets

ENV GF_PATHS_HOME="/usr/share/grafana"
WORKDIR $GF_PATHS_HOME

COPY --from=go-src /tmp/grafana/bin/grafana* /tmp/grafana/bin/*/grafana* ./bin/
COPY --from=js-src /tmp/grafana/public ./public
COPY --from=js-src /tmp/grafana/LICENSE ./

# Bundled plugins — shared by the 3 full (non-slim) variants, and by the 3 slim variants
# among themselves (as an empty directory). Kept separate from grafana-assets so the two
# groups each get their own shared layer rather than a single mixed one.
FROM alpine-base AS grafana-plugins

ARG GF_UID="472"
ARG GF_GID="0"

ENV GF_PATHS_HOME="/usr/share/grafana"
WORKDIR $GF_PATHS_HOME

RUN mkdir -p data/plugins-bundled

ARG SLIM=false
RUN --mount=type=bind,from=go-src,source=/tmp/grafana/data/plugins-bundled,target=/mnt/plugins-bundled \
  { [ "$SLIM" = "true" ] || cp -a /mnt/plugins-bundled/. ./data/plugins-bundled/; } && \
  chown -R "${GF_UID}:${GF_GID}" data/plugins-bundled && \
  chmod -R 777 data/plugins-bundled

# Intermediate filesystem setup for the distroless target.
# Uses an Alpine shell to create directories, users, and config files
# since distroless has no shell. No network access required.
FROM alpine-base AS distroless-prep

ARG GF_UID="472"
ARG GF_GID="0"

ENV PATH="/usr/share/grafana/bin:$PATH" \
  GF_PATHS_CONFIG="/etc/grafana/grafana.ini" \
  GF_PATHS_DATA="/var/lib/grafana" \
  GF_PATHS_HOME="/usr/share/grafana" \
  GF_PATHS_LOGS="/var/log/grafana" \
  GF_PATHS_PLUGINS="/var/lib/grafana/plugins" \
  GF_PATHS_PROVISIONING="/etc/grafana/provisioning"

WORKDIR $GF_PATHS_HOME

COPY --from=go-src /tmp/grafana/conf ./conf
COPY --from=go-src /tmp/grafana/bin/grafana* /tmp/grafana/bin/*/grafana* ./bin/

RUN if [ ! "$(getent group "$GF_GID")" ]; then \
  addgroup -S -g $GF_GID grafana; \
  fi && \
  GF_GID_NAME=$(getent group $GF_GID | cut -d':' -f1) && \
  mkdir -p "$GF_PATHS_HOME/.aws" \
  "$GF_PATHS_PROVISIONING/datasources" \
  "$GF_PATHS_PROVISIONING/dashboards" \
  "$GF_PATHS_PROVISIONING/notifiers" \
  "$GF_PATHS_PROVISIONING/plugins" \
  "$GF_PATHS_PROVISIONING/access-control" \
  "$GF_PATHS_PROVISIONING/alerting" \
  "$GF_PATHS_LOGS" \
  "$GF_PATHS_PLUGINS" \
  "$GF_PATHS_HOME/data/plugins-bundled" \
  "$GF_PATHS_DATA" \
  /etc/grafana && \
  adduser -S -u $GF_UID -G "$GF_GID_NAME" grafana && \
  cp conf/sample.ini "$GF_PATHS_CONFIG" && \
  cp conf/ldap.toml /etc/grafana/ldap.toml && \
  chown -R "grafana:$GF_GID_NAME" "$GF_PATHS_DATA" "$GF_PATHS_HOME/.aws" "$GF_PATHS_LOGS" "$GF_PATHS_PLUGINS" "$GF_PATHS_PROVISIONING" "$GF_PATHS_HOME/data/plugins-bundled" && \
  chmod -R 777 "$GF_PATHS_DATA" "$GF_PATHS_HOME/.aws" "$GF_PATHS_LOGS" "$GF_PATHS_PLUGINS" "$GF_PATHS_PROVISIONING" "$GF_PATHS_HOME/data/plugins-bundled" && \
  printf 'root:x:0:0:root:/root:/sbin/nologin\nnobody:x:65534:65534:nobody:/nonexistent:/sbin/nologin\ngrafana:x:%s:%s::/usr/share/grafana:/sbin/nologin\n' "$GF_UID" "$GF_GID" > /tmp/distroless-passwd && \
  printf 'root:x:0:\nnobody:x:65534:\n' > /tmp/distroless-group && \
  if [ "$GF_GID" != "0" ]; then printf 'grafana:x:%s:\n' "$GF_GID" >> /tmp/distroless-group; fi && \
  grafana server --homepath="$GF_PATHS_HOME" -v | sed -e 's/Version //' > /.grafana-version && \
  chmod 644 /.grafana-version

# Alpine final stage
FROM alpine-base AS final-alpine

LABEL maintainer="Grafana Labs <hello@grafana.com>"
LABEL org.opencontainers.image.source="https://github.com/grafana/grafana"

ARG GF_UID="472"
ARG GF_GID="0"

ENV PATH="/usr/share/grafana/bin:$PATH" \
  GF_PATHS_CONFIG="/etc/grafana/grafana.ini" \
  GF_PATHS_DATA="/var/lib/grafana" \
  GF_PATHS_HOME="/usr/share/grafana" \
  GF_PATHS_LOGS="/var/log/grafana" \
  GF_PATHS_PLUGINS="/var/lib/grafana/plugins" \
  GF_PATHS_PROVISIONING="/etc/grafana/provisioning"

WORKDIR $GF_PATHS_HOME

RUN apk add --no-cache ca-certificates bash bubblewrap curl tzdata musl-utils && \
  apk info -vv | sort

# glibc support for alpine x86_64 only
# docker run --rm --env STDOUT=1 sgerrand/glibc-builder 2.40 /usr/glibc-compat > glibc-bin-2.40.tar.gz
ARG GLIBC_VERSION=2.40

RUN if [ "$(arch)" = "x86_64" ]; then \
  curl -fsSL "https://dl.grafana.com/glibc/glibc-bin-$GLIBC_VERSION.tar.gz" | tar zxf - -C / \
  usr/glibc-compat/lib/ld-linux-x86-64.so.2 \
  usr/glibc-compat/lib/libc.so.6 \
  usr/glibc-compat/lib/libdl.so.2 \
  usr/glibc-compat/lib/libm.so.6 \
  usr/glibc-compat/lib/libpthread.so.0 \
  usr/glibc-compat/lib/librt.so.1 \
  usr/glibc-compat/lib/libresolv.so.2 && \
  mkdir /lib64 && \
  ln -s /usr/glibc-compat/lib/ld-linux-x86-64.so.2 /lib64; \
  fi

COPY --from=go-src /tmp/grafana/conf ./conf

RUN if [ ! "$(getent group "$GF_GID")" ]; then \
  addgroup -S -g $GF_GID grafana; \
  fi && \
  GF_GID_NAME=$(getent group $GF_GID | cut -d':' -f1) && \
  mkdir -p "$GF_PATHS_HOME/.aws" && \
  adduser -S -u $GF_UID -G "$GF_GID_NAME" grafana && \
  mkdir -p "$GF_PATHS_PROVISIONING/datasources" \
  "$GF_PATHS_PROVISIONING/dashboards" \
  "$GF_PATHS_PROVISIONING/notifiers" \
  "$GF_PATHS_PROVISIONING/plugins" \
  "$GF_PATHS_PROVISIONING/access-control" \
  "$GF_PATHS_PROVISIONING/alerting" \
  "$GF_PATHS_LOGS" \
  "$GF_PATHS_PLUGINS" \
  "$GF_PATHS_HOME/data/plugins-bundled" \
  "$GF_PATHS_DATA" && \
  cp conf/sample.ini "$GF_PATHS_CONFIG" && \
  cp conf/ldap.toml /etc/grafana/ldap.toml && \
  chown -R "grafana:$GF_GID_NAME" "$GF_PATHS_DATA" "$GF_PATHS_HOME/.aws" "$GF_PATHS_LOGS" "$GF_PATHS_PLUGINS" "$GF_PATHS_PROVISIONING" "$GF_PATHS_HOME/data/plugins-bundled" && \
  chmod -R 777 "$GF_PATHS_DATA" "$GF_PATHS_HOME/.aws" "$GF_PATHS_LOGS" "$GF_PATHS_PLUGINS" "$GF_PATHS_PROVISIONING" "$GF_PATHS_HOME/data/plugins-bundled"

COPY --link --from=grafana-assets /usr/share/grafana /usr/share/grafana
COPY --link --from=grafana-plugins /usr/share/grafana/data /usr/share/grafana/data

RUN grafana server -v | sed -e 's/Version //' > /.grafana-version
RUN chmod 644 /.grafana-version

EXPOSE 3000

ARG RUN_SH=./packaging/docker/run.sh

COPY ${RUN_SH} /run.sh

USER "$GF_UID"
ENTRYPOINT [ "/run.sh" ]

# Ubuntu final stage — use --target=final-ubuntu to select this variant
FROM ubuntu-base AS final-ubuntu

LABEL maintainer="Grafana Labs <hello@grafana.com>"
LABEL org.opencontainers.image.source="https://github.com/grafana/grafana"

ARG GF_UID="472"
ARG GF_GID="0"

ENV PATH="/usr/share/grafana/bin:$PATH" \
  GF_PATHS_CONFIG="/etc/grafana/grafana.ini" \
  GF_PATHS_DATA="/var/lib/grafana" \
  GF_PATHS_HOME="/usr/share/grafana" \
  GF_PATHS_LOGS="/var/log/grafana" \
  GF_PATHS_PLUGINS="/var/lib/grafana/plugins" \
  GF_PATHS_PROVISIONING="/etc/grafana/provisioning"

WORKDIR $GF_PATHS_HOME

RUN DEBIAN_FRONTEND=noninteractive apt-get update && \
  apt-get install -y ca-certificates curl tzdata musl && \
  apt-get autoremove -y && \
  rm -rf /var/lib/apt/lists/*

COPY --from=go-src /tmp/grafana/conf ./conf

RUN if [ ! "$(getent group "$GF_GID")" ]; then \
  groupadd --system --gid $GF_GID grafana; \
  fi && \
  GF_GID_NAME=$(getent group $GF_GID | cut -d':' -f1) && \
  mkdir -p "$GF_PATHS_HOME/.aws" && \
  useradd --system --uid $GF_UID --gid "$GF_GID_NAME" --create-home grafana && \
  mkdir -p "$GF_PATHS_PROVISIONING/datasources" \
  "$GF_PATHS_PROVISIONING/dashboards" \
  "$GF_PATHS_PROVISIONING/notifiers" \
  "$GF_PATHS_PROVISIONING/plugins" \
  "$GF_PATHS_PROVISIONING/access-control" \
  "$GF_PATHS_PROVISIONING/alerting" \
  "$GF_PATHS_LOGS" \
  "$GF_PATHS_PLUGINS" \
  "$GF_PATHS_HOME/data/plugins-bundled" \
  "$GF_PATHS_DATA" && \
  cp conf/sample.ini "$GF_PATHS_CONFIG" && \
  cp conf/ldap.toml /etc/grafana/ldap.toml && \
  chown -R "grafana:$GF_GID_NAME" "$GF_PATHS_DATA" "$GF_PATHS_HOME/.aws" "$GF_PATHS_LOGS" "$GF_PATHS_PLUGINS" "$GF_PATHS_PROVISIONING" "$GF_PATHS_HOME/data/plugins-bundled" && \
  chmod -R 777 "$GF_PATHS_DATA" "$GF_PATHS_HOME/.aws" "$GF_PATHS_LOGS" "$GF_PATHS_PLUGINS" "$GF_PATHS_PROVISIONING" "$GF_PATHS_HOME/data/plugins-bundled"

COPY --link --from=grafana-assets /usr/share/grafana /usr/share/grafana
COPY --link --from=grafana-plugins /usr/share/grafana/data /usr/share/grafana/data

RUN grafana server -v | sed -e 's/Version //' > /.grafana-version
RUN chmod 644 /.grafana-version

EXPOSE 3000

###################### HANDLING CMF SPECIFIC DATA - START ######################
### Env variables for grafana plugins
ENV GF_INSTALL_PLUGINS= \
    GF_PATHS_CONFIG=/etc/grafana/grafana.ini \
    GF_PATHS_DATA=/var/lib/grafana \
    GF_PATHS_HOME=/usr/share/grafana \
    GF_PATHS_LOGS=/var/log/grafana \
    GF_PATHS_PLUGINS=/data/grafana/plugins \
    GF_PATHS_PROVISIONING=/etc/grafana/provisioning \
    GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS="criticalmanufacturing-odata-datasource"

### Copy CMF plugin to the plugin directory
RUN mkdir -p /data/grafana/plugins/criticalmanufacturing-odata-datasource
COPY --from=im_node /usr/src/odata/dist/ /data/grafana/plugins/criticalmanufacturing-odata-datasource
COPY --from=im_go /go/src/odata/dist/cmf_backend_odata_plugin_linux_amd64 /data/grafana/plugins/criticalmanufacturing-odata-datasource/
RUN chmod u+x /data/grafana/plugins/criticalmanufacturing-odata-datasource/cmf_backend_odata_plugin_linux_amd64
RUN grafana cli --pluginsDir "/data/grafana/plugins" plugins install retrodaredevil-wildgraphql-datasource 1.6.1
RUN grafana cli --pluginsDir "/data/grafana/plugins" plugins install volkovlabs-echarts-panel 6.4.1
RUN grafana cli --pluginsDir "/data/grafana/plugins" plugins install gapit-htmlgraphics-panel 2.2.1
RUN grafana cli --pluginsDir "/data/grafana/plugins" plugins install grafana-clickhouse-datasource 4.10.2
###################### HANDLING CMF SPECIFIC DATA - END ######################

ARG RUN_SH=./packaging/docker/run.sh

COPY ${RUN_SH} /run.sh

USER root
# https://learn.microsoft.com/en-us/dotnet/core/runtime-config/globalization
# avoid our CMFEntrypoint to throw this error: Couldn't find a valid ICU package installed on the system
# caused by missing package libicu63 in this image
# this need to be set as environment variable on all base images
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
# License
COPY --from=dev.criticalmanufacturing.io/criticalmanufacturing/base/ubi9:12.0-dev /licenses /licenses
# CmfEntrypoint
COPY --from=dev.criticalmanufacturing.io/criticalmanufacturing/base/ubi9:12.0-dev /usr/share/CmfEntrypoint /usr/share/CmfEntrypoint
COPY ./packaging/docker/link_admin_oauth.sh /link_admin_oauth.sh
RUN chmod +x /link_admin_oauth.sh
RUN apt-get update \
    && apt-get install -y gnupg wget sqlite3 \
    && wget http://ftp.de.debian.org/debian/pool/main/i/icu/libicu67_67.1-7_amd64.deb \
    && dpkg -i libicu67_67.1-7_amd64.deb \
    && rm libicu67_67.1-7_amd64.deb \
    && wget http://ftp.de.debian.org/debian/pool/main/o/openssl/libssl1.1_1.1.1w-0+deb11u1_amd64.deb \
    && dpkg -i libssl1.1_1.1.1w-0+deb11u1_amd64.deb \
    && rm libssl1.1_1.1.1w-0+deb11u1_amd64.deb \
    && rm -rf /var/lib/apt/lists/*
WORKDIR $GF_PATHS_HOME
USER root
RUN chown -R $GF_UID:$GF_GID "$GF_PATHS_DATA" "$GF_PATHS_HOME" "$GF_PATHS_LOGS" "$GF_PATHS_PLUGINS" "$GF_PATHS_PROVISIONING" && \
    chmod -R 775 "$GF_PATHS_DATA" "$GF_PATHS_HOME" "$GF_PATHS_LOGS" "$GF_PATHS_PLUGINS" "$GF_PATHS_PROVISIONING"

USER "$GF_UID"
ENTRYPOINT [ "/usr/share/CmfEntrypoint/CmfEntrypoint", \
      "--process-secrets", \
      "--layer=grafana", \
      "--target-directory=/etc/grafana/provisioning" ,\
      "--exec-script-async", "/link_admin_oauth.sh", \
      "--" ,\
      "/run.sh" ]

# Distroless final stage — use --target=final-distroless to select this variant.
# No shell, no package manager, no OS utilities: significantly reduces CVE surface.
# Requires a static binary (CGO_ENABLED=0). The run.sh entrypoint is replaced by a
# direct grafana server invocation, so these run.sh features are unavailable:
#   - GF_*__FILE secret expansion (reading config values from mounted secret files)
#   - AWS credential file generation from GF_AWS_* env vars
#   - GF_INSTALL_PLUGINS (deprecated; use GF_PLUGINS_PREINSTALL instead)
# GF_PATHS_* env vars work normally — they are not overridden by cfg: flags in this entrypoint.
#
# Filesystem layout (dirs, users, config) is prepared by distroless-prep and
# binaries/assets are copied directly from go-src/js-src. No Alpine OS packages,
# libraries, or network downloads are included.
FROM distroless-base AS final-distroless

LABEL maintainer="Grafana Labs <hello@grafana.com>"
LABEL org.opencontainers.image.source="https://github.com/grafana/grafana"

ARG GF_UID="472"
ARG GF_GID="0"

ENV PATH="/usr/share/grafana/bin:$PATH" \
  GF_PATHS_CONFIG="/etc/grafana/grafana.ini" \
  GF_PATHS_DATA="/var/lib/grafana" \
  GF_PATHS_HOME="/usr/share/grafana" \
  GF_PATHS_LOGS="/var/log/grafana" \
  GF_PATHS_PLUGINS="/var/lib/grafana/plugins" \
  GF_PATHS_PROVISIONING="/etc/grafana/provisioning"

WORKDIR $GF_PATHS_HOME

COPY --from=distroless-prep /tmp/distroless-passwd /etc/passwd
COPY --from=distroless-prep /tmp/distroless-group /etc/group
COPY --from=distroless-prep /etc/grafana /etc/grafana
COPY --chown=${GF_UID}:${GF_GID} --from=distroless-prep /var/lib/grafana /var/lib/grafana
COPY --chown=${GF_UID}:${GF_GID} --from=distroless-prep /var/log/grafana /var/log/grafana
COPY --from=distroless-prep /usr/share/grafana/conf /usr/share/grafana/conf
COPY --chown=${GF_UID}:${GF_GID} --from=distroless-prep /usr/share/grafana/.aws /usr/share/grafana/.aws
COPY --chown=${GF_UID}:${GF_GID} --from=distroless-prep /usr/share/grafana/data /usr/share/grafana/data
COPY --link --from=grafana-assets /usr/share/grafana /usr/share/grafana
COPY --link --from=grafana-plugins /usr/share/grafana/data /usr/share/grafana/data
COPY --from=distroless-prep /.grafana-version /.grafana-version

EXPOSE 3000

USER $GF_UID

# ENTRYPOINT holds the invariant invocation; CMD holds the overridable default
# args. Splitting them follows the conventional Docker pattern so runtime args
# (docker run <img> <args> / Kubernetes args:) replace the defaults instead of
# being permanently pinned after a fully-baked ENTRYPOINT.
ENTRYPOINT ["/usr/share/grafana/bin/grafana", "server", "--homepath=/usr/share/grafana", "--config=/etc/grafana/grafana.ini", "--packaging=docker"]
CMD ["cfg:default.log.mode=console"]

# Default stage — alpine. Builds without --target produce an alpine image.
# Use --target=final-ubuntu to build the ubuntu variant instead.
FROM final-alpine
