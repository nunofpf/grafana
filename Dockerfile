# syntax=docker/dockerfile:1
 
ARG BASE_IMAGE=alpine:3.18.3
ARG JS_IMAGE=node:20-alpine3.18
ARG JS_PLATFORM=linux/amd64
ARG GO_IMAGE=golang:1.21.5-alpine3.18
 
ARG GO_SRC=go-builder
ARG JS_SRC=js-builder
 
################### PLUGINS COMPILATION - Start ###################
FROM proxy.criticalmanufacturing.io/golang:alpine3.21 as im_go
USER root
 
RUN apk add --no-cache git
 
COPY ./plugins/criticalmanufacturing-grpc-datasource /go/src/grpc
WORKDIR /go/src/grpc
 
### Compiling backend
 
RUN go "build" "-o" "dist/cmf_backend_grpc_plugin_linux_amd64" "-ldflags" "-w -s -extldflags \"-static\" -X 'github.com/grafana/grafana-plugin-sdk-go/build.buildInfoJSON={\"time\":1677258377824,\"version\":\"1.0.0\",\"repo\":\"CMF\",\"branch\":\"Deploy\",\"hash\":\"83d7fe05b465008972bea160643473286f89af9e6\"}' -X 'main.version=1.0.0' -X 'main.branch=Deploy' -X 'main.commit=abcd'" "./pkg"
 
RUN git clone https://github.com/criticalmanufacturing/grafana-odata-datasource.git /go/src/odata -b feature-odata-query-string --depth 1
WORKDIR /go/src/odata
 
### Compiling backend
 
RUN go "build" "-o" "dist/cmf_backend_odata_plugin_linux_amd64" "-ldflags" "-w -s -extldflags \"-static\" -X 'github.com/grafana/grafana-plugin-sdk-go/build.buildInfoJSON={\"time\":1677258377824,\"version\":\"1.0.0\",\"repo\":\"CMF\",\"branch\":\"Deploy\",\"hash\":\"83d7fe05b465008972bea160643473286f89af9e6\"}' -X 'main.version=1.0.0' -X 'main.branch=Deploy' -X 'main.commit=abcd'" "./pkg"
 
### Compiling frontend grpc
 
FROM proxy.criticalmanufacturing.io/ubuntu:22.04 as im_node
USER root
 
WORKDIR /usr/src/grpc
COPY ./plugins/criticalmanufacturing-grpc-datasource .
 
COPY ./public.gpg.key /opt/public.gpg.key
 
