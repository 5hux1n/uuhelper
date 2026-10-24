<p align="center">
  <img src="assets/icon.png" width="108" height="108" alt="uu 远控增强" />
</p>

# uu 远控增强

UU 远程 iOS 客户端增强插件，支持 iOS 15.0 及以上。为日常远控提供常用组合快捷键、圆环虚拟滚轮以及多显示器视角记忆修复。

## 功能

- **电脑键盘常用组合键**：在组合键模式下，将下方原符号按键替换为 6 个常用快捷组合键：`Shift+Enter`、全选（`⌘A` / `Ctrl+A`）、撤销（`⌘Z` / `Ctrl+Z`）、剪切（`⌘X` / `Ctrl+X`）、复制（`⌘C` / `Ctrl+C`）、粘贴（`⌘V` / `Ctrl+V`）。自动识别被控电脑系统使用 Mac ⌘ 或 Windows Ctrl。
- **圆环虚拟滚轮**：将原生虚拟鼠标中间滚轮改为双层圆圈转盘效果，逆时针转圈向上滚动，顺时针转圈向下滚动，并根据旋转角速度自适应映射滚动速度。
- **多显示器视角记忆与定位修复**：记住各显示器的缩放比例与平移定位。在原生菜单「操作→显示→多显示屏管理」切换显示器以及 App 切到后台返回时，自动恢复对应显示器的缩放和位置。
- **良好共存**：可与「UU远控切屏」（`im.mjh.uuscreenswitch`）同时安装使用，底层视角引擎自动协同，不产生冲突。

## 安装

正式版本：**1.0.1**。包名：`uuhelper`（RootHide 为 `uuhelper.roothide`）。

| 环境 | 下载 |
|---|---|
| Rootless | [uuhelper_1.0.1_arm64.deb](https://github.com/5hux1n/uuhelper/releases/download/v1.0.1/uuhelper_1.0.1_arm64.deb) |
| RootHide | [uuhelper_1.0.1_arm64e.deb](https://github.com/5hux1n/uuhelper/releases/download/v1.0.1/uuhelper_1.0.1_arm64e.deb) |

可通过个人插件源 [apt.mjh.im](https://apt.mjh.im/) 直接添加安装。

## 更新日志

### 1.0.1
- 修复切回前台后屏幕缩放和定位失效的问题。


### 1.0.0
- 首次正式发布：
  - 新增电脑键盘常用组合键（Shift+Enter、全选、撤销、剪切、复制、粘贴）。
  - 新增虚拟鼠标圆环滚轮转盘与自适应转速调节。
  - 新增多显示屏切换与后台恢复时的视角定位记忆修复。

## 关于与支持

- 作者：[Junhong](https://mjh.im/)
- 插件源：[apt.mjh.im](https://apt.mjh.im/)
- 反馈：[https://pingme.pm/uuhelper](https://pingme.pm/uuhelper)
- GitHub：[https://github.com/5hux1n/uuhelper](https://github.com/5hux1n/uuhelper)
