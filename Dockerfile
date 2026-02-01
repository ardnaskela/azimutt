# Dockerfile (Azimutt) - patched for multi-arch / ARM64 builds
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

# Use an official multi-arch Elixir image (includes arm64)
ARG BUILDER_IMAGE="elixir:1.16.3-otp-25-slim"
ARG RUNNER_IMAGE="debian:bullseye-slim"

FROM ${BUILDER_IMAGE} as builder

# install build dependencies (keep minimal but sufficient)
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
     build-essential git curl wget ca-certificates gnupg \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# Install modern Node.js without NodeSource (works on arm64) using `n`
# and upgrade npm to a modern version.
RUN curl -L https://raw.githubusercontent.com/tj/n/master/bin/n -o /usr/local/bin/n \
 && chmod +x /usr/local/bin/n \
 # Install Node 20 (adjust version if you prefer another 20.x)
 && n 20.11.1 \
 # Ensure npm is recent and stable
 && npm install -g npm@10 \
 && node --version \
 && npm --version

# Install Elm compiler (arm64-friendly) via the maintained npm distribution
# that contains compatible binaries for linux/arm64.
RUN npm install -g @carwow/elm@0.19.1 \
 && elm --version

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# copy and fetch mix deps
COPY backend/mix.exs backend/mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
COPY backend/config/config.exs backend/config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY backend/priv priv

# copy assets and frontend sources
COPY backend/assets assets
COPY package.json .
COPY pnpm-workspace.yaml .
COPY pnpm-lock.yaml .
COPY libs/ libs
COPY frontend/ frontend

# install pnpm and build frontend assets (this step runs the project's build:docker)
RUN npm install -g pnpm@9.5.0
RUN npm run build:docker

# Compile the release
COPY backend/lib lib

# compile assets for Phoenix
RUN cd assets && npm install
RUN mix assets.deploy

RUN mix compile

# Changes to config/runtime.exs don't require recompiling the code
COPY backend/config/runtime.exs config/

COPY backend/rel rel
RUN mix release

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE}

# runtime deps
RUN apt-get update -y \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses5 locales ca-certificates \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

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

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/azimutt ./
RUN mkdir -p ./app/bin/priv/static/
COPY --from=builder --chown=nobody:root /app/priv/static/blog ./bin/priv/static/blog

USER nobody

CMD ["sh", "-c", "/app/bin/migrate && /app/bin/server"]
