FROM python:3.13-alpine@sha256:399babc8b49529dabfd9c922f2b5eea81d611e4512e3ed250d75bd2e7683f4b0

ENV PYTHONDONTWRITEBYTECODE=1
WORKDIR /app
COPY --chmod=0444 portal-simulator.py /app/portal-simulator.py

USER 65534:65534
EXPOSE 8080
CMD ["python3", "-u", "/app/portal-simulator.py", "--host", "0.0.0.0", "--port", "8080"]
