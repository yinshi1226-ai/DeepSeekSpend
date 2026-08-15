#!/bin/bash
# build.sh — 编译并打包 DeepSeekSpend.app（菜单栏应用）
# 用法：
#   ./build.sh          本机构建（会把本机 node 路径写入打包配置）
#   ./build.sh release  发布构建（剥离机器相关路径，生成可分发的 zip）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"           # DeepSeekSpend 项目目录
OUT="$ROOT/../DeepSeekSpend.app"                 # 生成的 App 放在「deepseek 消费」文件夹里
APP_NAME="DeepSeekSpend"
BUNDLE_ID="com.deepseekspend.menu"
TMP="$ROOT/.build"
MODE="${1:-local}"

echo "==> 清理旧产物"
rm -rf "$OUT" "$TMP"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" "$TMP"

echo "==> 编译 Swift (arm64, macOS 13+)"
swiftc -O \
  -target arm64-apple-macosx13.0 \
  "$ROOT/App/main.swift" \
  -o "$OUT/Contents/MacOS/$APP_NAME" \
  -framework AppKit -framework SwiftUI -framework ServiceManagement

echo "==> 复制采集器与配置"
cp "$ROOT/collector.mjs" "$OUT/Contents/Resources/collector.mjs"
cp "$ROOT/config.json"   "$OUT/Contents/Resources/config.json"

# 决定 node 路径并写入打包配置（App 启动时优先使用）。
# 注意：如果 node 二进制位于 ~/Documents 下，GUI 启动的子进程会在 dyld
# 加载阶段被 TCC 卡死，因此把它复制到不受 TCC 限制的 Application Support。
SUPPORT_NODE="$HOME/Library/Application Support/DeepSeekSpend/node"
NODE_BIN="$(command -v node || true)"
NODE_PATH=""
if [ -n "$NODE_BIN" ]; then
  case "$NODE_BIN" in
    "$HOME/Documents/"*)
      echo "==> node 位于 Documents（受 TCC 保护），复制到 Application Support"
      mkdir -p "$(dirname "$SUPPORT_NODE")"
      if [ ! -x "$SUPPORT_NODE" ] || [ "$NODE_BIN" -nt "$SUPPORT_NODE" ]; then
        cp "$NODE_BIN" "$SUPPORT_NODE"
        chmod +x "$SUPPORT_NODE"
      fi
      NODE_PATH="$SUPPORT_NODE"
      ;;
    *)
      NODE_PATH="$NODE_BIN"
      ;;
  esac
fi
if [ -n "$NODE_PATH" ]; then
  python3 - "$OUT/Contents/Resources/config.json" "$NODE_PATH" "$MODE" <<'PY'
import json, sys
p, node, mode = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = json.load(open(p, encoding="utf-8"))
if mode == "release":
    # 发布包不能带机器相关路径：移除 nodePath，App 启动时会自动探测
    cfg.pop("nodePath", None)
    print("release 模式：不写入 nodePath（App 运行时自动探测）")
else:
    cfg["nodePath"] = node
    print("nodePath ->", node)
json.dump(cfg, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
fi

echo "==> 生成图标"
swift "$ROOT/genicon.swift" "$TMP/icon_1024.png"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT/Contents/Resources/AppIcon.icns"

echo "==> 写入 Info.plist"
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>DeepSeekSpend</string>
	<key>CFBundleDisplayName</key>
	<string>DeepSeek 消费</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>NSHumanReadableCopyright</key>
	<string>本地工具 · 数据不出本机</string>
</dict>
</plist>
PLIST

echo "==> 代码签名（稳定自签名身份，避免每次重建都触发系统权限弹窗）"
SIGN_ID="DeepSeekSpend Dev"
SIGN_DIR="$ROOT/.sign"
SIGN_KC="$SIGN_DIR/signing.keychain-db"
mkdir -p "$SIGN_DIR"
if ! security find-identity -v -p codesigning "$SIGN_KC" 2>/dev/null | grep -q "$SIGN_ID"; then
  echo "    创建签名身份…"
  openssl req -new -newkey rsa:2048 -x509 -nodes -days 3650 \
    -subj "/CN=$SIGN_ID/O=Local/OU=Tools" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -keyout "$SIGN_DIR/key.pem" -out "$SIGN_DIR/cert.pem" 2>/dev/null
  openssl pkcs12 -export -out "$SIGN_DIR/identity.p12" \
    -inkey "$SIGN_DIR/key.pem" -in "$SIGN_DIR/cert.pem" -passout pass:dssign 2>/dev/null
  security delete-keychain "$SIGN_KC" 2>/dev/null || true
  security create-keychain -p dssign "$SIGN_KC"
  security import "$SIGN_DIR/identity.p12" -k "$SIGN_KC" -P dssign \
    -T /usr/bin/codesign -A 2>/dev/null
  security add-trusted-cert -d -r trustRoot -k "$SIGN_KC" "$SIGN_DIR/cert.pem" 2>/dev/null
fi
if security find-identity -v -p codesigning "$SIGN_KC" 2>/dev/null | grep -q "$SIGN_ID"; then
  # codesign 只在钥匙串搜索列表中查找身份：临时加入 → 签名 → 还原
  LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"
  security list-keychains -d user -s "$SIGN_KC" "$LOGIN_KC" 2>/dev/null
  security unlock-keychain -p dssign "$SIGN_KC" 2>/dev/null || true
  if codesign --force --deep --sign "$SIGN_ID" "$OUT" 2>/dev/null; then
    echo "    已用「${SIGN_ID}」签名（跨版本身份稳定）"
    SIGNED=1
  else
    echo "    签名失败，退回 ad-hoc"
    codesign --force --deep --sign - "$OUT"
    SIGNED=0
  fi
  security list-keychains -d user -s "$LOGIN_KC" 2>/dev/null
else
  echo "    签名身份不可用，退回 ad-hoc"
  codesign --force --deep --sign - "$OUT"
  SIGNED=0
fi

echo "==> 完成"
echo "App: $OUT"
du -sh "$OUT"

# 发布模式：打 zip 包到 dist/
if [ "$MODE" = "release" ]; then
  DIST="$ROOT/dist"
  mkdir -p "$DIST"
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$OUT/Contents/Info.plist" 2>/dev/null || echo 1.0.0)"
  ARCH="$(uname -m)"
  ZIP="$DIST/DeepSeekSpend-v${VERSION}-macOS-${ARCH}.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$OUT" "$ZIP"
  echo "==> 发布包: $ZIP"
  ls -lh "$ZIP"
fi
