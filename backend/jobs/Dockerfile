# Nightly aggregation image (Cloud Run Job). Person A builds this; C wires it into Terraform as
# var.aggregate_image and triggers it via Cloud Scheduler (infra/modules/stack).
#
#   docker build -t <region>-docker.pkg.dev/<project>/fsd/aggregate:m1 backend/jobs
#
# Explicit COPYs rather than `COPY . .`, so tests, venvs and caches can never ride into the image —
# no .dockerignore needed to keep it lean.
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY aggregate.py .
# The versioned scoring config (the gate). SCORING_CONFIG can point at a different file to retune
# without rebuilding the image.
COPY config ./config
CMD ["python", "aggregate.py"]
