FROM python:3.13-alpine

ENV PYTHONDONTWRITEBYTECODE=1
WORKDIR /app
COPY --chmod=0444 portal-simulator.py /app/portal-simulator.py

USER 65534:65534
EXPOSE 8080
CMD ["python3", "-u", "/app/portal-simulator.py", "--host", "0.0.0.0", "--port", "8080"]
