FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# The service does not need root privileges at runtime.
RUN groupadd --system --gid 10001 oracle \
    && useradd --system --uid 10001 --gid oracle --home-dir /app --no-create-home oracle

COPY pyproject.toml README.md ./
COPY oracle ./oracle

RUN python -m pip install --upgrade pip \
    && python -m pip install .

COPY public ./public

RUN chown -R oracle:oracle /app

USER oracle

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=3)"

CMD ["uvicorn", "oracle.app:app", "--host", "0.0.0.0", "--port", "8080"]
