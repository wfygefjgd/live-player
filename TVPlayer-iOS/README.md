# TVPlayer iOS 1.8 Stable

自签侧载版本的 TVPlayer 1.8 稳定版直播播放器。

## 功能特性

- M3U/M3U8 直播源播放
- 源可以自定义，支持添加和切换 M3U/M3U8 地址
- 多线路自动切换（超时、卡顿、无声自动切线）
- 智能切线：无声音/卡顿/超时自动切换
- 后台音频播放
- 数字键选台（iPad 外接键盘）
- 收藏/隐藏频道
- WiFi/蜂窝网络感知

## 构建与安装

### 方式一：GitHub Actions 自动构建（推荐）

1. Fork 本仓库到你自己的 GitHub 账号
2. 在仓库 Settings → Secrets and variables → Actions 中添加以下 secrets（可选，用于签名）：
   - `BUILD_CERTIFICATE_BASE64`: Base64 编码的 .p12 证书（如无则使用临时自签名）
   - `P12_PASSWORD`: 证书密码
   - `BUILD_PROVISION_PROFILE_BASE64`: Base64 编码的 mobileprovision（可选）
   - `TEAM_ID`: Apple Developer Team ID（可选）
3. 推送一个 tag 触发构建：
   ```bash
   git tag v1.8
   git push origin v1.8
   ```
4. 在 Actions 页面等待构建完成
5. 在 Release 页面下载 `TVPlayer.ipa`
6. 使用 [Sideloadly](https://sideloadly.io/) 或 [AltStore](https://altstore.io/) 侧载安装

### 方式二：本地 Xcode 构建

```bash
git clone https://github.com/YOUR_USERNAME/TVPlayer-iOS.git
cd TVPlayer-iOS
open TVPlayer_iOS.xcodeproj
# 选择 Team 和签名证书，然后 Archive → Distribute App
```

## 侧载工具

| 工具 | 特点 |
|------|------|
| [Sideloadly](https://sideloadly.io/) | 免费，每周需重签 |
| [AltStore](https://altstore.io/) | 免费，需要电脑辅助 |
| [TrollStore](https://github.com/opa334/TrollStore) | 永久签名（iOS 14-17 部分版本） |
| [Scarlet](https://usescarlet.com/) | 支持无线安装 |

## 系统要求

- iOS 15.0+
- iPhone / iPad
- 需要网络连接加载直播源

## 项目结构

```
TVPlayer_iOS/
├── Model/          # 数据模型（Channel）
├── View/           # SwiftUI 视图
├── ViewModel/      # 播放器状态管理
├── Engine/         # AVPlayer 播放引擎
├── Service/        # 网络/存储/音量辅助
└── Util/           # 工具类
```

## License

MIT
