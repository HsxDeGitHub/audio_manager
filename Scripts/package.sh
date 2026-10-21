#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
if [[ ! -x .runtime/tools/whisper-cli || ! -x .runtime/tools/ffmpeg ]]; then
  python3 Scripts/bootstrap.py
fi
swift build -c release --disable-sandbox --cache-path .build/cache
BIN_DIR="$(swift build -c release --disable-sandbox --cache-path .build/cache --show-bin-path)"
APP_DIR="$PROJECT_DIR/dist/听阅.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/InterviewAudio" "$APP_DIR/Contents/MacOS/InterviewAudio"
cp "$BIN_DIR/AudioWorker" "$APP_DIR/Contents/MacOS/AudioWorker"
mkdir -p "$APP_DIR/Contents/Resources/Tools"
cp .runtime/tools/whisper-cli .runtime/tools/ffmpeg "$APP_DIR/Contents/Resources/Tools/"
mkdir -p "$APP_DIR/Contents/Resources/Tools/sherpa/bin" "$APP_DIR/Contents/Resources/Tools/sherpa/lib"
cp .runtime/tools/sherpa/bin/sherpa-onnx-offline-punctuation .runtime/tools/sherpa/bin/sherpa-onnx-offline-speaker-diarization "$APP_DIR/Contents/Resources/Tools/sherpa/bin/"
cp -L .runtime/tools/sherpa/lib/libonnxruntime.dylib "$APP_DIR/Contents/Resources/Tools/sherpa/lib/"
cp -R .runtime/tools/Licenses "$APP_DIR/Contents/Resources/"
cp THIRD_PARTY_NOTICES.md "$APP_DIR/Contents/Resources/"
# 独立 Python 运行时：锁定依赖、下载解释器、安装后端 wheel，并签名原生扩展。
EMBEDDING_FLAG=""
if [[ "${PACKAGE_EMBEDDINGS:-1}" == "0" ]]; then EMBEDDING_FLAG="--without-embeddings"; fi
python3 Scripts/package_backend.py "$APP_DIR" ${EMBEDDING_FLAG:+"$EMBEDDING_FLAG"}
# This release binary already uses @executable_path/../lib. Keep that layout in the app.
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.interview.audio</string>
  <key>CFBundleName</key><string>听阅</string>
  <key>CFBundleDisplayName</key><string>听阅</string>
  <key>CFBundleExecutable</key><string>InterviewAudio</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.3.0</string>
  <key>CFBundleVersion</key><string>5</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict></plist>
PLIST
swift Scripts/icon.swift "$APP_DIR/Contents/Resources"
iconutil -c icns "$APP_DIR/Contents/Resources/AppIcon.iconset" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
find "$APP_DIR/Contents" -type f \( -name '*.dylib' -o -name 'whisper-cli' -o -name 'ffmpeg' -o -name 'AudioWorker' -o -name 'sherpa-onnx-offline-speaker-diarization' -o -name 'sherpa-onnx-offline-punctuation' \) -exec codesign --force --sign - {} \;
codesign --force --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
# Reference the project models without duplicating 3 GB. Settings also support any external model directory.
if [[ -d Models && ! -e dist/Models ]]; then ln -s ../Models dist/Models; fi
print "应用已构建：$APP_DIR"
