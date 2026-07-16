# Build context is the REPO ROOT, not backend/ingest — the image needs C's app AND A's export
# queries (db/exports.py), which live in different lanes:
#
#   docker build -f backend/ingest/Dockerfile -t <image> .      (infra/deploy.sh does this)
#
# See the root .dockerignore: it denies everything by default so the repo's multi-GB Valhalla tiles
# can't enter the context.
FROM python:3.12-slim
WORKDIR /app
COPY backend/ingest/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY backend/ingest/app ./app
# Person A's export queries, shipped as-is (C never edits them). The inspect/export routes import
# this as `exports`; WORKDIR is on sys.path, so a flat copy is all it takes.
COPY db/exports.py ./exports.py
ENV PORT=8080
# --factory: build_production_app() wires the real GCS/Firebase/DB/exports ports from env.
CMD ["uvicorn", "app.main:build_production_app", "--factory", "--host", "0.0.0.0", "--port", "8080"]
