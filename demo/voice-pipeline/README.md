# The voice pipeline, run by the harness server

`demo.sh` starts a headless harness and has it run the local voice
pipeline as its own children, then connects a second, ordinary Emacs to
it over TCP ACP and speaks through it:

```sh
demo/voice-pipeline/demo.sh
```

It prints what the client asks and what comes back:

```text
== harness server: starting the pipeline as its child
   starting · command

== a client, with no speech program of its own, over TCP ACP
   status      : running · 2 of 2 programs (command)
   transcribe  : harness speech fixture
   synthesize  : 3244 bytes of audio/wav

== the programs are the harness's children, and stop with it
   stt pid 16, tts pid 17
   stop
   stop        : stopped
   programs ended
```

That is the point of the change: the client's Emacs has no whisper.cpp,
no Kokoro and no container runtime. It asks `_harness/speech/status',
`_harness/speech/transcribe' and `_harness/speech/synthesize' over the
connection it already has, and the harness does the speech.

Nothing here runs a model. The harness starts
`test/harness-speech-service.py` as its speech-to-text and
text-to-speech programs, which serve whisper.cpp's multipart
`/inference` and Kokoro's `/v1/audio/speech` with fixed answers. The
processes, the ports, the ACP connection and the module are real; only
the model is a stand-in, so the demo needs no GPU, no docker and no
download.

| File | What it is |
| --- | --- |
| `demo.sh` | Runs the server and the client, and stops the pipeline |
| `server.el` | The headless harness: its `command` backend is the fixture, and it listens on loopback |
| `client.el` | The client, with no speech program of its own: status, transcribe, synthesize, stop |

`python3` is the only requirement. The picture of the same page is
`docs/media/voice-setup.png`, taken by `scripts/media.sh voice-setup`;
see [docs/voice.md](../../docs/voice.md) and the design at
[docs/design/server-voice-pipeline.md](../../docs/design/server-voice-pipeline.md).
