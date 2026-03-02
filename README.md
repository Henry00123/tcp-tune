# 🚀 VPS Smart Network Tuner (VPS 智能网络调优脚本)

![License](https://img.shields.io/badge/License-MIT-blue.svg)
![Version](https://img.shields.io/badge/Version-v4.7-brightgreen.svg)
![Bash](https://img.shields.io/badge/Language-Bash-yellow.svg)

专为**跨洋高延迟链路**、**上下行不对称带宽**以及**高并发流媒体/Web服务**打造的 Linux 网络底层内核调优神兵利器。

告别市面上“一刀切”的无脑 BBR 脚本，本脚本通过物理内存与实际带宽的动态算力模型，精准滴灌，实现极速吞吐与极低重传的完美平衡。

## ✨ 核心痛点与解决方案 (为什么选择本项目？)

市面上的常规优化脚本（如无脑拉大缓冲区）往往会带来灾难性后果：
1. **不对称带宽的受害者：** 如果你的 VPS 是 `500M 下行 / 50M 上行`，常规脚本要么撑爆你的发送内存，要么腰斩你的下载速度。
2. **运营商 QoS 拔网线：** BBR 算法极具侵略性，一旦突发超速，极易触发上级路由器的强制丢包（Policing），导致单次测速出现数万次重传，甚至直接断流。
3. **高延迟起步慢：** 跨海 160ms 延迟下，默认的 TCP 初始窗口（`initcwnd=10`）需要多次往返才能完成首屏加载。
4. **多核 CPU 围观：** 千兆大带宽下，网卡软中断全压在 `CPU0` 上，导致单核 100% 满载卡死，其他核心闲置。

**本项目通过以下底层技术完美解决上述问题：**

### 🌟 独家核心特性

* ⚖️ **真·非对称缓冲区计算 (Asymmetric BDP Tuning)**
  * 彻底分离接收（RX）与发送（TX）缓冲区。榨干 500M 下载的同时，严格限制 50M 上传的排队内存，杜绝 Bufferbloat。
* 🛡️ **动态 OOM 防护机制**
  * 根据物理内存大小动态计算 TCP 全局红线（最高占用 25% 内存），1核1G 小鸡绝对不会因为高并发爆内存死机。
* 🚦 **智能流量整形 (TC FQ Pacing)**
  * 可选开启出站流量限速。通过平滑发包，彻底规避运营商的按压式限速惩罚，将 **数万次重传瞬间降至 0**，曲线稳如直线。
* ⚡ **跨洋高延迟起步爆发 (initcwnd=32)**
  * 修改路由表初始拥塞窗口，大幅减少 TCP 慢启动时的 RTT 往返次数，API 与网页首包响应速度提升 200%。
* 🧬 **多核收包均衡 (RPS/RFS 分流)**
  * 自动计算 CPU 掩码，将网卡软中断均匀分摊给所有核心，大幅提升高并发/大带宽下的系统抗压能力。
* 💾 **Systemd 级无感持久化**
  * 自动接管 Linux 重启后会失效的 `initcwnd` 和 `RPS` 设置，创建静默系统服务，保证每次开机状态满血恢复。



---

## 🛠️ 安装与使用

### 环境要求
* 系统：Ubuntu 18.04+ / Debian 9+ / CentOS 7+ (建议使用较新版本)
* 内核：Linux Kernel 4.9+ (内置 BBR 支持即可，兼容官方原版内核及 XanMod)
* 权限：`root` 权限运行

### 一键运行命令
```bash
wget -O vps_tune.sh [https://raw.githubusercontent.com/Henry00123/tcp-tune/main/tcp_tune.sh](https://raw.githubusercontent.com/Henry00123/tcp-tune/main/tcp_tune.sh) && chmod +x vps_tune.sh && ./vps_tune.sh
