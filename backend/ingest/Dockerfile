FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
ENV PORT=8080
# --factory: build_production_app() wires the real GCS/Firebase/DB ports from env.
CMD ["uvicorn", "app.main:build_production_app", "--factory", "--host", "0.0.0.0", "--port", "8080"]
