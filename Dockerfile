FROM node:lts-alpine AS base

RUN npm install -g --arch=x64 --platform=linux sharp

FROM base AS deps

RUN apk add --no-cache libc6-compat
RUN apk add --no-cache python3 make g++

WORKDIR /app

COPY . .

# 顯式設為 development 確保 devDependencies 會被安裝（tsdown、tailwindcss、tsc 等）
ENV NODE_ENV=development
RUN npm install -g pnpm
RUN pnpm install --no-frozen-lockfile --shamefully-hoist

FROM base AS builder

RUN apk update && apk add --no-cache git

WORKDIR /app
COPY --from=deps /app/ .

# 重新安裝 pnpm（避免 symlink 權限問題，同時確保 .bin 的 hoist 結果可用）
RUN npm install -g pnpm

ENV NODE_ENV=production
# Next.js 16 預設使用 Turbopack，但 @haklex/* v0.0.105 的 CSS 含 ::highlight 偽元素
# Turbopack 解析器不認識，強制回退 Webpack 進行 production build
ENV NEXT_PRIVATE_TURBOPACK=0
ARG BASE_URL

# Build-time secrets - ensure these are passed securely during docker build
# and not committed to version control
ARG S3_ACCESS_KEY
ARG S3_SECRET_KEY
ARG WEBHOOK_SECRET
ARG TMDB_API_KEY
ARG GH_TOKEN
ENV BASE_URL=${BASE_URL}
ENV NEXT_PUBLIC_API_URL=${BASE_URL}/api/v2
ENV NEXT_PUBLIC_GATEWAY_URL=${BASE_URL}

ENV S3_ACCESS_KEY=${S3_ACCESS_KEY}
ENV S3_SECRET_KEY=${S3_SECRET_KEY}
ENV TMDB_API_KEY=${TMDB_API_KEY}
ENV WEBHOOK_SECRET=${WEBHOOK_SECRET}
ENV GH_TOKEN=${GH_TOKEN}

RUN pnpm turbo run build --filter=@shiro/web

FROM base AS runner
WORKDIR /app

ENV NODE_ENV=production

# Install fonts for proper text rendering
RUN apk add --no-cache fontconfig wget curl
RUN mkdir -p /usr/share/fonts/truetype/chinese /usr/share/fonts/truetype/english

# Install Chinese fonts
RUN wget -O /usr/share/fonts/truetype/LXGWWenKai-Regular.ttf \
    https://github.com/lxgw/LxgwWenKai/releases/download/v1.520/LXGWWenKai-Regular.ttf
RUN wget -O /usr/share/fonts/truetype/LXGWWenKai-Medium.ttf \
    https://github.com/lxgw/LxgwWenKai/releases/download/v1.520/LXGWWenKai-Medium.ttf
RUN wget -O /usr/share/fonts/truetype/LXGWWenKai-Light.ttf \
    https://github.com/lxgw/LxgwWenKai/releases/download/v1.520/LXGWWenKai-Light.ttf

# Install English font Geist
RUN wget -O /tmp/geist.zip \
    https://github.com/vercel/geist-font/releases/download/1.5.0/geist-font-1.5.0.zip 
RUN unzip /tmp/geist.zip -d /tmp/geist
RUN find /tmp/geist -name "*.ttf" -exec cp {} /usr/share/fonts/truetype/ \;
RUN rm -rf /tmp/geist.zip /tmp/geist

# Update font cache
RUN fc-cache -fv

# and other docker env inject
# Next standalone (monorepo) outputs server at /app/apps/web/server.js
COPY --from=builder /app/apps/web/public ./apps/web/public
COPY --from=builder /app/apps/web/.next/standalone ./
COPY --from=builder /app/apps/web/.next/static ./apps/web/.next/static
COPY --from=builder /app/apps/web/.next/server ./apps/web/.next/server

EXPOSE 2323

ENV PORT=2323
ENV NEXT_SHARP_PATH=/usr/local/lib/node_modules/sharp
CMD ["sh", "-c", "echo 'Mix Space Web [Shiro] Image.' && node apps/web/server.js"]
