#!/bin/sh
# Start whisper.cpp's server on the model named by WHISPER_MODEL.
#
# The whisper.cpp image ships a model downloader and whisper-server; the
# model lives in the whisper-models volume, so it is downloaded once and
# reused.  A model that is already there is never fetched again, and
# WHISPER_MODEL is the file name, `ggml-base.en.bin' for example.
#
# The image moved both programs between releases -- the server from
# /app/whisper-server to /app/build/bin/whisper-server, the downloader
# from /app to /app/models -- so both layouts are looked for.
set -eu

model="${WHISPER_MODEL:-ggml-base.en.bin}"
models="${WHISPER_DIR:-/models}"

downloader=
for candidate in /app/download-ggml-model.sh /app/models/download-ggml-model.sh; do
    if [ -x "$candidate" ]; then
        downloader="$candidate"
        break
    fi
done

server=
for candidate in /app/whisper-server /app/build/bin/whisper-server; do
    if [ -x "$candidate" ]; then
        server="$candidate"
        break
    fi
done

if [ -z "$server" ]; then
    echo "voice-local: whisper-server not found" >&2
    exit 1
fi

if [ ! -f "$models/$model" ]; then
    short="${model#ggml-}"
    short="${short%.bin}"
    echo "voice-local: downloading $model" >&2
    if [ -z "$downloader" ]; then
        echo "voice-local: model downloader not found" >&2
        exit 1
    fi
    "$downloader" "$short" "$models"
fi

exec "$server" -m "$models/$model" --host 0.0.0.0 --port 8080