RUN apt-get update \
    && apt-get install -y curl gnupg \
    && apt-key add /opt/public.gpg.key \
    && rm -rf /var/lib/apt/lists/*
 
RUN apt update
RUN apt install curl -y
#GRPC only compiles with version "^14 || ^16 || ^17 || ^18 || ^19"
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash - && apt-get install -y nodejs
RUN curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add -
RUN echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list
RUN apt-get update
RUN apt-get install yarn -y
RUN yarn install --ignore-engines
RUN yarn build
 
RUN apt install git -y
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y nodejs
 
RUN git clone https://github.com/criticalmanufacturing/grafana-odata-datasource.git /usr/src/odata -b feature-odata-query-string --depth 1
 
WORKDIR /usr/src/odata
 
RUN yarn install
RUN yarn build
 
################### PLUGINS COMPILATION - End ###################
 
FROM --platform=${JS_PLATFORM} ${JS_IMAGE} as js-builder
 
ENV NODE_OPTIONS=--max_old_space_size=8000
 
WORKDIR /tmp/grafana
 
COPY package.json yarn.lock .yarnrc.yml ./
COPY .yarn .yarn
COPY packages packages
COPY plugins-bundled plugins-bundled
COPY public public
 
RUN yarn install --immutable
 
COPY tsconfig.json .eslintrc .editorconfig .browserslistrc .prettierrc.js babel.config.json ./
COPY public public
COPY scripts scripts
COPY emails emails
 
ENV NODE_ENV production
RUN yarn build
 
FROM ${GO_IMAGE} as go-builder
 
ARG COMMIT_SHA=""
ARG BUILD_BRANCH=""
ARG GO_BUILD_TAGS="oss"
ARG WIRE_TAGS="oss"
ARG BINGO="true"
 
# Install build dependencies
RUN if grep -i -q alpine /etc/issue; then \
      apk add --no-cache gcc g++ make git; \
    fi
 
WORKDIR /tmp/grafana
 
COPY go.* ./
COPY .bingo .bingo
 
# Include vendored dependencies
COPY pkg/util/xorm/go.* pkg/util/xorm/
 
RUN go mod download
RUN if [[ "$BINGO" = "true" ]]; then \
      go install github.com/bwplotka/bingo@latest && \
      bingo get -v; \
    fi
 
COPY embed.go Makefile build.go package.json ./
COPY cue.mod cue.mod
COPY kinds kinds
COPY local local
COPY packages/grafana-schema packages/grafana-schema
COPY public/app/plugins public/app/plugins
COPY public/api-merged.json public/api-merged.json
COPY pkg pkg
COPY scripts scripts
COPY conf conf
COPY .github .github
COPY LICENSE ./
 
ENV COMMIT_SHA=${COMMIT_SHA}
ENV BUILD_BRANCH=${BUILD_BRANCH}
 
RUN make build-go GO_BUILD_TAGS=${GO_BUILD_TAGS} WIRE_TAGS=${WIRE_TAGS}
 
FROM ${BASE_IMAGE} as tgz-builder
 
WORKDIR /tmp/grafana
 
ARG GRAFANA_TGZ="grafana-latest.linux-x64-musl.tar.gz"
 
COPY ${GRAFANA_TGZ} /tmp/grafana.tar.gz
 
# add -v to make tar print every file it extracts
RUN tar x -z -f /tmp/grafana.tar.gz --strip-components=1
 
# helpers for COPY --from
FROM ${GO_SRC} as go-src
FROM ${JS_SRC} as js-src
 
# Final stage
FROM ${BASE_IMAGE}
 
LABEL name="grafana" \
      maintainer="contact@criticalmanufacturing.com" \
      vendor="CRITICAL MANUFACTURING, S.A." \
      summary="Grafana container image" \
      description="Grafana container image"
 
ARG GF_UID="1001"
ARG GF_GID="0"
 
ENV PATH="/usr/share/grafana/bin:$PATH" \
    GF_PATHS_CONFIG="/etc/grafana/grafana.ini" \
    GF_PATHS_DATA="/var/lib/grafana" \
    GF_PATHS_HOME="/usr/share/grafana" \
    GF_PATHS_LOGS="/var/log/grafana" \
    GF_PATHS_PLUGINS="/data/grafana/plugins" \
    GF_PATHS_PROVISIONING="/etc/grafana/provisioning"
 
WORKDIR $GF_PATHS_HOME
 
# Install dependencies
RUN if grep -i -q alpine /etc/issue; then \
    apk add --no-cache ca-certificates bash curl tzdata musl-utils && \
      apk info -vv | sort; \
    elif grep -i -q ubuntu /etc/issue; then \
      DEBIAN_FRONTEND=noninteractive && \
      apt-get update && \
      apt-get install -y ca-certificates curl tzdata musl && \
      apt-get autoremove -y && \
      rm -rf /var/lib/apt/lists/*; \
    else \
      echo 'ERROR: Unsupported base image' && /bin/false; \
    fi
 
# glibc support for alpine x86_64 only
RUN if grep -i -q alpine /etc/issue && [ `arch` = "x86_64" ]; then \
      wget -q -O /etc/apk/keys/sgerrand.rsa.pub https://alpine-pkgs.sgerrand.com/sgerrand.rsa.pub && \
      wget https://github.com/sgerrand/alpine-pkg-glibc/releases/download/2.35-r0/glibc-2.35-r0.apk \
        -O /tmp/glibc-2.35-r0.apk && \
      wget https://github.com/sgerrand/alpine-pkg-glibc/releases/download/2.35-r0/glibc-bin-2.35-r0.apk \
        -O /tmp/glibc-bin-2.35-r0.apk && \
      apk add --force-overwrite --no-cache /tmp/glibc-2.35-r0.apk /tmp/glibc-bin-2.35-r0.apk && \
      rm -f /lib64/ld-linux-x86-64.so.2 && \
      ln -s /usr/glibc-compat/lib64/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2 && \
      rm -f /tmp/glibc-2.35-r0.apk && \
      rm -f /tmp/glibc-bin-2.35-r0.apk && \
      rm -f /lib/ld-linux-x86-64.so.2 && \
      rm -f /etc/ld.so.cache; \
    fi
 
COPY --from=go-src /tmp/grafana/conf ./conf
 
RUN if [ ! $(getent group "$GF_GID") ]; then \
      if grep -i -q alpine /etc/issue; then \
        addgroup -S -g $GF_GID grafana; \
      else \
        addgroup --system --gid $GF_GID grafana; \
      fi; \
    fi && \
    GF_GID_NAME=$(getent group $GF_GID | cut -d':' -f1) && \
    mkdir -p "$GF_PATHS_HOME/.aws" && \
    if grep -i -q alpine /etc/issue; then \
      adduser -S -u $GF_UID -G "$GF_GID_NAME" grafana; \
    else \
      adduser --system --uid $GF_UID --ingroup "$GF_GID_NAME" grafana; \
    fi && \
    mkdir -p "$GF_PATHS_PROVISIONING/datasources" \
             "$GF_PATHS_PROVISIONING/dashboards" \
             "$GF_PATHS_PROVISIONING/notifiers" \
             "$GF_PATHS_PROVISIONING/plugins" \
             "$GF_PATHS_PROVISIONING/access-control" \
             "$GF_PATHS_PROVISIONING/alerting" \
             "$GF_PATHS_LOGS" \
             "$GF_PATHS_PLUGINS" \
             "$GF_PATHS_DATA" && \
    cp conf/sample.ini "$GF_PATHS_CONFIG" && \
    cp conf/ldap.toml /etc/grafana/ldap.toml && \
    chown -R "grafana:$GF_GID_NAME" "$GF_PATHS_DATA" "$GF_PATHS_HOME/.aws" "$GF_PATHS_LOGS" "$GF_PATHS_PLUGINS" "$GF_PATHS_PROVISIONING" && \
    chmod -R 777 "$GF_PATHS_DATA" "$GF_PATHS_HOME/.aws" "$GF_PATHS_LOGS" "$GF_PATHS_PLUGINS" "$GF_PATHS_PROVISIONING"
 
COPY --from=go-src /tmp/grafana/bin/grafana* /tmp/grafana/bin/*/grafana* ./bin/
COPY --from=js-src /tmp/grafana/public ./public
COPY --from=go-src /tmp/grafana/LICENSE ./
 
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
    GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS="criticalmanufacturing-grpc-datasource,criticalmanufacturing-odata-datasource"
 
