# AnyWay 图标提案

这组图标围绕 AnyWay 的定位模拟、路径点编辑与路线回放设计。四个初版和两版「02 坐标偏移」细化稿均为原创矢量图，没有直接使用图标库或其他产品的标志。

| 方案 | 核心图形 | 气质 | 对应功能 |
| --- | --- | --- | --- |
| 01 Route A | 由三个路径点连接成的 A | 稳重、精确 | 品牌名称与路线编辑 |
| 02 Offset | 由原坐标移向模拟坐标 | 科技、灵动 | 模拟定位 |
| 03 Loop | 闭合轨迹与播放符号 | 亲和、直接 | 循环路线与跑道模板 |
| 04 Waymark | 带路径点的 W 形路线 | 鲜明、品牌化 | AnyWay 与自由路线 |

四个初版中，**01 Route A** 最贴近现有界面配色，**02 Offset** 最能表达模拟坐标的变化。针对「定位特征不够明显」的反馈，下面继续细化 02，并优先推荐定位针版本。

## 02 坐标偏移细化

在保留紫色旧坐标、薄荷绿新坐标与曲线迁移的前提下，增加了两种「定位」表达：

| 方案 | 改进 | 建议 |
| --- | --- | --- |
| 02 Location Pin | 终点形成定位针；旧坐标与终点之间采用适度弧线，中段不回折，辅以低对比定位环 | **推荐**：定位与路线模拟都更直接 |
| 02 Location Focus | 终点变为 GPS 锁定准星，保留原版的圆形结构 | 适合偏工具、精密仪器的风格 |

三版并排对照见 `offset-refinements.png`。初版和细化版都保留在目录中，便于继续调整。

每版包含可编辑的 `1024×1024` SVG、`1024×1024` PNG 和 `64×64` 检查图。原图保留完整方形背景，系统可按平台裁切圆角；比较图仅为圆角场景预览。尚未替换应用当前图标。

## 设计参考

- [Apple App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons.md)：使用少量清晰形状、让主体居中，并由系统处理圆角。
- [Material Design system icons](https://m2.material.io/design/iconography/system-icons.html)：使用粗壮的几何图形，检查小尺寸下的辨识度。

在 Windows 项目的 Python 环境中重新生成 PNG 和比较图：

```powershell
.\windows\.venv\Scripts\python.exe design\icon-concepts\render.py
```
