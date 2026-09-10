# CodeCut 对外分发清单

项目已经启用 Hardened Runtime，并准备好 `developer-id` 导出配置。以下步骤只需在 Apple Developer Program 已激活、钥匙串中出现有效的 `Developer ID Application` 证书后执行。

## 1. 归档并导出 Developer ID 应用

```bash
cd CodeCutMac
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project CodeCut.xcodeproj \
  -scheme CodeCut \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath Release/CodeCut.xcarchive \
  archive

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -exportArchive \
  -archivePath Release/CodeCut.xcarchive \
  -exportPath Release/DeveloperID \
  -exportOptionsPlist DistributionExportOptions.plist
```

## 2. 保存公证凭据并提交

首次执行时，将 Apple ID、团队 ID 和 App 专用密码交互式保存到钥匙串：

```bash
xcrun notarytool store-credentials CodeCutNotary
```

压缩、提交并等待结果：

```bash
ditto -c -k --sequesterRsrc --keepParent \
  Release/DeveloperID/CodeCut.app Release/CodeCut-notary.zip
xcrun notarytool submit Release/CodeCut-notary.zip \
  --keychain-profile CodeCutNotary --wait
```

## 3. 装订并验证

```bash
xcrun stapler staple Release/DeveloperID/CodeCut.app
xcrun stapler validate Release/DeveloperID/CodeCut.app
spctl --assess --type execute --verbose=4 Release/DeveloperID/CodeCut.app
```

只有最后三条全部成功，才把应用交给其他用户。不要把 Apple ID、App 专用密码或 API Key 写入项目文件。
