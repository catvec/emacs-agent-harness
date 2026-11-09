# The speech-to-text half of the voice-local stack: NVIDIA Parakeet TDT
# 0.6B through sherpa-onnx's ONNX Runtime, on the CPU.
#
# The image carries the runtime, not the model.  server.py downloads the
# model named by PARAKEET_MODEL into the parakeet-models volume on first
# start, so a larger model is an environment change rather than a new
# image.  Pinning sherpa-onnx keeps a first build reproducible; override
# the image in compose to run another version.
FROM python:3.12-slim

# numpy converts the upload; sherpa-onnx loads and decodes the model.
RUN pip install --no-cache-dir "sherpa-onnx==2.0.1" "numpy>=2,<3"

COPY server.py /app/server.py
WORKDIR /app
EXPOSE 8081
ENTRYPOINT ["python3", "-u", "/app/server.py"]
