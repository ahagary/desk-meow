# 狸花猫桌面宠物

原生 macOS 桌面宠物。当前默认形象已恢复为用户选定的原稿 `Assets/tabby-preferred.png`；原文件未改动。待办、便签和历史数据仍保存在本机。

## 构建与运行

需要 Apple Silicon Mac、Xcode 命令行工具和 Python 3.9+。构建目标为 `arm64`、最低 macOS 13；安装者无需安装这些开发工具。

```sh
xcode-select --install  # 只需安装一次，等待安装完成
./build.sh
open 'build/狸花猫桌面宠物.app'
```

点击猫咪打开「今日小纸条」；猫咪可拖动。菜单栏可打开动作预览、暂停闲逛、减少动态效果、开关声音与退出。数据存放在 `~/Library/Application Support/TabbyDesktopPet/data.json`。

## Git 仓库与发布

项目已初始化 Git，主分支为 `main`。源码、运行素材和工具进入仓库；`build/`、`dist/`、`output/`、本地凭据和临时文件被忽略。项目仓库为 [ahagary/desk-meow](https://github.com/ahagary/desk-meow)。首次关联与推送：

```sh
git remote add origin https://github.com/ahagary/desk-meow.git  # 已关联则跳过
git push -u origin main
```

Git 提交邮箱与远程登录是两回事：推送仍需 GitHub 的 SSH 或 HTTPS 认证。若目标仓库已有内容，应先合并，避免强制覆盖。

### 在本机生成安装包

```sh
./release.sh
```

脚本从当前源码重新编译，检查 arm64 架构，运行资源、动画状态和投喂数据检查，再生成：

- `dist/TabbyDesktopPet-0.1.0-macOS-arm64.dmg`：打开后将应用拖入 Applications。
- `dist/TabbyDesktopPet-0.1.0-macOS-arm64.zip`：解压后将应用放入“应用程序”。
- `dist/TabbyDesktopPet-0.1.0-macOS-arm64.sha256`：上述文件的 SHA-256 校验值。

M1 和 M2 使用同一个 arm64 包。版本号由 `VERSION` 管理；更新发布前修改该文件。默认最低 macOS 13 是编译与安装元数据的目标，仍应在最低系统版本的真实机器上验收。升级时先退出旧版再替换 `.app`，待办和便签数据保留在用户目录。

### GitHub 自动构建与 Release

`.github/workflows/release.yml` 会在推送 `main`、Pull Request 和手动运行时编译并上传安装包。可以在 GitHub 仓库的 Actions 页面下载，默认保留 14 天。本机暂时没有编译工具时也能使用此方式。

推送与 `VERSION` 一致的标签，会在构建和检查成功后创建带安装包的 **Release 草稿**：

```sh
git tag -a v0.1.0 -m 'Release 0.1.0'
git push origin v0.1.0
```

到 GitHub 的 Releases 页面检查草稿，再点击 Publish release，其他人就能在仓库可见范围内下载。不要把安装包提交进 Git 历史。工作流使用 [GitHub 官方 macOS 15 arm64 runner](https://github.com/actions/runner-images)。

### 签名与 Apple 公证

默认本地和 GitHub 自动构建使用 ad-hoc 签名，适合开发和测试分发，**不等于 Apple 认可的开发者签名**。下载后首次运行可能被 Gatekeeper 拦截；确认来源可信后，按 [Apple 的说明](https://support.apple.com/zh-cn/102445) 在“系统设置 → 隐私与安全性”中允许打开。

面向普通用户正式分发时，建议使用 Apple Developer Program 的 **Developer ID Application** 证书签名并完成 [Apple 公证](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。安装证书后，先在本机钥匙串交互式保存公证凭据，再运行：

```sh
xcrun notarytool store-credentials 'tabby-notary'
CODESIGN_IDENTITY='Developer ID Application: 你的开发者名称 (TEAMID)' \
NOTARYTOOL_PROFILE='tabby-notary' ./release.sh
```

脚本会启用 Hardened Runtime，提交 Apple 公证、装订公证票据，并检查签名。证书密码和 Apple 凭据不要写进源码或仓库。目前 GitHub 工作流没有导入开发者证书，自动生成的草稿会明确标记为未公证版本；已公证的本地安装包可以手动上传到 Release。

## 当前动作状态

### 投喂统一角色母图（2026-11-12）

本轮撤销了“分别给多套动作素材调色”的方向。问题不只是毛色：此前 `rise`、`jump`、`chew`、`wipe`、`turn` 来自不同批次，脸宽、眼距、耳距、胸纹、头身比和四肢粗细都不同，所以即使脚底锚点连续，连播时仍会像突然换猫。

现在完整投喂表演只使用 `feeding/feed-master-v1-normalized.png` 这一张 4 × 4 统一母图，覆盖坐姿、起身、站立、蓄力、跳跃、衔卡、落地、咀嚼、单爪擦嘴、正面/四分之三/侧后/背面转身。`feed-master-blink-v3.png` 的身体逐像素继承母图坐姿，只从同一母图的闭眼姿态移植左右眼睑，用于回身后的眨眼和等待 Todo 时的自然眨眼。独立生成的眨眼候选因重画了整只猫而被拒绝，没有接入。

动作链仍为 `FeedStart → Rise → CatchCard → Settle → Eat → Swallow → WipeMouth → StandAfterWipe → TurnBack → Poop → ReturnFront → Proud`。所有相邻动作复用完全相同的边界帧；转身通过身体、肩膀和后躯逐姿势改变视角，不再对整张猫图旋转。旧的起身、跳跃、咀嚼、擦嘴和转身图集保留作历史参考，但不再被投喂运行时引用。待机 `Idle`、`IdleAccent`、`Hover` 及原定稿 `tabby-preferred.png` 未修改。

统一母图的生成引用、提示词摘要、网格规格、被拒绝稿和眨眼派生方法记录在 `feeding/feed-master-v1.json`。修改前的构建器、清单和注册表备份位于 `output/identity-repair-20261112/`。实际应用导出的 453 帧预览在 `http://127.0.0.1:8770/`；已检查正常速度、逐帧和回身后的闭眼帧。

### 投喂毛色一致性修正（2026-10-25）

用户指出完整投喂过程中猫咪毛色和形象跳变。检查发现 `rise-front-v5.png` 的橘红偏色、耳鼻饱和度与相邻素材明显不同；同一图集被起身、落地坐下、擦嘴后起身、收尾坐下和便签开合六个片段重复使用，使问题在整段反复出现。此前边界复用检查只能验证切换姿态，不能证明角色外观一致。

本轮用内置 image_gen 定向修正共用起坐素材，选用 `feeding/rise-coat-v8.png`，重新测量裁切区域及脚底/嘴部锚点。起坐次序、动作时长、跳跃、咀嚼、擦嘴和前后迈步素材保留；`Idle`、`IdleAccent`、`Hover` 与原定稿文件保持不变。另一个待机过渡修色候选没有明确改善，未接入运行时。

`Tools/inspect_coat.swift` 只读检查 sRGB 棕色中间调，排除透明像素、极暗条纹、浅色胸毛和眼睛，避免整图 RGB 均值被姿势影响。修正前起坐中间调色相中位数约 21.7°、饱和度 0.646；本次约 24.3°、0.556，相邻擦嘴素材约 24.7°、0.573。统计用于定位偏色，不能替代脸型、条纹和连播的美术检查。各候选、完整提示词、来源和限制记录在 `feeding/identity-20261025.json`，结果在 `coat-audit-20261025.json`；新稿仍属于待审阅素材。

预览 `http://127.0.0.1:8770/` 增加原定稿与修改前后同步对照；只有前后时间线的状态、帧索引完全对应时才显示比较，图片带版本号以防浏览器继续使用旧缓存。资源、流程、任务存储和边界衔接检查通过；本轮没有修改投喂数据逻辑。

### 投喂衔接打磨（2026-10-24）

本轮保留 `Idle`、`IdleAccent`、`Hover` 的现有帧、时长和资源引用。新增素材仅用于投喂和便签开合衔接：

- 起坐使用正面逐帧动作，调整后的头身比例位于 `feeding/rise-front-v5.png`；跳跃使用 `jump-proportions-v2.png`，根部上移幅度从 28pt 调整为 14pt，并在落地缓冲帧前归零。
- 起身、落地坐稳、咀嚼、吞咽、擦嘴、转背、下蹲、回身与收尾的边界复用同一姿态，避免动作切换时突然换体型。
- `idle-bridge-v1.png` 用小幅迈步把正面站姿接回已有的三分之四待机站姿；`FaceCard` 让已经站着的猫先调整朝向再接卡。
- 快速开关便签会先完成正在播放的起坐；排队投喂也会等待起坐完成。投喂结束时便签仍开着就继续坐着，便签已关闭则起身后恢复现有待机。

原生状态机导出的 `journey.gif` 与预览页涵盖「已有待机 → 打开便签 → 写 Todo → 投喂 → 坐着陪伴 → 关闭便签 → 恢复已有待机」，演示约 17 秒；单次投喂的素材时长合计约 10.5 秒。预览按 30fps 采样，真实应用按 60Hz 更新，姿态仍使用明确的逐帧时长。`polish-20261024.json` 保存生成提示词、选用素材、被剔除的版本和验证范围。

资源、相邻动作姿态一致性、快速开合便签、恢复待机及任务存储/队列检查已通过。原生窗口自动点击复测遇到控制工具超时；已在浏览器检查同一原生渲染器与状态机输出，不把自动点击记作通过。

### 角色母版与完整喂食动画（2026-10-23）

`Assets/character-model/v1/` 保存以最初定稿生成的站立正面、站立侧面、站立背面、蹲坐正面四张 1402 × 1122 透明 PNG。原稿的字节与 SHA-256 保持不变。新视角属于待审阅的角色设定，不能自动标记为用户已确认。

打开该目录的 `review.html` 可对照原稿与四视图；`wipe-preview.html` 是从蹲坐母版派生的 8 帧单前爪擦嘴预览，支持正常速度、半速和逐帧查看，动作 1.52 秒。支撑脚基线一致，抬起前爪后不保留重复的落地脚；头部保持正直，仅接触口鼻时略微前低。

`model.json` 保存身份约束、各视图的生成提示词与来源；`wipe.json` 保存姿态顺序、每帧时长和图集区域。擦嘴图集有效区域是 1980 × 792，4 列 × 2 行，每帧 495 × 396；原始 PNG 右侧与底部各多 1 像素完全透明边缘，播放器按显式区域读取，不缩放或重绘源图。

这组母版派生的起坐、跳跃、咀嚼、吞咽、擦嘴和迈步转身已接入运行时。擦嘴使用 8 个完整姿态，结束后追加 80ms 坐稳，再起身；同一只前爪抬起、触嘴、擦过、落回，禁止额外添加一只手。运行时不再用蹭人姿态或局部嘴巴补丁表现吃东西。

默认待机和蹭人仍沿用原稿体系。自主玩球、毛线和蝴蝶仍暂停。不会用低分辨率实验角色替代默认形象。

### 喂食交互（2026-10-23）

按用户最新反馈，流程为 `FeedStart → Rise → CatchCard → Settle → Eat → Swallow → WipeMouth → StandAfterWipe → TurnBack → Poop → ReturnFront → Proud`，当前完整表演约 10.5 秒：

1. 点击「喂给猫咪」，原任务行淡出并收成小纸卡，随后飘向猫咪。起点取自任务行实际屏幕坐标，排队任务开始时重新读取位置。
2. 猫咪保留点击前姿态；坐着时先经过起身中间姿势。已有站姿不会强行先坐下。
3. 猫咪跳起衔住卡片；卡片跟随当前帧嘴部落地，猫咪坐稳后分三口咀嚼吞下。道具和角色使用同一时间线，运行时按 60 Hz 刷新；美术姿态按各自帧时长播放。
4. 吞咽后坐着单爪擦嘴，落爪站稳，再起身。
5. 转背用 9 个迈步姿态（1.10 秒）：先转头、前爪抬起落下带动肩膀、后腿跟步带动胯部，最后背对站稳。
6. 拉粑粑后用独立绘制的 9 个回身姿态（1.10 秒）转回来：先回头看，再前后腿迈步，最后坐下眨眼。便便短暂停留后消散。

原稿 `tabby-preferred.png` 保持原文件。新图集位于 `Assets/character-model/v1/feeding/`，`provenance.json` 记录来源与生成提示词；`registration.json` 保存逐帧裁切区域、等比尺寸、脚底与口部锚点。`Tools/build_model_feeding.py` 可重新生成运行时清单。图集按实测区域读取，源 PNG 像素不变，不使用整猫旋转、交叉淡入或逆放静态朝向图来模拟转身。旧 `turn.png` 的朝向序列因“像转台”被停用，仅保留背面下蹲用于拉粑粑；下蹲前后直接复用两组迈步的边界帧。这些派生素材仍标记为 provisional，未视为用户确认的最终美术。

`build/preview-feeding-model-v1/index.html` 播放应用原生状态机与渲染器导出的逐帧画面，提供完整播放、循环转身、半速和逐帧检查；同目录有含待机和便签开合的 `journey.gif`、单独投喂的 `feed.gif` 与 `feed-steps.png`。从项目根目录运行 `python3 -m http.server 8770 --bind 127.0.0.1 --directory build/preview-feeding-model-v1` 后访问 `http://127.0.0.1:8770/`。

任务在播放前先落盘，退出不会丢失完成记录或重播。多项喂食排队，同一任务去重；等待中和播放中可撤销，播放结束后再保留 5 秒撤销入口。数据保存失败时保留未完成状态并显示错误。菜单栏「试喂一张卡片」可演示，不修改真实待办。

低分辨率实验稿保存在 `Assets/pixel/`，对应清单是 `Assets/pet-animations-pixel.json`。它们**不会打包进当前应用**。`Tools/generate_pixel_sprites.py` 只更新实验清单，不会覆盖默认清单。

可运行以下检查：

```sh
'build/狸花猫桌面宠物.app/Contents/MacOS/TabbyDesktopPet' --validate-resources
'build/狸花猫桌面宠物.app/Contents/MacOS/TabbyDesktopPet' --check-animation-flow
'build/狸花猫桌面宠物.app/Contents/MacOS/TabbyDesktopPet' --check-feeding
'build/狸花猫桌面宠物.app/Contents/MacOS/TabbyDesktopPet' --export-feed build/preview-feeding-model-v1
cp Tools/feed-preview.html build/preview-feeding-model-v1/index.html
'build/狸花猫桌面宠物.app/Contents/MacOS/TabbyDesktopPet' --export-preview build/preview-head-motion
```

`--check-feeding` 使用临时数据验证保存、重复点击、队列、撤销、中断和减少动态效果，不修改个人任务。UI 验收可用 `--data-file /absolute/path/to/fixture.json --open-notes` 指定独立数据文件。
