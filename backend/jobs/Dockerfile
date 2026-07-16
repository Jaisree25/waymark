# Nightly pipeline image (Cloud Run Job). Person A builds this; C wires it into Terraform as
# var.aggregate_image and triggers it via Cloud Scheduler (infra/modules/stack).
#
# Build context is the REPO ROOT, not backend/jobs — the pipeline composes three lanes' files:
#   backend/jobs/   the job itself (A)
#   db/exposure.py  attribution + exposure (A)
#   backend/mapmatch/valhalla.py   the real MapMatcher (C)
#   contracts/mapmatch.py          the frozen interface both sides agree on
#
#   docker build -f backend/jobs/Dockerfile -t <region>-docker.pkg.dev/<project>/fsd/aggregate:m1 .
#
# See the root .dockerignore: it denies everything by default, so backend/mapmatch/data's multi-GB
# Valhalla tiles can't wander into the context alongside valhalla.py.
FROM python:3.12-slim
WORKDIR /app
COPY backend/jobs/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY backend/jobs/nightly.py backend/jobs/aggregate.py ./
# The versioned scoring config (the gate). SCORING_CONFIG can point at a different file to retune
# without rebuilding the image.
COPY backend/jobs/config ./config
# A's attribution/exposure and C's matcher, laid out flat beside the job so WORKDIR's presence on
# sys.path is all the wiring they need. Copied as their owners wrote them — neither is edited here.
COPY db/exposure.py ./exposure.py
COPY backend/mapmatch/valhalla.py ./valhalla.py
COPY contracts/mapmatch.py ./contracts/mapmatch.py

# nightly.py, not aggregate.py: aggregating without attribution + exposure scores an empty
# denominator and gates every road.
CMD ["python", "nightly.py"]
