# Third-party components

This application uses separate local executables. It does not send recordings to third-party services.

- **whisper.cpp 1.9.5**, MIT license. Source: https://github.com/ggml-org/whisper.cpp/tree/v1.9.5. A license copy is bundled in Resources/Licenses.
- **Whisper large-v3 GGML weights**, downloaded from https://huggingface.co/ggerganov/whisper.cpp at revision `5359861c739e955e79d9a303bcbc70fb988958b1`. Whisper project: https://github.com/openai/whisper.
- **Silero VAD v6.2.0 GGML model**, MIT license, official whisper.cpp distribution: https://huggingface.co/ggml-org/whisper-vad. Upstream: https://github.com/snakers4/silero-vad.
- **sherpa-onnx 1.13.8**, Apache-2.0 license. Source and native release: https://github.com/k2-fsa/sherpa-onnx/tree/v1.13.8.
- **ONNX Runtime**, MIT license. Included by the official sherpa-onnx native release. Source: https://github.com/microsoft/onnxruntime.
- **pyannote segmentation 3.0 ONNX model**, MIT license as distributed with the official sherpa-onnx model archive. Model source: https://huggingface.co/pyannote/segmentation-3.0.
- **3D-Speaker ERes2Net Chinese speaker embedding**, official sherpa-onnx model distribution. Project: https://github.com/modelscope/3D-Speaker (Apache-2.0).
- **FFmpeg 7.1**, executable from the macOS ARM64 `imageio-ffmpeg` 0.6.0 wheel. FFmpeg version/configuration can be obtained with `ffmpeg -version`; this build enables GPL components. Upstream source: https://ffmpeg.org/download.html, executable build project: https://github.com/imageio/imageio-binaries, wrapper distribution: https://pypi.org/project/imageio-ffmpeg/0.6.0/. The wrapper package license is bundled in Resources/Licenses.

Models remain outside the app bundle. Model downloads are checked against pinned SHA-256 digests before use.
