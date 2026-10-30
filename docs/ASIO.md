# ASIO 输出扩展

现有 WASAPI/WDM 输出保持默认。ASIO 通过同一个 `MultiEndpointRenderer` 入口接收解码后的 PCM，适用于现有 MAT、DTS:X、PCM 布局路由命令。选择一个 ASIO 驱动后，整个布局共用该设备时钟；目前一个配置只能有一个 ASIO 输出路由，不混用 ASIO 与 WASAPI，也不聚合多个 ASIO 驱动。

## 通道数的含义

ASIO 输出与 PCM 队列使用动态容器，不设 8、12 或 32 声道上限。物理输出通道由 `IASIO::getChannels` 查询，映射必须落在驱动报告的范围内，不使用 Windows 扬声器通道掩码。通道总数仍受驱动、ASIO 的 `long` 接口、内存和实时处理能力约束。

移除了原生布局解析的 12 个扬声器上限和 PCM 队列的 32 声道上限。这并不会增加输入音源的信息量：原生 PCM 捕获仍是上游的 7.1.4 输入，Cinema、MAT、DTS:X 解码能力仍取决于原有解码链路。自定义更大布局使用原有声像/混音逻辑，不能将 7.1.4 宣称为额外的独立原生解码声道。

## Studio 与 Cinema

Studio 的 **Salidas** 页提供 ASIO 驱动选择器：

1. 打开已有扬声器配置，点击 **Actualizar ASIO** 枚举已安装的 x64 ASIO 驱动。
2. 选择驱动，输入按该路由扬声器顺序排列的物理通道（从 1 开始；留空使用 1..N）。
3. 设置 buffer 帧数，0 使用驱动首选值，点击 **Usar / aplicar ASIO**。
4. 保存为一个新配置以保留原来的多设备 WASAPI 配置，再测试扬声器和启动桥接。

应用设置时会短暂打开设备查询实际输出数、48 kHz 支持与缓冲限制，不启动音频，也不修改采样率。先停止桥接后再执行此查询。所有逻辑扬声器合并到一条 ASIO 主路由；旧路由的不同延迟不转移到合并路由，ASIO 路由延迟可在表格中设置。重选 WASAPI endpoint 会清除该路由的 ASIO 设置，恢复多个 WASAPI 设备请重新打开之前保存的配置。

程序每次启动会读取安装目录中的 `default.ini`，默认 7.1.4 使用 Dante Virtual Soundcard，兼容 `(64x)` 名称。输出顺序为 L,R,C,LF,LS,RS,LSR,RSR,LTF,RTF,LTR,RTR（ASIO 1..12）。INI 内部规范名依次为 FL,FR,FC,LFE,SL,SR,BL,BR,TFL,TFR,TBL,TBR。Studio 保存该默认配置时也更新此 INI，重启后保留编辑。

Cinema 已有中文图形入口：双击 `SpatialAudioLab.Cinema.exe` 打开窗口。影片以 Float32 PCM 通过 `render-pcm-stdin` 直送同一个原生 ASIO/WASAPI 引擎，不需要虚拟驱动或 Windows Dolby/DTS 提供程序。原有命令行命令仍由入口转发至 `SpatialAudioLab.Cinema.Engine.exe`。影院的输出时钟是渲染进度估计，硬件时钟偏差仍需实测。

游戏实时桥接保留虚拟驱动路径。Studio 现在会真正调用空间音效准备与验证工具，自动识别虚拟端点及设备实例，保留端点状态备份和诊断日志。Dolby/DTS 应用内许可状态由各自应用管理；不能把端点配置成功等同于真实激活验收。

HISENSE 虚拟端点可以在 PnP 查询不可用、容器 ID 不一致或存在多个 SysVAD 根设备时识别。
Studio“实时桥接”页提供可保存的 Windows 捕获端点选择；手动指定的端点离线时会提示重新选择，
不会悄悄改用其他设备。PnP 实例无法确认时，仍可配置已识别的端点，但不会猜测要重启的设备。
微软正式签名的准备材料与当前状态见 [驱动签名说明](DRIVER-SIGNING.md)。

既有 V1 共享仪表协议显示前 32 个逻辑扬声器；较大的布局仍输出全部声道，仪表上限不再阻止桥接启动。

## 构建

