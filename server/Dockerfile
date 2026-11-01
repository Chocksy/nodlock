# python:3.12-slim, multi-arch index digest (amd64 + arm64), looked up 2026-11-01.
FROM python:3.12-slim@sha256:aa943ce411423c7582288f18707ff66eddcbaeb510502d747a72aeb34f30d159

# curl (HTTP/2) and openssl (ES256 signing) are only used for optional Apple push.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl openssl \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --home-dir /app nodlock \
 && mkdir -p /app /data /secrets \
 && chown nodlock /data

WORKDIR /app
COPY app.py .
USER nodlock
ENV PYTHONUNBUFFERED=1
EXPOSE 8080

HEALTHCHECK --interval=60s --timeout=5s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import os,urllib.request; urllib.request.urlopen('http://127.0.0.1:%s/healthz' % os.environ.get('PORT', '8080'), timeout=4)"]

CMD ["python", "app.py"]
