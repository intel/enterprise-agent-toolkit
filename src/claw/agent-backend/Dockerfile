# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
# agent-backend image. The tests are a build gate: the runtime stage copies from the stage that ran them.
ARG NODE_IMAGE=docker.io/library/node:24-trixie-slim@sha256:7f486cabe892bff8fef04c0f7da8dba84a560be3e4e2740b7a86afc57ebec315

FROM ${NODE_IMAGE} AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY tsconfig.json tsconfig.test.json server.ts ./
COPY lib ./lib
COPY test ./test
RUN npm test && npm run build && npm prune --omit=dev

FROM ${NODE_IMAGE}
ENV NODE_ENV=production
WORKDIR /app
COPY --from=build /app/package.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
# npm and corepack are not needed at runtime.
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack /usr/local/bin/npm \
      /usr/local/bin/npx /usr/local/bin/corepack
USER 65532:65532
EXPOSE 3000
CMD ["node", "dist/server.js"]
