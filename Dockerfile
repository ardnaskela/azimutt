ARG ELIXIR_VERSION=1.14.3
ARG OTP_VERSION=25.2.2
ARG OTP_MAJOR=25
ARG DEBIAN_VERSION=bullseye-20230109-slim

ARG S3_KEY_ID
ARG S3_HOST
ARG S3_KEY_SECRET
ARG S3_BUCKET
ARG HOST
ARG GITHUB_CLIENT_SECRET
ARG GITHUB_CLIENT_ID
ARG STRIPE_API_KEY
ARG STRIPE_WEBHOOK_SIGNING_SECRET
ARG PHX_SERVER
ARG DATABASE_URL

# Multi-arch builder + runner
ARG BUILDER_IMAGE="elixir:1.16.3-otp-25-slim"
ARG RUNNER_IMAGE="debian:bullseye-slim"

FROM ${BUILDER_IMAGE} as builder

# Build deps
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
     build-essential git curl wget ca-certificates gnupg \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# Install modern Node.js (arm64 OK) via `n`
RUN curl -L https://raw.githubusercontent.com/tj/n/master/bin/n -o /usr/local/bin/n \
 && chmod +x /usr/local/bin/n \
 && n 20.11.1 \
 && npm install -g npm@10 \
 && node --version \
 && npm --version

# IMPORTANT: neutralize any injected npm auth and force public registry
RUN rm -f /root/.npmrc \
 && npm config set registry https://registry.npmjs.org/

# Install Elm with Linux ARM support via the Elm team's test package
# (includes Linux ARM binaries)
RUN npm install -g @lydell/elm@0.19.1-9 \
 && elm --version

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

ENV MIX_ENV="prod"

# install mix dependencies
COPY backend/mix.exs backend/mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY backend/config/config.exs backend/config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY backend/priv priv
COPY backend/assets assets

COPY package.json .
COPY pnpm-workspace.yaml .
COPY pnpm-lock.yaml .
COPY libs/ libs
COPY frontend/ frontend

# install pnpm
RUN npm install -g pnpm@9.5.0

# install JS deps but skip lifecycle scripts (preinstall/postinstall) that try to run the failing elm installer
# use the lockfile to ensure deterministic deps
RUN pnpm install --frozen-lockfile --ignore-scripts

# now run the project's build, which will use the global `elm` binary we installed earlier
RUN npm run build:docker

# Compile the release
COPY backend/lib lib

# compile assets
RUN cd assets && npm install
RUN mix assets.deploy

RUN mix compile

COPY backend/config/runtime.exs config/
COPY backend/rel rel
RUN mix release

FROM ${RUNNER_IMAGE}

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
     libstdc++6 openssl libncurses5 locales ca-certificates \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

ENV S3_KEY_ID=${S3_KEY_ID}
ENV S3_HOST=${S3_HOST}
ENV S3_KEY_SECRET=${S3_KEY_SECRET}
ENV S3_BUCKET=${S3_BUCKET}
ENV HOST=${HOST}
ENV GITHUB_CLIENT_SECRET=${GITHUB_CLIENT_SECRET}
ENV GITHUB_CLIENT_ID=${GITHUB_CLIENT_ID}
ENV STRIPE_API_KEY=${STRIPE_API_KEY}
ENV STRIPE_WEBHOOK_SIGNING_SECRET=${STRIPE_WEBHOOK_SIGNING_SECRET}
ENV DATABASE_URL=${DATABASE_URL}
ENV MIX_ENV="prod"
ENV PHX_SERVER="true"

WORKDIR "/app"
RUN chown nobody /app

RUN chown nobody /app

# ADD THESE 3 LINES HERE:
RUN mkdir -p /app/bin/uploads && \
    chown -R nobody:root /app/bin/uploads && \
    chmod -R 755 /app/bin/uploads

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/azimutt ./
RUN mkdir -p ./app/bin/priv/static/
COPY --from=builder --chown=nobody:root /app/priv/static/blog ./bin/priv/static/blog

# Fix DNS for Oracle Cloud
RUN echo "nameserver 8.8.8.8" > /etc/resolv.conf && \
    echo "nameserver 8.8.4.4" >> /etc/resolv.conf

# Test internet connectivity during build
RUN echo "Testing internet connectivity..." && \
    curl -s --connect-timeout 10 https://google.com > /dev/null && \
    echo "Internet access OK" || echo "Warning: No internet access during build"

USER nobody
CMD ["sh", "-c", "/app/bin/migrate && /app/bin/server"]
