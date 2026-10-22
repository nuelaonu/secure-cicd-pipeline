# Multi-stage build for the sample service.
#
# Stage 1 (builder): byte-compile the application so syntax errors fail
# the image build, and so the runtime stage ships no build tooling.
# Stage 2 (runtime): slim base, non-root user, only the compiled app.
#
# The service has no third-party runtime dependencies (Python standard
# library only), so there is nothing to pip-install — the attack
# surface stays at the base image plus this code.

FROM python:3.12-slim AS builder
WORKDIR /build
COPY app/ ./app/
RUN python -m compileall -q app

FROM python:3.12-slim AS runtime

# Patch the base image at build time so the shipped image starts from
# current OS packages; the Anchore and OpenSCAP gates verify the rest.
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

# Non-root runtime user with a fixed UID for predictable file ownership.
RUN groupadd --gid 10001 app \
    && useradd --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

WORKDIR /app
COPY --from=builder /build/app/ ./app/

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8080

USER 10001:10001
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2)"

CMD ["python", "-m", "app.main"]
