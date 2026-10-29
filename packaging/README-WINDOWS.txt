SpatialAudioLab 空间音频工作室与影院 · 简体中文版 · Windows x64
第一方修改作者：B00kerLouis
源代码：https://github.com/B00kerLouis/spatial-audio-lab
原始项目：https://github.com/barralutz/spatial-audio-lab

快速使用
1. 将整个 ZIP 解压至可写目录。内含 .NET 执行环境，无需安装 SDK。
2. 先启动 Dante Virtual Soundcard，选 ASIO 模式、48 kHz、至少 16×16 声道，
   并在 Dante Controller 中配置网络订阅。识别标准名称及带 (64x) 的 64 位驱动。
3. 每次打开 Studio 或 Cinema 都自动读取程序目录中的 default.ini。
   默认 7.1.4 输出顺序为：
   ASIO 1=L，2=R，3=C，4=LF，5=LS，6=RS，7=LSR，8=RSR，
   9=LTF，10=RTF，11=LTR，12=RTR。
   INI 内部使用 FL,FR,FC,LFE,SL,SR,BL,BR,TFL,TFR,TBL,TBR 规范名称。
   可修改位置、增益、物理声道与缓冲；在 Studio 保存默认配置后，下次自动重载。
4. 双击 SpatialAudioLab.Cinema.exe 打开影院窗口，选择 MKV/MKA 并播放。
   影片通过 Float32 PCM 直接送至原生 ASIO/WASAPI 引擎，无需安装虚拟驱动或
   先启用 Dolby Access / DTS Sound Unbound。请先停止 Studio 的实时桥接，
   避免两个进程同时占用 Dante ASIO；影院会停止本应用自身的实时桥接。
   视频窗口支持暂停、定位、字幕与全屏；播放失败会保留在影院窗口及 Data/Logs。
5. Studio 提供扬声器位置、音量、声道映射、测音和游戏实时桥接。
   Cinema.Engine.exe 是命令行播放引擎，日常请打开 Cinema.exe。

游戏实时捕获与 Windows 空间音效
此功能需安装包内 Virtual Sink，并安装／配置相应的 Dolby Access 或
DTS Sound Unbound。它们应作用于 SpatialAudioLab 虚拟端点，ASIO Dante 用作
软件内部的物理输出。Studio 的启动按钮现在会实际检测、选择和验证空间音效；
“检查并重新注册 Dolby / DTS 应用”生成诊断报告并重新注册已安装的应用。
应用自身的许可与激活由相应应用处理；诊断会记录实际能力与请求结果。

虚拟驱动采用开发测试签名。使用 Windows 高级启动 → 启动设置 → 选项 7
（禁用驱动程序签名强制）进入开发启动，然后在管理员 PowerShell 中运行
Driver/Install-Driver.ps1。驱动安装会导入随包的公开测试证书；不自动改动
Secure Boot、BCD 或 BitLocker。实时游戏桥接请以管理员身份运行 Studio。
测试签名驱动启动期间避免运行内核反作弊游戏，完成后用
Driver/Uninstall-Driver.ps1 移除驱动及测试证书，并恢复正常启动。

诊断与边界
真实 Dante 网络时钟、硬件播放、Dolby/DTS 应用内激活及长期稳定性需在目标机复测。
影院原生输出时钟以已渲染 PCM 进度及设备延迟估计，未声称测得硬件时钟偏差。
TrueHD 后端仍使用通过回归的公开源码版本。ISF 与多 metadata 时间块会明确报告
不支持；当前渲染器要求 48 kHz。错误不会再表现为影院窗口一闪而过。

源码、许可与校验
build-manifest.json 记录提交和依赖版本，runtime-dependencies.json 记录下载摘要。
Licenses 保存第三方许可；Cavern 作者为 Bence Sganetz (VoidX)：
https://github.com/VoidXH/Cavern ，https://cavern.sbence.hu/ 。
ASIO SDK 仅为构建依赖，SDK 文件不包含在运行包内。ZIP 旁提供 SHA-256 校验文件。
