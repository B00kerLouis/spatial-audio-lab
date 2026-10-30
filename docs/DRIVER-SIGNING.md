# Virtual Sink 的微软驱动签名

第一方维护：B00kerLouis。保留 Microsoft SysVAD 及其他依赖的原有版权和许可。

`SpatialAudioLab-VirtualSink-x64-unsigned-submission.cab` 是待提交的材料，
**不是微软签名的驱动**。其中的 SYS/DLL/CAT 仍使用构建时生成的测试签名。
公开 CER 文件、导入受信任根证书、普通应用程序 Authenticode 签名，都不能代替微软内核签名。

构建脚本会打包本次构建的 INF、SYS、DLL、CAT 和对应的 x64 Release PDB，
并生成 SHA-256 清单。符号单独保存在提交材料中，不增加播放器运行包的体积。
同一个 SysVAD 目录中的基础、扩展、APO INF 共用 sysvad.cat，作为完整的关联文件集保留。

## 签名渠道

- 注册 Microsoft Hardware Developer Program／Partner Center，完成发布者身份验证，
  并关联可用的 EV 代码签名证书。证书私钥留在持有者的硬件或签名服务中。
- 面向正式发布使用 WHCP／HLK 测试与提交；此 CAB 不包含 HLK 结果，不能宣称已通过 WHQL。
- 如使用微软提供的 attestation 测试签名流程，按当前账户及目标 Windows 版本的要求提交。
  Attestation 不等于 HLK 认证，也不能直接向零售用户发布到 Windows Update。
- Azure Artifact Signing 的普通应用签名不能替代 Partner Center 的内核驱动签名。

官方步骤：

- https://learn.microsoft.com/en-us/windows-hardware/drivers/dashboard/code-signing-attestation
- https://learn.microsoft.com/en-us/windows-hardware/drivers/dashboard/driver-signing-offerings
- https://learn.microsoft.com/en-us/azure/artifact-signing/faq

## 提交与回收

1. 在证书持有者的 Windows 签名环境中，用关联的 EV 证书对 CAB 做 SHA-256 签名及时间戳。
   使用证书供应商支持的硬件令牌或远程签名工具，不上传私钥到仓库。
2. 登录 Partner Center，按账户当前提供的签名流程提交。CAB 签名本身不是最终微软签名。
3. 下载微软返回的驱动包。微软可能重建 CAT 或重签二进制；不要再运行测试签名步骤，
   不要修改返回的 SYS/DLL/INF/CAT，也不要用测试版文件覆盖它们。
4. 在 Windows SDK 环境运行 `signtool verify /kp /v` 验证内核签名，
   并用 `signtool verify /kp /v /c sysvad.cat TabletAudioSample.sys` 验证目录成员。
   同时核对 INF、DLL、CAT 的签名和文件清单。仅凭 PowerShell 显示 Valid 不等于完整内核策略验证。
5. 重新打包并在目标机上验证 Secure Boot 开启、TESTSIGNING 关闭时的安装及加载，
   检查设备状态和 `\\.\DolbyDecoderMat` 接口，再复测 7.1.4、Dolby/DTS 和 Dante 输出。
   完成前不能标记为“正常启动验证通过”。

当前 GitHub Actions 只完成编译、测试签名、CAB 准备与软件回归；没有微软账户／EV 私钥，
不会提交身份资料、购买证书或冒用其他发布者签名。