需要 Windows x64、Visual Studio C++ 工具链及上游 README 列出的 SDK。另从 [Steinberg](https://www.steinberg.net/asiosdk) 获取 ASIO SDK，解压后指定包含 `common/iasiodrv.h` 的目录。SDK 不随本源码包分发。

```powershell
$env:SAL_ASIO_SDK_ROOT = 'C:\SDKs\asiosdk'
git submodule update --init --depth 1 driver/windows-driver-samples
.\tools\Initialize-SpatialAudioLab.ps1 -Component Driver
.\tools\Build-SpatialAudioLab.ps1 -Component CLI,Studio
```

也可使用 CMake；这是运行原生测试的入口：

```powershell
cmake -S . -B build-asio -A x64 -DSAL_ASIO_SDK_ROOT="$env:SAL_ASIO_SDK_ROOT"
cmake --build build-asio --config Release
ctest --test-dir build-asio -C Release --output-on-failure
```

直接构建 CLI 可运行 `tools/Build-DolbyProbe.ps1`。未设置 SDK 路径时构建仍保留 WASAPI，ASIO 命令会明确报告构建未启用 ASIO，不会回退到其他设备。

## 配置与播放

```powershell
.\build\SpatialAudioLab.CLI.exe list-asio
.\build\SpatialAudioLab.CLI.exe list-asio-channels '{你的驱动CLSID}'
```

复制 `configs/asio-714.ini`，将 `asio_driver` 替换为枚举到的 CLSID。`asio_channels` 是**从 1 开始**的设备物理通道，数量和顺序对应该路由的 `speakers`。例如 `1,2,3,4,5,6,7,8,17,18,19,20`。省略此字段则使用连续的 1..N 通道。不允许重复、负数、零、越界或缺少映射。

`asio_buffer_frames=0` 使用驱动首选缓冲大小；非零值必须满足驱动范围与粒度。ASIO 不采用 WASAPI 的 safe/balanced/low 周期选择。引擎要求驱动支持 48 kHz PCM，会在必要时请求切换采样率；不支持时明确失败，不进行隐式重采样。支持整型 16/24/32 位、32 位容器中的 16/18/20/24 位，以及 Float32/Float64 的大小端格式；不支持 DSD。

也可以保留现有布局的位置、增益和扬声器命名，生成新的配置（需要 Python 3）：

```powershell
py -3 tools/New-AsioLayout.py --driver '{你的驱动CLSID}' --output my-asio.ini
py -3 tools/New-AsioLayout.py --layout custom-layout.ini --driver '{你的驱动CLSID}' --output custom-asio.ini
```

生成器不覆盖已有配置。以下命令沿用上游捕获/解码与虚拟驱动前置条件：

```powershell
.\build\SpatialAudioLab.CLI.exe test-speaker 2 my-asio.ini TFL 0.05
.\build\SpatialAudioLab.CLI.exe test-layout 5 my-asio.ini 0.05
.\build\SpatialAudioLab.CLI.exe live-layout 0 my-asio.ini 0.25 40 balanced
.\build\SpatialAudioLab.CLI.exe live-dtsx-layout 0 my-asio.ini 0.25 40 balanced
.\build\SpatialAudioLab.CLI.exe live-pcm-layout 0 my-asio.ini 0.25 40 balanced
```

## 实时行为与故障

生产线程从原有 PCM 队列读取并应用路由延迟、主增益与扬声器 trim，写入预分配的单生产者/单消费者环形缓冲区。ASIO 回调不分配内存、不获取互斥锁、不访问原有可变 PCM 队列，只读环形缓冲并转换至驱动的分声道双缓冲。可用源数据耗尽后输出静音，后续数据到达时继续，不跳过尚未生成的源帧。回调计数使用编译期检查的无锁 64 位原子变量。

停止前等待最后提交的硬件块和驱动报告的延迟；软件排空判断同时检查源队列与环形缓冲。延迟变更在服务线程刷新。驱动重置、缓冲大小变化、重同步或采样率改变会停止桥接并提示重启；此版本不自动重新加载 ASIO 驱动。回调停止超过 5 秒（或超大缓冲时四个周期）会报告设备失联，避免永久等待排空。

只向配置选中的设备通道创建缓冲区；未选择的输出不由本应用驱动。驱动本身可能具有独占约束。整个进程一次只持有一个 ASIO 渲染实例，创建第二个实例会在加载驱动之前失败。

## 验证范围

可移植测试直接编译实际 ASIO host、布局解析与 PCM 队列；模拟驱动用于验证音频处理和资源生命周期，不代表真实设备测试：

```bash
python3 tools/Test-AsioPortable.py
python3 tools/Test-AsioPortable.py --sanitize address
```

覆盖 18 种采样格式、128 声道配置、65 声道实际双缓冲输出、512 路设备上的稀疏通道映射、10 万帧并发队列、增益、延迟、欠载恢复、尾块、设备查询、重置/采样率/缓冲通知及初始化失败资源回收。无 SDK 分支也单独编译。

.NET 测试覆盖 ASIO 配置保存、重载、Studio 模型往返、128 声道配置、错误映射与 WASAPI 切换。运行 `dotnet test tests/SpatialAudioLab.Core.Tests -c Release`。其中上游 `RuntimePathsTests.Installed_mode_uses_local_app_data` 使用 Windows 路径，完整测试应在 Windows 执行。

GitHub Actions 执行 Linux ASan/UBSan 测试和 Windows x64 的 WASAPI/ASIO 构建矩阵，包括原生测试、完整 Core 测试、Studio 构建及直接 CLI 构建脚本。CI 使用 SDK 镜像 `audiosdk/asio` 的固定提交 `496a0765b8bb9c26f764f22f9a9712a937177db2`，SDK 不提交到本仓库。

尚未执行真实 ASIO 设备、声道接线、长时间播放与完整 MAT/DTS:X/Cinema 硬件验收。硬件复测时先运行 `list-asio-channels`，确认物理声道和缓冲限制，再以 `test-speaker` 逐路检查，最后启动对应空间音频桥接。记录设备/驱动版本、buffer 帧数、输出延迟和 CLI 的 starvation 计数。
