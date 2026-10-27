ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}
ENV DEBIAN_FRONTEND=noninteractive PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN apt-get update && apt-get install -y --no-install-recommends python3 libc-bin libstdc++6 libgomp1 ca-certificates && rm -rf /var/lib/apt/lists/*
COPY consumer.py /opt/libllama-consumer.py
ENTRYPOINT ["python3", "/opt/libllama-consumer.py"]