### Copy CMF plugin to the plugin directory
RUN mkdir -p /data/grafana/plugins/criticalmanufacturing-grpc-datasource
COPY --from=im_node /usr/src/grpc/dist/ /data/grafana/plugins/criticalmanufacturing-grpc-datasource
COPY --from=im_go /go/src/grpc/dist/cmf_backend_grpc_plugin_linux_amd64 /data/grafana/plugins/criticalmanufacturing-grpc-datasource/
RUN chmod u+x /data/grafana/plugins/criticalmanufacturing-grpc-datasource/cmf_backend_grpc_plugin_linux_amd64
 
RUN mkdir -p /data/grafana/plugins/criticalmanufacturing-odata-datasource
COPY --from=im_node /usr/src/odata/dist/ /data/grafana/plugins/criticalmanufacturing-odata-datasource
COPY --from=im_go /go/src/odata/dist/cmf_backend_odata_plugin_linux_amd64 /data/grafana/plugins/criticalmanufacturing-odata-datasource/
RUN chmod u+x /data/grafana/plugins/criticalmanufacturing-odata-datasource/cmf_backend_odata_plugin_linux_amd64
 
RUN grafana-cli --pluginsDir "/data/grafana/plugins" plugins install retrodaredevil-wildgraphql-datasource 1.2.1
RUN grafana-cli --pluginsDir "/data/grafana/plugins" plugins install volkovlabs-echarts-panel 6.4.1
 
 
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
COPY --from=dev.criticalmanufacturing.io/criticalmanufacturing/base/ubi9:11.1-dev /licenses /licenses
# CmfEntrypoint
COPY --from=dev.criticalmanufacturing.io/criticalmanufacturing/base/ubi9:11.1-dev /usr/share/CmfEntrypoint /usr/share/CmfEntrypoint
 
RUN apt-get update \
    && apt-get install -y gnupg wget \
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
 
ENTRYPOINT /usr/share/CmfEntrypoint/CmfEntrypoint "/bin/sh /run.sh" \
       --process-secrets \
       --layer="grafana" \
       --target-directory="/etc/grafana/provisioning"
