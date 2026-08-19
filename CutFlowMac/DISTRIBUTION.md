# CutFlow 对外分发清单

项目已经启用 Hardened Runtime，并准备好 `developer-id` 导出配置。以下步骤只需在 Apple Developer Program 已激活、钥匙串中出现有效的 `Developer ID Application` 证书后执行。

## 1. 归档并导出 Developer ID 应用

```bash
cd CutFlowMac
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project CutFlow.xcodeproj \
  -scheme CutFlow \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath Release/CutFlow.xcarchive \
  archive

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -exportArchive \
  -archivePath Release/CutFlow.xcarchive \
  -exportPath Release/DeveloperID \
  -exportOptionsPlist DistributionExportOptions.plist
```

## 2. 保存公证凭据并提交

首次执行时，将 Apple ID、团队 ID 和 App 专用密码交互式保存到钥匙串：

```bash
xcrun notarytool store-credentials CutFlowNotary
```

压缩、提交并等待结果：

```bash
ditto -c -k --sequesterRsrc --keepParent \
  Release/DeveloperID/CutFlow.app Release/CutFlow-notary.zip
xcrun notarytool submit Release/CutFlow-notary.zip \
  --keychain-profile CutFlowNotary --wait
```

## 3. 装订并验证

```bash
xcrun stapler staple Release/DeveloperID/CutFlow.app
xcrun stapler validate Release/DeveloperID/CutFlow.app
spctl --assess --type execute --verbose=4 Release/DeveloperID/CutFlow.app
```

只有最后三条全部成功，才把应用交给其他用户。不要把 Apple ID、App 专用密码或 API Key 写入项目文件。
