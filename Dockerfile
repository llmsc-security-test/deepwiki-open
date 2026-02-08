# syntax=docker/dockerfile:1-labs
# ------------------------------------------------------------------
# Multi‑stage build for a Next.js front‑end + Python back‑end (DeepWiki)
# ------------------------------------------------------------------

# ---------- Build arguments ----------
ARG CUSTOM_CERT_DIR=certs      # Directory with custom CA certificates (if any)

# ---------- Node.js base image ----------
FROM node:20-alpine3.22 AS node_base

# ---------- Install production Node.js dependencies ----------
FROM node_base AS node_deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --legacy-peer-deps

# ---------- Build the Next.js application ----------
FROM node_base AS node_builder
WORKDIR /app
# Re‑use the already‑installed node_modules
COPY --from=node_deps /app/node_modules ./node_modules
# Copy only the files required for a production build
COPY package.json package-lock.json next.config.ts tsconfig.json \
     tailwind.config.js postcss.config.mjs ./
COPY src/ ./src/
COPY public/ ./public/
# Increase Node memory limit & disable Next telemetry
ENV NODE_OPTIONS="--max-old-space-size=4096"
ENV NEXT_TELEMETRY_DISABLED=1
RUN NODE_ENV=production npm run build

# ---------- Install Python production dependencies ----------
FROM python:3.11-slim AS py_deps
WORKDIR /api
COPY api/pyproject.toml .
COPY api/poetry.lock .
# Install Poetry, create an in‑project venv and install only runtime deps
RUN python -m pip install --no-cache-dir poetry==2.0.1 && \
    poetry config virtualenvs.create true --local && \
    poetry config virtualenvs.in-project true --local && \
    poetry config virtualenvs.options.always-copy true --local && \
    POETRY_MAX_WORKERS=10 poetry install --no-interaction --no-ansi --only main && \
    poetry cache clear --all .

# ---------- Final runtime image ----------
FROM python:3.11-slim

# Set working directory
WORKDIR /app

# ----- Install Node.js (via Nodesource) -----
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl gnupg git ca-certificates && \
    mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | \
        gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends nodejs && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# ----- Install custom CA certificates (if provided) -----
ARG CUSTOM_CERT_DIR
RUN if [ -n "${CUSTOM_CERT_DIR}" ] && [ -d "${CUSTOM_CERT_DIR}" ]; then \
        mkdir -p /usr/local/share/ca-certificates && \
        cp -r ${CUSTOM_CERT_DIR}/* /usr/local/share/ca-certificates/ 2>/dev/null || true && \
        update-ca-certificates && \
        echo "Custom certificates installed successfully."; \
    else \
        echo "No custom certificates found – proceeding with default CAs."; \
    fi

# ----- Python virtual environment -----
ENV PATH="/opt/venv/bin:$PATH"
COPY --from=py_deps /api/.venv /opt/venv

# ----- Application source code -----
COPY api/ ./api/
COPY --from=node_builder /app/public ./public
COPY --from=node_builder /app/.next/standalone ./
COPY --from=node_builder /app/.next/static ./.next/static

# ----- Expose ports -----
# 8001 – Python API (default, can be overridden at runtime)
# 3000 – Next.js front‑end
EXPOSE 8001 3000

# ----- Startup script (runs both back‑end and front‑end) -----
RUN echo '#!/usr/bin/env bash\n\
set -e\n\
# Load .env if present\n\
if [ -f .env ]; then\n\
  export $(grep -v "^#" .env | xargs -r)\n\
fi\n\
# Warn if required keys are missing\n\
if [ -z "$OPENAI_API_KEY" ] || [ -z "$GOOGLE_API_KEY" ]; then\n\
  echo "Warning: OPENAI_API_KEY and/or GOOGLE_API_KEY are not set."\n\
fi\n\
# Start the Python API (background)\n\
python -m api.main --port ${PORT:-8001} &\n\
# Start the Next.js server (foreground)\n\
HOSTNAME=0.0.0.0 PORT=3000 node server.js\n' > /app/start.sh && chmod +x /app/start.sh

# ----- Default environment variables -----
ENV PORT=8001 \
    NODE_ENV=production \
    SERVER_BASE_URL="http://localhost:${PORT}"

# Ensure a .env file exists (can be overridden at runtime)
RUN touch .env

# ----- Entrypoint handling (provided by the platform) -----
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && \
    mkdir -p /var/log && touch /var/log/app.log

# The platform expects this entrypoint
ENTRYPOINT ["/entrypoint.sh"]