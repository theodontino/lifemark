# Git 与当前基线

当前维护基线为 **UX 更新后版本**，标签 `v0.1.0-ux-baseline.1`，分支 `main`。范围、已有验证和已知问题见 [CURRENT_BASELINE.md](docs/CURRENT_BASELINE.md)。Git仅在本地建立，尚未上传GitHub；安装包、日志和个人签名配置不入库。

## 新增：计时器主界面

打开App默认进入“计时与记录”：输入事项→开始计时→结束并保存。运行一项时输入下一项，可“结束当前，开始这一项”；也支持并行开始。
计时开始时间保存在本机，重开恢复；结束时原子保存实际时间记录，重复结束不重复记录。进行中的计时不跨设备同步。
iPhone已加入锁屏实时活动及灵动岛扩展，点击返回计时首页手动结束。需系统允许实时活动，灵动岛显示由系统决定，约8小时的系统显示上限不结束本机计时。尚未真机验证。
新增7项计时器测试，Store总19项通过，加Core14项共33项。Mac计时、切换下一项、结束保存已进行实际界面验证。
最新版Mac压缩包为 dist/人生记录-Mac-计时版.zip。

# 人生记录 · 本地开发测试版 0.1

这是 iPhone + Mac 原生人生回顾应用的首个整合开发版。产品仅记录实际发生的事，不提供计划排程。

## 直接使用 Mac 版

打开 dist/人生记录.app，首次可从「记一笔」「读截图」「补记时间」开始。

- 记一笔：信用卡、微信、支付宝等账户名称可自行填写。
- 读截图：在本机用 Apple Vision 识别中文和英文，核对后入账；也可先留草稿。
- 实际时间：支持同时进行的事项，统计覆盖时间时去重。
- 回顾：账期分类、近六月账目、有记录月份的总额及分类平均、商户与分类次数、用户自己标记后悔的消费、大额消费规模比较、事项平均/中位耗时。
- 设置：账单日1…31、记录导出、AI兼容接口与密钥、自动记录入口。

这不是银行账户连接工具：账户名称是记录标签，不会读取银行账号、登录银行或自动执行转账。信用卡还款选“转账 / 还款”，不重复记消费。现版统计人民币，其他币种记录不混算。

## 自动记录

Mac 采屏基础来自 MIT Dayflow，iPhone 定位基础来自 Apache-2.0 Overland。已有两端适配出口：屏幕摘要和完整地点停留进入待核对区；人工修订独立保留，重跑采集不覆盖。

Mac 初次打开保持暂停；在设置打开屏幕采集页面，配置系统权限和所选模型后主动开启。原采集设置部分仍为英文，模型配置与新生活页 AI 设置暂分开。退出 App 会真实结束进程；新启动不自动开始录屏。

iPhone 入口已经整合到同一 App；设置中的按钮打开原定位采集界面。没有在用户手机上运行过，后台完整度、耗电与实际位置数据需真机检验。

原始屏幕内容与密集位置证据保留在采集设备，不进入已列入同步的业务表。屏幕摘要/地点停留本身可能包含生活信息，请按需要启停采集。

## iCloud 与 AI 状态

用户目前没有付费 Apple Developer Program 账号。本版已经接入 SQLiteData/CloudKit 同步代码、不可变修订和冲突选择；尚未配置自有容器和签名。界面显示“仅本机 · iCloud 尚未配置”，不会声称同步成功。

账号到位后需要配置两端同一私有 CloudKit 容器、相关签名与远程通知，并完成真实双机测试。iPhone 开发签名检查目前通过 provisioning profile 读取；TestFlight/App Store 的签名检测路线尚需交付前验证。

云端 AI 支持用户自行填写兼容 Chat Completions 的服务根地址、模型和密钥。密钥进本机系统钥匙串；未填写时不会主动调用。截图增强发送本机OCR文字；回顾发送页面可预览的汇总，不发送录屏、完整聊天或原始位置。没有接入用户真实付费服务实测，费用由所选服务商决定。

## 已验证

- Mac 原生 target 编译通过，ad-hoc 本机签名。
- iOS 真机架构 target 编译通过，未签名、未安装到手机。
- LifeCore 14项测试通过：精确金额、实付优先、退款/转账、月末账单日、重叠去重、跨界裁剪、月均和典型耗时等。
- LifeStore 12项测试通过：保存/编辑/删除/重开、并改冲突、摘要去重与人工覆盖、原始位置仅本机保存、同步未配置状态、同库多实例刷新、旧表单拒绝覆盖新修改/复活删除。
- Mac UI实际操作通过：手工12.34元账目、30分钟事项、回顾数值、退出重开恢复、删除后统计更新。
- 中文合成付款图实际OCR通过：实付28.50、原价35.00、优惠6.50、余额888.88同时出现，正确识别实付/商户/微信/时间并确认入账。合成图不能代表所有真实支付截图准确率。
- 临时测试数据已从可见账本和时间记录清理。
- 独立复核后的旧表单保护已补测试；换图失败后旧字段清空与拒绝误入账已在Mac界面复测。

## 尚未验证或未完成

- 真机双端iCloud同步、iPhone后台定位/耗电、真实日常Mac录屏与所选AI分析。
- 用户真实微信/支付宝/银行卡/信用卡截图的覆盖率，退款/多笔图的实图效果。
- 原生iOS照片选择的实际手机操作；iOS系统分享扩展尚未制作，可先从照片或文件导入。
- 录屏自动分类的准确率、长期数据量性能，以及完整历史数据迁移。
- 银行账单批量导入、完整资金资产/还款计算；大额比较仅使用已记录支出，不代表偿付能力。
- Mac自动记录与原采集设置仍有英文和上游界面；生活主界面为中文。

