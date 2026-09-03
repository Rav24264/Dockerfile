FROM node:24-alpine AS builder

ARG EVOLUTION_TAG=2.3.7
ARG EVOLUTION_COMMIT=cd800f2976e1e5b682fbf86a01ee4d85ae61f370
ARG BAILEYS_HOTFIX_COMMIT=4f263f0e365c2e74dd1b824031d1c5910f518c26

RUN apk add --no-cache git ffmpeg wget curl bash openssl

RUN git clone --depth 1 --branch "${EVOLUTION_TAG}" \
      https://github.com/evolution-foundation/evolution-api.git /evolution \
    && test "$(git -C /evolution rev-parse HEAD)" = "${EVOLUTION_COMMIT}"

WORKDIR /evolution

# Root lifecycle fix applied to the exact reviewed Evolution commit. The build
# fails closed if upstream source no longer matches the audited patch context.
COPY patches/0001-single-flight-whatsapp-lifecycle.patch /tmp/evolution-lifecycle.patch
RUN git apply --check /tmp/evolution-lifecycle.patch \
    && git apply /tmp/evolution-lifecycle.patch

# Pin the exact reviewed hotfix commit. It adds handling for
# companion_reg_refresh and keeps the rest of Evolution API on 2.3.7.
RUN npm install --save-exact \
      "baileys@git+https://github.com/doryani-ai/Baileys.git#${BAILEYS_HOTFIX_COMMIT}"

RUN node --input-type=module -e \
  "import { handleCompanionRegRefresh, makePairingQRRenderer } from 'baileys'; if (typeof handleCompanionRegRefresh !== 'function' || typeof makePairingQRRenderer !== 'function') process.exit(1); console.log('Baileys companion refresh hotfix verified');"

# Block a production image whenever the resolved runtime dependency graph has
# a critical advisory. This runs after the pinned Git dependency has rewritten
# the lockfile, so the audit covers the graph that is copied to the final image.
RUN npm audit fix --omit=dev
RUN npm audit --omit=dev --audit-level=critical

ENV DOCKER_ENV=true
ENV DATABASE_PROVIDER=postgresql

RUN npm run db:generate
RUN npm run build

FROM node:24-alpine AS final

RUN apk add --no-cache tzdata ffmpeg bash openssl

ENV TZ=Asia/Riyadh
ENV DOCKER_ENV=true

WORKDIR /evolution

COPY --from=builder /evolution/package.json ./package.json
COPY --from=builder /evolution/package-lock.json ./package-lock.json
COPY --from=builder /evolution/node_modules ./node_modules
COPY --from=builder /evolution/dist ./dist
COPY --from=builder /evolution/prisma ./prisma
COPY --from=builder /evolution/manager ./manager
COPY --from=builder /evolution/public ./public
COPY --from=builder /evolution/Docker ./Docker
COPY --from=builder /evolution/runWithProvider.js ./runWithProvider.js
COPY --from=builder /evolution/tsup.config.ts ./tsup.config.ts

EXPOSE 8080

ENTRYPOINT ["/bin/bash", "-c", ". ./Docker/scripts/deploy_database.sh && npm run start:prod"]