## 源码与复用

项目：LifeRecord.xcodeproj  
可维护的生成配置：project.yml（XcodeGen）  
共享模块：Packages/LifeCore、LifeStore、LifeUI  
采集适配：App/Integration  
实际固定来源与版本：UPSTREAMS.lock.json  
第三方许可：THIRD_PARTY_NOTICES.md、Licenses/

原始上游仓库保存在 Upstream/ 内，并保留 .git 供后续查看差异和更新。没有向 GitHub 发布新仓库。

实际复用是 Dayflow/Overland/FMDB/SQLiteData 及其依赖、ezBookkeeping收据提示规则。早先方案列的 My Wallet 经审查未摘入源码：其英语金额兜底不适合中文截图，核心计算与保守解析独立实现。详见 LifeCore/SOURCE_NOTES.md。

## 开发构建

当前本机 Xcode27.2 / Swift6.4.2。SQLiteData1.13.0需要Swift6.4；产品最低iOS17/macOS14。

```sh
xcodegen generate
xcodebuild -project LifeRecord.xcodeproj -scheme LifeRecordMac -destination 'platform=macOS' -skipMacroValidation -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
xcodebuild -project LifeRecord.xcodeproj -scheme LifeRecordiOS -destination 'generic/platform=iOS' -skipMacroValidation -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
swift test --package-path Packages/LifeCore --disable-sandbox
swift test --package-path Packages/LifeStore --disable-sandbox
```

上述宏由固定版本的公开依赖提供。测试环境曾用 /private/tmp 浅镜像加速 GRDB/SwiftSyntax 下载，镜像是相同官方提交，未把临时路径放入项目声明。普通开发环境使用官方GitHub来源。未开启任何屏幕或定位采集来运行自动测试。


## Apple Watch 简单计时入口（2026-11-12）

手表 App 名称“人生计时”，源码 App/Watch/WatchTimerApp.swift，手机通信 App/Integration/PhoneWatchTimerBridge.swift。

- 显示 iPhone 上的当前事项、类别和累计时长；可以结束并保存。
- 无计时时，可以输入或系统口述事项，或从最近8个已确认事项里选择。无历史时提供备课/上课/吃饭/休息入口。
- 第一版作为手机遥控入口，需要能连接配对 iPhone。手机是记录的唯一写入端；手表不独立排队记账或离线开始。
- 不通时显示上次状态并提示；操作要等手机回执，传输失败保留同一请求，允许重试，避免重复写入。
- 请求编号直接作为本地计时编号，重复请求跨重启仍不会重复开始；已结束或已取消的编号不能重新启动。
- 状态使用手机持久化递增序号和安装代号排序，不依赖手机墙上时钟，避免调时间后拒收新状态。
- iPhone 的 WatchConnectivity 在 AppDelegate 启动时安装，支持系统后台唤醒；手表结束会通知实时活动控制器更新。

验证：手表单独编译通过；手机+嵌入手表 App 签名编译通过；Store21项测试通过，含重启重试、已结束与已取消后重试不复活。
真机未验：Mac 与 Watch 的开发连接被手表拒绝（RemotePairingError1035），系统要求配对 iPhone 有线连接 Mac 重新建立开发配对；用户目前无数据线，要求先保留代码。未解除手表与手机配对，未重置任何设备。

后续继续：iPhone 数据线连接 Mac、解锁并信任 → 检查手表开发连接/开发者模式 → 针对手表设备重新生成描述文件与签名 → 安装配套 iPhone 和 Watch 最新同版 → 测手机开始/手表结束、手表开始/手机出现、断连重试不重复。当前 generic Watch 描述文件并不包含该手表 UDID，不能当作已具备真机安装条件。

构建目标 LifeRecordWatch，最低 watchOS10。无需 iCloud 或额外云服务来完成手机手表通信。手机已安装的是首次加入 Watch 桥接的开发中版本；后续安装 Watch 时必须同时更新手机到本目录最终代码构建的匹配版本。


## 重新签名并覆盖安装

日常在项目根目录双击 `重新签名安装.command`。说明见 `重新签名说明.txt`。

终端 / Luna：`python3 Scripts/resign_install.py`；`--check` 仅检查连接和签名；`--watch` 仅在真实手表开发连接已建立后使用。
使用 `Scripts/resign-config.json` 中既有设备和团队，不自动选其他手机，不卸载或清空数据。先构建并核对 bundle ID、团队、设备描述文件和实际有效期，再安装。默认仅更新手机；包含手表代码的 iPhone 包不代表手表安装验证成功。
脚本可整体随项目移动；缓存可重建，临时镜像不存在时使用项目原始官方依赖源。新运行日志写到 `validation/resign/日期时间/`。若苹果复用尚有效的签名，脚本如实显示期限，不声称自动延长7天。
验证：`python3 Scripts/test_resign_install.py` 5项通过；双击入口通过 zsh 语法检查；真实 `--check` 在当前手机未连接时正确停止，没有执行构建或安装。本轮未实际重新安装，不把脚本逻辑测试当作真机重新签名验收。


## 2026-11-13 交互修复

用户代码复查所列10项已逐项处理，行为、验证范围与限制见 [交互复查修复记录](docs/交互复查修复-20261113.md)。本轮测试与构建日志保存在 `validation/recovery-20261113/`，不再依赖临时目录中的日志。修复后的Mac包单独交付，手机与Watch本轮未安装；实际设备UI验收仍需补做。
